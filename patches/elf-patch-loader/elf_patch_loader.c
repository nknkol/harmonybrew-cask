/* SPDX-License-Identifier: MIT */
/*
 * Universal HarmonyOS ELF In-Memory Patch Loader (AArch64)
 *
 * Loads an unmodified ELF64 AArch64 binary (and its PT_INTERP if dynamic)
 * into anonymous memory, applies declarative in-memory patches (supporting
 * wildcard signature search, Go pclntab symbol lookup, and exact-offset
 * fallback), injects DT_RUNPATH in memory without patchelf, enables
 * PROT_EXEC via HarmonyOS PR_HM_JIT, and transfers control.
 */

#include <stdint.h>
#include <stddef.h>
#include <elf.h>
#include <asm/unistd.h>

#define PAGE_SIZE 4096UL
#define ROUND_PG(x) (((x) + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1))
#define TRUNC_PG(x) ((x) & ~(PAGE_SIZE - 1))

#define PROT_NONE  0x0
#define PROT_READ  0x1
#define PROT_WRITE 0x2
#define PROT_EXEC  0x4

#define MAP_PRIVATE         0x02
#define MAP_FIXED           0x10
#define MAP_ANONYMOUS       0x20
#define MAP_FIXED_NOREPLACE 0x100000

#define AT_FDCWD (-100)
#define O_RDONLY 0

#define PR_SET_NAME 15
#define PR_HM_JIT   0x6a6974

#define MAX_PHDRS       64
#define MAX_PATH_LEN    1024
#define MAX_ENVS        64
#define MAX_TARGETS     32
#define MAX_CANDIDATES  8
#define MAX_PAT_LEN     128
#define CONFIG_MAX_SIZE (64 * 1024)

static inline long sys_call(long n, long a0, long a1, long a2, long a3, long a4, long a5) {
    register long x8 __asm__("x8") = n;
    register long x0 __asm__("x0") = a0;
    register long x1 __asm__("x1") = a1;
    register long x2 __asm__("x2") = a2;
    register long x3 __asm__("x3") = a3;
    register long x4 __asm__("x4") = a4;
    register long x5 __asm__("x5") = a5;
    __asm__ volatile ("svc #0"
                      : "+r"(x0)
                      : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5)
                      : "memory", "cc");
    return x0;
}

static size_t z_strlen(const char *s) {
    size_t n = 0;
    while (s && s[n]) n++;
    return n;
}

static int z_strcmp(const char *a, const char *b) {
    while (*a && *a == *b) { a++; b++; }
    return (unsigned char)*a - (unsigned char)*b;
}

static int z_strncmp(const char *a, const char *b, size_t n) {
    for (size_t i = 0; i < n; i++) {
        if (a[i] != b[i] || !a[i] || !b[i])
            return (unsigned char)a[i] - (unsigned char)b[i];
    }
    return 0;
}

void *memcpy(void *dst, const void *src, size_t n) {
    unsigned char *d = dst;
    const unsigned char *s = src;
    while (n--) *d++ = *s++;
    return dst;
}

void *memset(void *dst, int c, size_t n) {
    unsigned char *d = dst;
    while (n--) *d++ = (unsigned char)c;
    return dst;
}

#define z_memcpy memcpy
#define z_memset memset

static void z_strcpy(char *dst, const char *src, size_t cap) {
    if (!cap) return;
    size_t i = 0;
    while (i + 1 < cap && src[i]) {
        dst[i] = src[i];
        i++;
    }
    dst[i] = '\0';
}

static void write_str(int fd, const char *s) {
    sys_call(__NR_write, fd, (long)s, (long)z_strlen(s), 0, 0, 0);
}

static void write_hex(int fd, uint64_t val) {
    char buf[19];
    buf[0] = '0';
    buf[1] = 'x';
    int pos = 18;
    buf[pos] = '\0';
    if (val == 0) {
        write_str(fd, "0x0");
        return;
    }
    while (val > 0 && pos > 2) {
        int d = val & 0xf;
        buf[--pos] = (char)(d < 10 ? ('0' + d) : ('a' + d - 10));
        val >>= 4;
    }
    write_str(fd, "0x");
    write_str(fd, &buf[pos]);
}

static void die(const char *msg, const char *detail) {
    write_str(2, "[elf-patch-loader] error: ");
    write_str(2, msg);
    if (detail && detail[0]) {
        write_str(2, ": ");
        write_str(2, detail);
    }
    write_str(2, "\n");
    sys_call(__NR_exit_group, 127, 0, 0, 0, 0, 0);
    __builtin_unreachable();
}

static void flush_icache(void *addr, size_t len) {
    uintptr_t start = (uintptr_t)addr & ~63UL;
    uintptr_t end = (uintptr_t)addr + len;
    for (uintptr_t p = start; p < end; p += 64)
        __asm__ volatile ("dc cvau, %0" : : "r"(p) : "memory");
    __asm__ volatile ("dsb ish");
    for (uintptr_t p = start; p < end; p += 64)
        __asm__ volatile ("ic ivau, %0" : : "r"(p) : "memory");
    __asm__ volatile ("dsb ish\n\tisb");
}

static int mprotect_hm(void *addr, size_t len, int prot) {
    if (prot & PROT_EXEC) {
        sys_call(__NR_prctl, PR_HM_JIT, 0, 0, 0, 0, 0);
        long rc = sys_call(__NR_mprotect, (long)addr, (long)len, prot, 0, 0, 0);
        sys_call(__NR_prctl, PR_HM_JIT, 0, 1, 0, 0, 0);
        if (rc == 0)
            flush_icache(addr, len);
        return (int)rc;
    }
    return (int)sys_call(__NR_mprotect, (long)addr, (long)len, prot, 0, 0, 0);
}

static void pread_full(int fd, void *buf, size_t count, uint64_t offset) {
    unsigned char *p = buf;
    while (count > 0) {
        long n = sys_call(__NR_pread64, fd, (long)p, (long)count, (long)offset, 0, 0);
        if (n <= 0) die("pread64 failed", NULL);
        p += n;
        count -= (size_t)n;
        offset += (uint64_t)n;
    }
}

enum cand_type {
    CAND_SEARCH = 1,
    CAND_SEARCH_ALL_SEGS = 2,
    CAND_GO_SYM = 3,
    CAND_OFFSET = 4,
    CAND_REDIRECT_ADRP = 5,
};

struct patch_candidate {
    enum cand_type type;
    uint64_t vaddr;               /* For CAND_OFFSET */
    char sym_name[128];           /* For CAND_GO_SYM */
    int64_t patch_off;            /* Byte offset relative to match/symbol/vaddr */
    uint8_t pattern[MAX_PAT_LEN]; /* Expected pattern bytes */
    uint8_t mask[MAX_PAT_LEN];    /* 0xff = exact match, 0x00 = wildcard ?? */
    size_t pat_len;
    uint8_t replace[MAX_PAT_LEN]; /* Replacement bytes */
    uint8_t rep_mask[MAX_PAT_LEN];/* 0xff = write byte, 0x00 = keep original byte */
    size_t rep_len;
    int allow_multiple;           /* 0 = require unique match (count==1), 1 = all */
};

struct patch_target {
    char name[64];
    int optional;
    int cand_count;
    struct patch_candidate cands[MAX_CANDIDATES];
};

struct loader_config {
    char program[MAX_PATH_LEN];
    char interp[MAX_PATH_LEN];
    char runpath[MAX_PATH_LEN];
    char envs[MAX_ENVS][256];
    int env_count;
    int trap_sigsys;
    struct patch_target targets[MAX_TARGETS];
    int target_count;
};

static int hex_val(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static int parse_u64(const char *s, uint64_t *out) {
    uint64_t v = 0;
    int base = 10;
    int neg = 0;
    if (*s == '-') { neg = 1; s++; }
    else if (*s == '+') { s++; }
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
        base = 16;
        s += 2;
    }
    if (!*s) return -1;
    while (*s) {
        int d = hex_val(*s++);
        if (d < 0 || d >= base) return -1;
        v = v * (uint64_t)base + (uint64_t)d;
    }
    *out = neg ? (uint64_t)(-(int64_t)v) : v;
    return 0;
}

/* Parse hex string where "??" or ".." is a wildcard byte (mask=0x00). */
static int parse_masked_hex(const char *s, uint8_t *bytes, uint8_t *mask, size_t *len_out) {
    size_t len = 0;
    if (s[0] == '-' && s[1] == '\0') {
        *len_out = 0;
        return 0;
    }
    while (*s) {
        if (*s == '_' || *s == ':') { s++; continue; }
        char c0 = s[0], c1 = s[1];
        if (!c1) return -1;
        if (len >= MAX_PAT_LEN) return -1;
        if ((c0 == '?' && c1 == '?') || (c0 == '.' && c1 == '.')) {
            bytes[len] = 0;
            mask[len] = 0x00;
        } else {
            int h0 = hex_val(c0), h1 = hex_val(c1);
            if (h0 < 0 || h1 < 0) return -1;
            bytes[len] = (uint8_t)((h0 << 4) | h1);
            mask[len] = 0xff;
        }
        len++;
        s += 2;
    }
    *len_out = len;
    return 0;
}

static int next_token(char **cursor, char *tok, size_t cap) {
    char *p = *cursor;
    while (*p == ' ' || *p == '\t' || *p == '\r') p++;
    if (!*p || *p == '#' || *p == '\n') {
        *cursor = p;
        return 0;
    }
    size_t i = 0;
    if (*p == '"') {
        p++;
        while (*p && *p != '"' && *p != '\n') {
            if (i + 1 < cap) tok[i++] = *p;
            p++;
        }
        if (*p == '"') p++;
    } else {
        while (*p && *p != ' ' && *p != '\t' && *p != '\r' && *p != '\n' && *p != '#') {
            if (i + 1 < cap) tok[i++] = *p;
            p++;
        }
    }
    tok[i] = '\0';
    *cursor = p;
    return 1;
}

static void resolve_rel_path(const char *base_dir, const char *in, char *out, size_t cap) {
    if (in[0] == '/') {
        z_strcpy(out, in, cap);
        return;
    }
    size_t blen = z_strlen(base_dir);
    z_strcpy(out, base_dir, cap);
    if (blen > 0 && out[blen - 1] != '/' && blen + 1 < cap) {
        out[blen++] = '/';
        out[blen] = '\0';
    }
    z_strcpy(out + blen, in, cap - blen);
}

static void parse_config(const char *conf_path, const char *prefix_dir, struct loader_config *cfg) {
    int fd = (int)sys_call(__NR_openat, AT_FDCWD, (long)conf_path, O_RDONLY, 0, 0, 0);
    if (fd < 0) die("cannot open config", conf_path);
    char *buf = (char *)sys_call(__NR_mmap, 0, CONFIG_MAX_SIZE, PROT_READ | PROT_WRITE,
                                 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if ((long)buf < 0 && (long)buf > -4096) die("mmap config failed", NULL);
    long n = sys_call(__NR_read, fd, (long)buf, CONFIG_MAX_SIZE - 1, 0, 0, 0);
    sys_call(__NR_close, fd, 0, 0, 0, 0, 0);
    if (n < 0) die("read config failed", conf_path);
    buf[n] = '\0';

    char *p = buf;
    char tok[MAX_PATH_LEN];
    struct patch_target *cur_target = NULL;

    while (*p) {
        while (*p == '\n' || *p == '\r') p++;
        if (!*p) break;
        if (!next_token(&p, tok, sizeof(tok))) {
            while (*p && *p != '\n') p++;
            continue;
        }
        if (z_strcmp(tok, "PROGRAM") == 0) {
            if (!next_token(&p, tok, sizeof(tok))) die("PROGRAM missing path", NULL);
            resolve_rel_path(prefix_dir, tok, cfg->program, sizeof(cfg->program));
        } else if (z_strcmp(tok, "INTERP") == 0) {
            if (!next_token(&p, tok, sizeof(tok))) die("INTERP missing path", NULL);
            resolve_rel_path(prefix_dir, tok, cfg->interp, sizeof(cfg->interp));
        } else if (z_strcmp(tok, "RUNPATH") == 0) {
            if (!next_token(&p, tok, sizeof(tok))) die("RUNPATH missing path", NULL);
            resolve_rel_path(prefix_dir, tok, cfg->runpath, sizeof(cfg->runpath));
        } else if (z_strcmp(tok, "ENV") == 0) {
            if (!next_token(&p, tok, sizeof(tok))) die("ENV missing KEY=VALUE", NULL);
            if (cfg->env_count >= MAX_ENVS) die("too many ENV entries", NULL);
            z_strcpy(cfg->envs[cfg->env_count++], tok, sizeof(cfg->envs[0]));
        } else if (z_strcmp(tok, "TRAP_SIGSYS") == 0) {
            cfg->trap_sigsys = 1;
        } else if (z_strcmp(tok, "TARGET") == 0) {
            if (!next_token(&p, tok, sizeof(tok))) die("TARGET missing name", NULL);
            if (cfg->target_count >= MAX_TARGETS) die("too many TARGET entries", NULL);
            cur_target = &cfg->targets[cfg->target_count++];
            z_memset(cur_target, 0, sizeof(*cur_target));
            z_strcpy(cur_target->name, tok, sizeof(cur_target->name));
            if (next_token(&p, tok, sizeof(tok))) {
                if (z_strcmp(tok, "OPTIONAL") == 0) cur_target->optional = 1;
                else if (z_strcmp(tok, "REQUIRED") != 0) die("unknown TARGET flag", tok);
            }
        } else if (z_strcmp(tok, "SEARCH") == 0 || z_strcmp(tok, "SEARCH_ALL") == 0) {
            if (!cur_target) die("SEARCH outside TARGET", NULL);
            if (cur_target->cand_count >= MAX_CANDIDATES) die("too many candidates", cur_target->name);
            struct patch_candidate *c = &cur_target->cands[cur_target->cand_count++];
            c->type = (z_strcmp(tok, "SEARCH_ALL") == 0) ? CAND_SEARCH_ALL_SEGS : CAND_SEARCH;
            char pat_s[512], off_s[64], rep_s[512], opt_s[64];
            if (!next_token(&p, pat_s, sizeof(pat_s)) ||
                !next_token(&p, off_s, sizeof(off_s)) ||
                !next_token(&p, rep_s, sizeof(rep_s)))
                die("SEARCH syntax: SEARCH <pattern_hex> <patch_off> <replace_hex> [multi]", cur_target->name);
            uint64_t poff = 0;
            if (parse_masked_hex(pat_s, c->pattern, c->mask, &c->pat_len) < 0 || c->pat_len == 0 ||
                parse_u64(off_s, &poff) < 0 ||
                parse_masked_hex(rep_s, c->replace, c->rep_mask, &c->rep_len) < 0 || c->rep_len == 0)
                die("invalid hex/offset in SEARCH", cur_target->name);
            c->patch_off = (int64_t)poff;
            if (next_token(&p, opt_s, sizeof(opt_s)) && z_strcmp(opt_s, "multi") == 0)
                c->allow_multiple = 1;
        } else if (z_strcmp(tok, "GO_SYM") == 0) {
            if (!cur_target) die("GO_SYM outside TARGET", NULL);
            if (cur_target->cand_count >= MAX_CANDIDATES) die("too many candidates", cur_target->name);
            struct patch_candidate *c = &cur_target->cands[cur_target->cand_count++];
            c->type = CAND_GO_SYM;
            char sym_s[128], off_s[64], pat_s[512], rep_s[512];
            if (!next_token(&p, sym_s, sizeof(sym_s)) ||
                !next_token(&p, off_s, sizeof(off_s)) ||
                !next_token(&p, pat_s, sizeof(pat_s)) ||
                !next_token(&p, rep_s, sizeof(rep_s)))
                die("GO_SYM syntax: GO_SYM <symbol> <patch_off> <expect_hex|-> <replace_hex>", cur_target->name);
            z_strcpy(c->sym_name, sym_s, sizeof(c->sym_name));
            uint64_t poff = 0;
            if (parse_u64(off_s, &poff) < 0 ||
                parse_masked_hex(pat_s, c->pattern, c->mask, &c->pat_len) < 0 ||
                parse_masked_hex(rep_s, c->replace, c->rep_mask, &c->rep_len) < 0 || c->rep_len == 0)
                die("invalid arguments in GO_SYM", cur_target->name);
            c->patch_off = (int64_t)poff;
        } else if (z_strcmp(tok, "OFFSET") == 0) {
            if (!cur_target) die("OFFSET outside TARGET", NULL);
            if (cur_target->cand_count >= MAX_CANDIDATES) die("too many candidates", cur_target->name);
            struct patch_candidate *c = &cur_target->cands[cur_target->cand_count++];
            c->type = CAND_OFFSET;
            char va_s[64], pat_s[512], rep_s[512];
            if (!next_token(&p, va_s, sizeof(va_s)) ||
                !next_token(&p, pat_s, sizeof(pat_s)) ||
                !next_token(&p, rep_s, sizeof(rep_s)))
                die("OFFSET syntax: OFFSET <vaddr> <expect_hex> <replace_hex>", cur_target->name);
            if (parse_u64(va_s, &c->vaddr) < 0 ||
                parse_masked_hex(pat_s, c->pattern, c->mask, &c->pat_len) < 0 ||
                parse_masked_hex(rep_s, c->replace, c->rep_mask, &c->rep_len) < 0 || c->rep_len == 0)
                die("invalid arguments in OFFSET", cur_target->name);
        } else if (z_strcmp(tok, "REDIRECT_ADRP") == 0) {
            if (!cur_target) die("REDIRECT_ADRP outside TARGET", NULL);
            if (cur_target->cand_count >= MAX_CANDIDATES) die("too many candidates", cur_target->name);
            struct patch_candidate *c = &cur_target->cands[cur_target->cand_count++];
            c->type = CAND_REDIRECT_ADRP;
            char pat_s[512], rep_s[512], opt_s[64];
            if (!next_token(&p, pat_s, sizeof(pat_s)) ||
                !next_token(&p, rep_s, sizeof(rep_s)))
                die("REDIRECT_ADRP syntax: REDIRECT_ADRP <orig_hex> <new_hex> [multi]", cur_target->name);
            if (parse_masked_hex(pat_s, c->pattern, c->mask, &c->pat_len) < 0 || c->pat_len == 0 ||
                parse_masked_hex(rep_s, c->replace, c->rep_mask, &c->rep_len) < 0 || c->rep_len == 0)
                die("invalid arguments in REDIRECT_ADRP", cur_target->name);
            if (next_token(&p, opt_s, sizeof(opt_s)) && z_strcmp(opt_s, "multi") == 0)
                c->allow_multiple = 1;
        } else {
            die("unknown directive in config", tok);
        }
        while (*p && *p != '\n') p++;
    }
    sys_call(__NR_munmap, (long)buf, CONFIG_MAX_SIZE, 0, 0, 0, 0);
}

struct loaded_elf {
    Elf64_Ehdr ehdr;
    Elf64_Phdr phdr[MAX_PHDRS];
    uintptr_t bias;
    uintptr_t entry;
    uintptr_t phdr_va;
    uintptr_t maxva;
    size_t extra_str_off;
};

static int match_bytes(const uint8_t *mem, const uint8_t *pat, const uint8_t *mask, size_t len) {
    for (size_t i = 0; i < len; i++) {
        if ((mem[i] & mask[i]) != (pat[i] & mask[i]))
            return 0;
    }
    return 1;
}

static void apply_replacement(uint8_t *dst, const uint8_t *rep, const uint8_t *rep_mask, size_t len) {
    for (size_t i = 0; i < len; i++) {
        if (rep_mask[i])
            dst[i] = rep[i];
    }
}

static uint8_t *vaddr_to_ptr(const struct loaded_elf *elf, uint64_t vaddr, size_t len) {
    for (int i = 0; i < elf->ehdr.e_phnum; i++) {
        const Elf64_Phdr *ph = &elf->phdr[i];
        if (ph->p_type != PT_LOAD) continue;
        if (vaddr >= ph->p_vaddr && vaddr + len <= ph->p_vaddr + ph->p_filesz)
            return (uint8_t *)(elf->bias + vaddr);
    }
    return NULL;
}

/* Locate a Go function's virtual address via .gopclntab in memory. */
static int find_go_symbol(const struct loaded_elf *elf, const char *sym_name, uint64_t *vaddr_out) {
    static const uint8_t magic[8] = {0xf1, 0xff, 0xff, 0xff, 0x00, 0x00, 0x04, 0x08};
    uint64_t pclntab_va = 0;
    const uint8_t *pclntab = NULL;

    for (int i = 0; i < elf->ehdr.e_phnum; i++) {
        const Elf64_Phdr *ph = &elf->phdr[i];
        if (ph->p_type != PT_LOAD || ph->p_filesz < 80) continue;
        const uint8_t *base = (const uint8_t *)(elf->bias + ph->p_vaddr);
        for (size_t off = 0; off + 80 <= ph->p_filesz; off += 8) {
            if (z_strncmp((const char *)(base + off), (const char *)magic, 8) == 0) {
                const uint64_t *hdr = (const uint64_t *)(base + off + 8);
                if (hdr[0] > 10 && hdr[0] < 2000000 && hdr[3] < ph->p_filesz) {
                    pclntab = base + off;
                    pclntab_va = ph->p_vaddr + off;
                    break;
                }
            }
        }
        if (pclntab) break;
    }
    if (!pclntab) return 0;

    const uint64_t *hdr = (const uint64_t *)(pclntab + 8);
    uint64_t nfunc = hdr[0];
    uint64_t text_start = hdr[2];
    uint64_t funcname_off = hdr[3];
    uint64_t pcln_off = hdr[7];

    /* If text_start is 0 (PIE with .rela.dyn), resolve moduledata.text from DT_RELA. */
    if (text_start == 0) {
        for (int i = 0; i < elf->ehdr.e_phnum; i++) {
            if (elf->phdr[i].p_type != PT_DYNAMIC) continue;
            const Elf64_Dyn *dyn = (const Elf64_Dyn *)(elf->bias + elf->phdr[i].p_vaddr);
            uint64_t rela_va = 0, rela_sz = 0;
            for (; dyn->d_tag != DT_NULL; dyn++) {
                if (dyn->d_tag == DT_RELA) rela_va = dyn->d_un.d_ptr;
                else if (dyn->d_tag == DT_RELASZ) rela_sz = dyn->d_un.d_val;
            }
            if (rela_va && rela_sz) {
                const Elf64_Rela *rela = (const Elf64_Rela *)(elf->bias + rela_va);
                size_t count = rela_sz / sizeof(Elf64_Rela);
                for (size_t r = 0; r < count; r++) {
                    if ((uint64_t)rela[r].r_addend == pclntab_va) {
                        uint64_t md_va = rela[r].r_offset;
                        for (size_t k = r + 1; k < r + 32 && k < count; k++) {
                            if (rela[k].r_offset == md_va + 0xa0) {
                                text_start = (uint64_t)rela[k].r_addend;
                                break;
                            }
                        }
                        break;
                    }
                }
            }
            break;
        }
    }
    if (text_start == 0) return 0;

    const uint8_t *funcnametab = pclntab + funcname_off;
    const uint8_t *functab = pclntab + pcln_off;
    for (uint64_t i = 0; i < nfunc; i++) {
        uint32_t entry_off = *(const uint32_t *)(functab + i * 8);
        uint32_t info_off = *(const uint32_t *)(functab + i * 8 + 4);
        int32_t name_off = *(const int32_t *)(functab + info_off + 4);
        if (name_off < 0) continue;
        const char *name = (const char *)(funcnametab + name_off);
        if (z_strcmp(name, sym_name) == 0) {
            *vaddr_out = text_start + entry_off;
            return 1;
        }
    }
    return 0;
}

static int apply_candidate(struct loaded_elf *elf, const struct patch_candidate *c,
                           uint64_t *matched_vaddr_out, int *match_count_out) {
    if (c->type == CAND_OFFSET) {
        uint64_t target_va = (uint64_t)((int64_t)c->vaddr + c->patch_off);
        uint8_t *check_ptr = vaddr_to_ptr(elf, c->vaddr, c->pat_len ? c->pat_len : 1);
        uint8_t *patch_ptr = vaddr_to_ptr(elf, target_va, c->rep_len);
        if (!check_ptr || !patch_ptr) return 0;
        if (c->pat_len > 0 && !match_bytes(check_ptr, c->pattern, c->mask, c->pat_len))
            return 0;
        apply_replacement(patch_ptr, c->replace, c->rep_mask, c->rep_len);
        *matched_vaddr_out = target_va;
        *match_count_out = 1;
        return 1;
    }

    if (c->type == CAND_GO_SYM) {
        uint64_t sym_va = 0;
        if (!find_go_symbol(elf, c->sym_name, &sym_va)) return 0;
        uint64_t target_va = (uint64_t)((int64_t)sym_va + c->patch_off);
        uint8_t *patch_ptr = vaddr_to_ptr(elf, target_va, c->rep_len);
        if (!patch_ptr) return 0;
        if (c->pat_len > 0) {
            uint8_t *check_ptr = vaddr_to_ptr(elf, target_va, c->pat_len);
            if (!check_ptr || !match_bytes(check_ptr, c->pattern, c->mask, c->pat_len))
                return 0;
        }
        apply_replacement(patch_ptr, c->replace, c->rep_mask, c->rep_len);
        *matched_vaddr_out = target_va;
        *match_count_out = 1;
        return 1;
    }

    if (c->type == CAND_SEARCH || c->type == CAND_SEARCH_ALL_SEGS) {
        uint64_t hits[16];
        int hit_count = 0;
        size_t step = (c->type == CAND_SEARCH && (c->pat_len % 4 == 0)) ? 4 : 1;

        for (int i = 0; i < elf->ehdr.e_phnum; i++) {
            const Elf64_Phdr *ph = &elf->phdr[i];
            if (ph->p_type != PT_LOAD) continue;
            if (c->type == CAND_SEARCH && !(ph->p_flags & PF_X)) continue;
            if (ph->p_filesz < c->pat_len) continue;

            const uint8_t *seg = (const uint8_t *)(elf->bias + ph->p_vaddr);
            size_t limit = ph->p_filesz - c->pat_len;
            for (size_t off = 0; off <= limit; off += step) {
                if (match_bytes(seg + off, c->pattern, c->mask, c->pat_len)) {
                    if (hit_count < 16)
                        hits[hit_count] = ph->p_vaddr + off;
                    hit_count++;
                    if (!c->allow_multiple && hit_count > 1)
                        return 0; /* Ambiguous match; reject candidate */
                }
            }
        }
        if (hit_count == 0) return 0;
        if (!c->allow_multiple && hit_count != 1) return 0;

        int to_apply = hit_count < 16 ? hit_count : 16;
        for (int h = 0; h < to_apply; h++) {
            uint64_t target_va = (uint64_t)((int64_t)hits[h] + c->patch_off);
            uint8_t *patch_ptr = vaddr_to_ptr(elf, target_va, c->rep_len);
            if (!patch_ptr) return 0;
            apply_replacement(patch_ptr, c->replace, c->rep_mask, c->rep_len);
        }
        *matched_vaddr_out = (uint64_t)((int64_t)hits[0] + c->patch_off);
        *match_count_out = hit_count;
        return 1;
    }

    if (c->type == CAND_REDIRECT_ADRP) {
        uint64_t lit_va = 0;
        int lit_hits = 0;
        for (int i = 0; i < elf->ehdr.e_phnum; i++) {
            const Elf64_Phdr *ph = &elf->phdr[i];
            if (ph->p_type != PT_LOAD || ph->p_filesz < c->pat_len) continue;
            const uint8_t *seg = (const uint8_t *)(elf->bias + ph->p_vaddr);
            size_t limit = ph->p_filesz - c->pat_len;
            for (size_t off = 0; off <= limit; off++) {
                if (match_bytes(seg + off, c->pattern, c->mask, c->pat_len)) {
                    lit_va = ph->p_vaddr + off;
                    lit_hits++;
                    if (lit_hits > 1) return 0;
                }
            }
        }
        if (lit_hits != 1) return 0;

        uint64_t code_hits[16];
        int code_count = 0;
        for (int i = 0; i < elf->ehdr.e_phnum; i++) {
            const Elf64_Phdr *ph = &elf->phdr[i];
            if (ph->p_type != PT_LOAD || !(ph->p_flags & PF_X) || ph->p_filesz < 8) continue;
            const uint8_t *seg = (const uint8_t *)(elf->bias + ph->p_vaddr);
            size_t limit = ph->p_filesz - 8;
            for (size_t off = 0; off <= limit; off += 4) {
                uint32_t i0 = *(const uint32_t *)(seg + off);
                uint32_t i1 = *(const uint32_t *)(seg + off + 4);
                if ((i0 & 0x9f000000U) == 0x90000000U && (i1 & 0xff800000U) == 0x91000000U) {
                    uint32_t rd0 = i0 & 0x1fU;
                    uint32_t rd1 = i1 & 0x1fU;
                    uint32_t rn1 = (i1 >> 5) & 0x1fU;
                    if (rd0 == rd1 && rd0 == rn1) {
                        int64_t immlo = (int64_t)((i0 >> 29) & 0x3U);
                        int64_t immhi = (int64_t)((i0 >> 5) & 0x7ffffU);
                        int64_t imm = (immhi << 2) | immlo;
                        if (imm & (1LL << 20)) imm -= (1LL << 21);
                        uint64_t pc = ph->p_vaddr + off;
                        uint64_t page = (pc & ~0xfffULL) + (uint64_t)(imm << 12);
                        uint64_t add_imm = (i1 >> 10) & 0xfffU;
                        if ((i1 >> 22) & 1U) add_imm <<= 12;
                        if (page + add_imm == lit_va) {
                            if (code_count < 16) code_hits[code_count] = pc;
                            code_count++;
                            if (!c->allow_multiple && code_count > 1) return 0;
                        }
                    }
                }
            }
        }
        if (code_count == 0) return 0;
        if (!c->allow_multiple && code_count != 1) return 0;
        if (elf->extra_str_off + c->rep_len > PAGE_SIZE) return 0;

        uint64_t new_va = elf->maxva + elf->extra_str_off;
        uint8_t *dst_str = (uint8_t *)(elf->bias + new_va);
        apply_replacement(dst_str, c->replace, c->rep_mask, c->rep_len);
        elf->extra_str_off = (elf->extra_str_off + c->rep_len + 7) & ~7UL;

        int to_apply = code_count < 16 ? code_count : 16;
        for (int h = 0; h < to_apply; h++) {
            uint64_t pc = code_hits[h];
            uint32_t *insns = (uint32_t *)(elf->bias + pc);
            uint32_t rd = insns[0] & 0x1fU;
            int64_t page_delta = ((int64_t)(new_va & ~0xfffULL) - (int64_t)(pc & ~0xfffULL)) >> 12;
            uint32_t uimm = (uint32_t)page_delta & 0x1fffffU;
            insns[0] = 0x90000000U | ((uimm & 3U) << 29) | ((uimm >> 2) << 5) | rd;
            insns[1] = 0x91000000U | (((uint32_t)(new_va & 0xfffULL)) << 10) | (rd << 5) | rd;
        }
        *matched_vaddr_out = code_hits[0];
        *match_count_out = code_count;
        return 1;
    }

    return 0;
}

__attribute__((visibility("hidden"))) uintptr_t g_got_sigaction;
__attribute__((visibility("hidden"))) uintptr_t g_got_pthread_sigmask;
__attribute__((visibility("hidden"))) uintptr_t g_got_sigprocmask;
__attribute__((visibility("hidden"))) uintptr_t g_got_sigfillset;

extern const uint8_t __sigsys_restorer[] __attribute__((visibility("hidden")));
extern const uint8_t __sigsys_handler[] __attribute__((visibility("hidden")));
extern const uint8_t __hook_go_rt_sigaction[] __attribute__((visibility("hidden")));
extern const uint8_t __hook_go_rtsigprocmask[] __attribute__((visibility("hidden")));
extern const uint8_t __hook_plt_sigaction[] __attribute__((visibility("hidden")));
extern const uint8_t __hook_plt_pthread_sigmask[] __attribute__((visibility("hidden")));
extern const uint8_t __hook_plt_sigprocmask[] __attribute__((visibility("hidden")));
extern const uint8_t __hook_plt_sigfillset[] __attribute__((visibility("hidden")));

static void write_abs_jump16(uint8_t *dst, uintptr_t target_addr) {
    uint32_t j0 = 0x58000050U; /* ldr x16, #8 */
    uint32_t j1 = 0xd61f0200U; /* br  x16     */
    uint64_t dst64 = (uint64_t)target_addr;
    z_memcpy(dst, &j0, 4);
    z_memcpy(dst + 4, &j1, 4);
    z_memcpy(dst + 8, &dst64, 8);
}

static int find_got_slot_for_sym(const struct loaded_elf *elf, const char *sym_name, uint64_t *got_va_out) {
    size_t slen = z_strlen(sym_name);
    for (int i = 0; i < elf->ehdr.e_phnum; i++) {
        if (elf->phdr[i].p_type != PT_DYNAMIC) continue;
        const Elf64_Dyn *dyn = (const Elf64_Dyn *)vaddr_to_ptr(elf, elf->phdr[i].p_vaddr, sizeof(Elf64_Dyn));
        if (!dyn) return 0;
        uint64_t symtab_va = 0, strtab_va = 0, strsz = 0;
        uint64_t jmprel_va = 0, pltrelsz = 0, rela_va = 0, relasz = 0;
        for (; dyn->d_tag != DT_NULL; dyn++) {
            switch (dyn->d_tag) {
            case DT_SYMTAB:   symtab_va = dyn->d_un.d_ptr; break;
            case DT_STRTAB:   strtab_va = dyn->d_un.d_ptr; break;
            case DT_STRSZ:    strsz     = dyn->d_un.d_val; break;
            case DT_JMPREL:   jmprel_va = dyn->d_un.d_ptr; break;
            case DT_PLTRELSZ: pltrelsz  = dyn->d_un.d_val; break;
            case DT_RELA:     rela_va   = dyn->d_un.d_ptr; break;
            case DT_RELASZ:   relasz    = dyn->d_un.d_val; break;
            }
        }
        if (!symtab_va || !strtab_va || !strsz) return 0;
        const char *strtab = (const char *)vaddr_to_ptr(elf, strtab_va, strsz);
        if (!strtab) return 0;

        uint64_t tables[2][2] = {{jmprel_va, pltrelsz}, {rela_va, relasz}};
        for (int t = 0; t < 2; t++) {
            uint64_t t_va = tables[t][0], t_sz = tables[t][1];
            if (!t_va || !t_sz) continue;
            const Elf64_Rela *rela = (const Elf64_Rela *)vaddr_to_ptr(elf, t_va, t_sz);
            if (!rela) continue;
            size_t count = t_sz / sizeof(Elf64_Rela);
            for (size_t r = 0; r < count; r++) {
                uint32_t rtype = (uint32_t)(rela[r].r_info & 0xffffffffU);
                if (rtype != 1026U && rtype != 1025U) continue; /* JUMP_SLOT or GLOB_DAT */
                uint32_t sidx = (uint32_t)(rela[r].r_info >> 32);
                const Elf64_Sym *sym = (const Elf64_Sym *)vaddr_to_ptr(
                    elf, symtab_va + (uint64_t)sidx * sizeof(Elf64_Sym), sizeof(Elf64_Sym));
                if (!sym || sym->st_name >= strsz) continue;
                const char *sname = strtab + sym->st_name;
                if (z_strncmp(sname, sym_name, slen) == 0 &&
                    (sname[slen] == '\0' || sname[slen] == '@')) {
                    *got_va_out = rela[r].r_offset;
                    return 1;
                }
            }
        }
        break;
    }
    return 0;
}

static int hook_plt_symbol(struct loaded_elf *elf, const char *sym_name,
                           uintptr_t hook_addr, uintptr_t *got_runtime_out, int verbose) {
    uint64_t got_va = 0;
    if (!find_got_slot_for_sym(elf, sym_name, &got_va)) return 0;

    uint64_t hit_va = 0;
    int hits = 0;
    for (int i = 0; i < elf->ehdr.e_phnum; i++) {
        const Elf64_Phdr *ph = &elf->phdr[i];
        if (ph->p_type != PT_LOAD || !(ph->p_flags & PF_X) || ph->p_filesz < 16) continue;
        const uint8_t *seg = (const uint8_t *)(elf->bias + ph->p_vaddr);
        size_t limit = ph->p_filesz - 16;
        for (size_t off = 0; off <= limit; off += 4) {
            const uint32_t *insns = (const uint32_t *)(seg + off);
            uint32_t i0 = insns[0], i1 = insns[1], i2 = insns[2], i3 = insns[3];
            if ((i0 & 0x9f00001fU) == 0x90000010U &&
                (i1 & 0xffc003ffU) == 0xf9400211U &&
                (i3 == 0xd61f0220U || i2 == 0xd61f0220U)) {
                int64_t immlo = (int64_t)((i0 >> 29) & 0x3U);
                int64_t immhi = (int64_t)((i0 >> 5) & 0x7ffffU);
                int64_t imm = (immhi << 2) | immlo;
                if (imm & (1LL << 20)) imm -= (1LL << 21);
                uint64_t pc = ph->p_vaddr + off;
                uint64_t page = (pc & ~0xfffULL) + (uint64_t)(imm << 12);
                uint64_t ldr_off = (uint64_t)((i1 >> 10) & 0xfffU) * 8ULL;
                if (page + ldr_off == got_va) {
                    hit_va = pc;
                    hits++;
                }
            }
        }
    }
    if (hits != 1) return 0;

    *got_runtime_out = elf->bias + got_va;
    write_abs_jump16((uint8_t *)(elf->bias + hit_va), hook_addr);
    if (verbose) {
        write_str(2, "[elf-patch] sigsys-guard hooked PLT '");
        write_str(2, sym_name);
        write_str(2, "' at vaddr ");
        write_hex(2, hit_va);
        write_str(2, "\n");
    }
    return 1;
}

static void apply_sigsys_guards(struct loaded_elf *elf, int verbose) {
    /* 1. Guard Go runtime.rt_sigaction (abi0) if present */
    uint64_t go_sa_va = 0;
    if (find_go_symbol(elf, "runtime.rt_sigaction", &go_sa_va)) {
        static const uint8_t exp_sa[16] = {
            0xe0, 0x07, 0x40, 0xf9, /* ldr x0, [sp, #8]  */
            0xe1, 0x0b, 0x40, 0xf9, /* ldr x1, [sp, #16] */
            0xe2, 0x0f, 0x40, 0xf9, /* ldr x2, [sp, #24] */
            0xe3, 0x13, 0x40, 0xf9  /* ldr x3, [sp, #32] */
        };
        static const uint8_t full_mask[16] = {
            0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
            0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff
        };
        uint8_t *ptr = vaddr_to_ptr(elf, go_sa_va, 16);
        if (ptr && match_bytes(ptr, exp_sa, full_mask, 16)) {
            write_abs_jump16(ptr, (uintptr_t)__hook_go_rt_sigaction);
            if (verbose) {
                write_str(2, "[elf-patch] sigsys-guard hooked Go 'runtime.rt_sigaction' at vaddr ");
                write_hex(2, go_sa_va);
                write_str(2, "\n");
            }
        }
    }

    /* 2. Guard Go runtime.rtsigprocmask (abi0) if present */
    uint64_t go_spm_va = 0;
    if (find_go_symbol(elf, "runtime.rtsigprocmask", &go_spm_va)) {
        static const uint8_t exp_spm[16] = {
            0xe0, 0x0b, 0x80, 0xb9, /* ldrsw x0, [sp, #8]  */
            0xe1, 0x0b, 0x40, 0xf9, /* ldr   x1, [sp, #16] */
            0xe2, 0x0f, 0x40, 0xf9, /* ldr   x2, [sp, #24] */
            0xe3, 0x23, 0x80, 0xb9  /* ldrsw x3, [sp, #32] */
        };
        static const uint8_t full_mask[16] = {
            0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
            0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff
        };
        uint8_t *ptr = vaddr_to_ptr(elf, go_spm_va, 16);
        if (ptr && match_bytes(ptr, exp_spm, full_mask, 16)) {
            write_abs_jump16(ptr, (uintptr_t)__hook_go_rtsigprocmask);
            if (verbose) {
                write_str(2, "[elf-patch] sigsys-guard hooked Go 'runtime.rtsigprocmask' at vaddr ");
                write_hex(2, go_spm_va);
                write_str(2, "\n");
            }
        }
    }

    /* 3. Guard glibc/PLT signal handlers & masks if dynamically imported */
    hook_plt_symbol(elf, "sigaction", (uintptr_t)__hook_plt_sigaction, &g_got_sigaction, verbose);
    hook_plt_symbol(elf, "pthread_sigmask", (uintptr_t)__hook_plt_pthread_sigmask, &g_got_pthread_sigmask, verbose);
    hook_plt_symbol(elf, "sigprocmask", (uintptr_t)__hook_plt_sigprocmask, &g_got_sigprocmask, verbose);
    hook_plt_symbol(elf, "sigfillset", (uintptr_t)__hook_plt_sigfillset, &g_got_sigfillset, verbose);
}

struct kernel_sigaction_hm {
    uintptr_t sa_handler;
    unsigned long sa_flags;
    uintptr_t sa_restorer;
    uint64_t sa_mask;
};

static void install_sigsys_trap(int verbose) {
    /* Ensure SIGSYS (31 -> bit 30) is unblocked before registering handler */
    uint64_t sigsys_bit = (1ULL << 30);
    sys_call(__NR_rt_sigprocmask, 1 /* SIG_UNBLOCK */, (long)&sigsys_bit, 0, 8, 0, 0);

    struct kernel_sigaction_hm ksa;
    ksa.sa_handler = (uintptr_t)__sigsys_handler;
    /* SA_SIGINFO(4) | SA_RESTORER(0x04000000) | SA_ONSTACK(0x08000000) | SA_RESTART(0x10000000) | SA_NODEFER(0x40000000) */
    ksa.sa_flags = 0x5c000004UL;
    ksa.sa_restorer = (uintptr_t)__sigsys_restorer;
    ksa.sa_mask = 0;

    long rc = sys_call(__NR_rt_sigaction, 31 /* SIGSYS */, (long)&ksa, 0, 8, 0, 0);
    if (rc < 0)
        die("rt_sigaction(SIGSYS) failed", NULL);
    if (verbose)
        write_str(2, "[elf-patch] installed resident SIGSYS -> -ENOSYS trap handler\n");
}

static void apply_all_patches(struct loaded_elf *elf, const struct loader_config *cfg, int verbose) {
    for (int t = 0; t < cfg->target_count; t++) {
        const struct patch_target *tgt = &cfg->targets[t];
        int matched = 0;
        for (int c = 0; c < tgt->cand_count; c++) {
            uint64_t vaddr = 0;
            int count = 0;
            if (apply_candidate(elf, &tgt->cands[c], &vaddr, &count)) {
                matched = 1;
                if (verbose) {
                    write_str(2, "[elf-patch] target '");
                    write_str(2, tgt->name);
                    write_str(2, "' matched candidate #");
                    char num[4] = {(char)('1' + c), '\0'};
                    write_str(2, num);
                    write_str(2, " at vaddr ");
                    write_hex(2, vaddr);
                    write_str(2, "\n");
                }
                break;
            }
        }
        if (!matched && !tgt->optional) {
            die("required patch target failed to match any candidate", tgt->name);
        } else if (!matched && verbose) {
            write_str(2, "[elf-patch] optional target '");
            write_str(2, tgt->name);
            write_str(2, "' skipped (no match)\n");
        }
    }
}

static void load_elf(const char *path, struct loaded_elf *out, const struct loader_config *cfg, int verbose) {
    int fd = (int)sys_call(__NR_openat, AT_FDCWD, (long)path, O_RDONLY, 0, 0, 0);
    if (fd < 0) die("cannot open ELF", path);
    pread_full(fd, &out->ehdr, sizeof(out->ehdr), 0);
    if (out->ehdr.e_ident[0] != 0x7f || out->ehdr.e_ident[1] != 'E' ||
        out->ehdr.e_ident[2] != 'L' || out->ehdr.e_ident[3] != 'F')
        die("not an ELF file", path);
    if (out->ehdr.e_phnum > MAX_PHDRS) die("too many program headers", path);
    pread_full(fd, out->phdr, out->ehdr.e_phnum * sizeof(Elf64_Phdr), out->ehdr.e_phoff);

    uintptr_t minva = (uintptr_t)-1, maxva = 0;
    for (int i = 0; i < out->ehdr.e_phnum; i++) {
        if (out->phdr[i].p_type != PT_LOAD) continue;
        if (out->phdr[i].p_vaddr < minva) minva = out->phdr[i].p_vaddr;
        if (out->phdr[i].p_vaddr + out->phdr[i].p_memsz > maxva)
            maxva = out->phdr[i].p_vaddr + out->phdr[i].p_memsz;
    }
    minva = TRUNC_PG(minva);
    maxva = ROUND_PG(maxva);
    const char *inject_runpath = (cfg && cfg->runpath[0]) ? cfg->runpath : NULL;
    size_t extra = cfg ? PAGE_SIZE : 0;
    int dyn = (out->ehdr.e_type == ET_DYN);
    void *hint = dyn ? NULL : (void *)minva;
    long base = sys_call(__NR_mmap, (long)hint, (long)(maxva - minva + extra), PROT_NONE,
                         (dyn ? 0 : MAP_FIXED_NOREPLACE) | MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (base < 0 && base > -4096) die("mmap reserve failed", path);
    out->bias = dyn ? ((uintptr_t)base - minva) : 0;
    out->maxva = maxva;
    out->extra_str_off = 3072;

    for (int i = 0; i < out->ehdr.e_phnum; i++) {
        const Elf64_Phdr *ph = &out->phdr[i];
        if (ph->p_type != PT_LOAD) continue;
        uintptr_t off = ph->p_vaddr & (PAGE_SIZE - 1);
        uintptr_t start = out->bias + TRUNC_PG(ph->p_vaddr);
        size_t size = ROUND_PG(ph->p_memsz + off);
        long p = sys_call(__NR_mmap, (long)start, (long)size, PROT_READ | PROT_WRITE,
                          MAP_FIXED | MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (p < 0 && p > -4096) die("mmap segment failed", path);
        if (ph->p_filesz > 0)
            pread_full(fd, (void *)(start + off), ph->p_filesz, ph->p_offset);
    }
    sys_call(__NR_close, fd, 0, 0, 0, 0, 0);

    out->phdr_va = 0;
    for (int i = 0; i < out->ehdr.e_phnum; i++) {
        if (out->phdr[i].p_type == PT_PHDR) {
            out->phdr_va = out->bias + out->phdr[i].p_vaddr;
            break;
        }
    }
    if (!out->phdr_va) {
        for (int i = 0; i < out->ehdr.e_phnum; i++) {
            if (out->phdr[i].p_type == PT_LOAD && out->ehdr.e_phoff >= out->phdr[i].p_offset &&
                out->ehdr.e_phoff < out->phdr[i].p_offset + out->phdr[i].p_filesz) {
                out->phdr_va = out->bias + out->phdr[i].p_vaddr + (out->ehdr.e_phoff - out->phdr[i].p_offset);
                break;
            }
        }
    }

    if (cfg) {
        uintptr_t extra_va = out->bias + maxva;
        long p = sys_call(__NR_mmap, (long)extra_va, PAGE_SIZE, PROT_READ | PROT_WRITE,
                          MAP_FIXED | MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (p < 0 && p > -4096) die("mmap extra page failed", path);
        apply_all_patches(out, cfg, verbose);
        if (cfg->trap_sigsys)
            apply_sigsys_guards(out, verbose);
    }

    if (inject_runpath && out->phdr_va) {
        uintptr_t extra_va = out->bias + maxva;
        Elf64_Phdr *mem_phdr = (Elf64_Phdr *)out->phdr_va;
        for (int i = 0; i < out->ehdr.e_phnum; i++) {
            if (mem_phdr[i].p_type == PT_DYNAMIC) {
                Elf64_Dyn *orig_dyn = (Elf64_Dyn *)(out->bias + mem_phdr[i].p_vaddr);
                Elf64_Dyn *new_dyn = (Elf64_Dyn *)extra_va;
                char *rpath_str = (char *)(extra_va + 2048);
                size_t rlen = z_strlen(inject_runpath);
                z_memcpy(rpath_str, inject_runpath, rlen + 1);
                uintptr_t strtab_vaddr = 0;
                int count = 0;
                for (; orig_dyn[count].d_tag != DT_NULL; count++) {
                    if (orig_dyn[count].d_tag == DT_RUNPATH || orig_dyn[count].d_tag == DT_RPATH)
                        continue;
                    new_dyn[count] = orig_dyn[count];
                    if (orig_dyn[count].d_tag == DT_STRTAB)
                        strtab_vaddr = orig_dyn[count].d_un.d_ptr;
                }
                new_dyn[count].d_tag = DT_RUNPATH;
                new_dyn[count].d_un.d_val = (maxva + 2048) - strtab_vaddr;
                count++;
                new_dyn[count].d_tag = DT_NULL;
                new_dyn[count].d_un.d_val = 0;
                count++;
                mem_phdr[i].p_vaddr = maxva;
                mem_phdr[i].p_paddr = maxva;
                mem_phdr[i].p_filesz = (uint64_t)count * sizeof(Elf64_Dyn);
                mem_phdr[i].p_memsz = (uint64_t)count * sizeof(Elf64_Dyn);
                break;
            }
        }
    }

    for (int i = 0; i < out->ehdr.e_phnum; i++) {
        const Elf64_Phdr *ph = &out->phdr[i];
        if (ph->p_type != PT_LOAD) continue;
        uintptr_t off = ph->p_vaddr & (PAGE_SIZE - 1);
        uintptr_t start = out->bias + TRUNC_PG(ph->p_vaddr);
        size_t size = ROUND_PG(ph->p_memsz + off);
        int prot = ((ph->p_flags & PF_R) ? PROT_READ : 0) |
                   ((ph->p_flags & PF_W) ? PROT_WRITE : 0) |
                   ((ph->p_flags & PF_X) ? PROT_EXEC : 0);
        if (mprotect_hm((void *)start, size, prot) < 0)
            die("mprotect segment failed", path);
    }
    out->entry = out->bias + out->ehdr.e_entry;
}

static const char *get_env(char **envp, const char *key) {
    size_t klen = z_strlen(key);
    for (char **e = envp; *e; e++) {
        if (z_strncmp(*e, key, klen) == 0 && (*e)[klen] == '=')
            return *e + klen + 1;
    }
    return NULL;
}

__asm__(
".text\n"
".align 4\n"
".globl _start\n"
"_start:\n"
"    mov x29, #0\n"
"    mov x30, #0\n"
"    mov x0, sp\n"
"    bl c_entry\n"
"    wfi\n"
".globl jump_to_entry\n"
"jump_to_entry:\n"
"    mov sp, x1\n"
"    mov x2, x0\n"
"    mov x0, #0\n"
"    mov x29, #0\n"
"    mov x30, #0\n"
"    br x2\n"
".align 4\n"
".hidden __sigsys_restorer\n"
".globl __sigsys_restorer\n"
"__sigsys_restorer:\n"
"    mov x8, #139\n"
"    svc #0\n"
".align 4\n"
".hidden __sigsys_handler\n"
".globl __sigsys_handler\n"
"__sigsys_handler:\n"
"    mov x3, #-38\n"
"    str x3, [x2, #184]\n"
"    ret\n"
".align 4\n"
".hidden __hook_go_rt_sigaction\n"
".globl __hook_go_rt_sigaction\n"
"__hook_go_rt_sigaction:\n"
"    ldr x0, [sp, #8]\n"
"    ldr x1, [sp, #16]\n"
"    ldr x2, [sp, #24]\n"
"    cmp x0, #31\n"
"    b.eq 2f\n"
"    ldr x3, [sp, #32]\n"
"    mov x8, #134\n"
"    svc #0\n"
"    str w0, [sp, #40]\n"
"    ret\n"
"2:\n"
"    cbz x2, 3f\n"
"    stp xzr, xzr, [x2]\n"
"    stp xzr, xzr, [x2, #16]\n"
"3:\n"
"    str wzr, [sp, #40]\n"
"    ret\n"
".align 4\n"
".hidden __hook_go_rtsigprocmask\n"
".globl __hook_go_rtsigprocmask\n"
"__hook_go_rtsigprocmask:\n"
"    ldrsw x0, [sp, #8]\n"
"    ldr   x1, [sp, #16]\n"
"    ldr   x2, [sp, #24]\n"
"    ldrsw x3, [sp, #32]\n"
"    cbz   x1, 4f\n"
"    cmp   w0, #1\n"
"    b.eq  4f\n"
"    ldr   x4, [x1]\n"
"    bic   x4, x4, #0x40000000\n"
"    str   x4, [sp, #-16]!\n"
"    mov   x1, sp\n"
"    mov   x8, #135\n"
"    svc   #0\n"
"    add   sp, sp, #16\n"
"    b     5f\n"
"4:\n"
"    mov   x8, #135\n"
"    svc   #0\n"
"5:\n"
"    cmn   x0, #4095\n"
"    b.lo  6f\n"
"    mov   x0, xzr\n"
"    str   x0, [x0]\n"
"6:\n"
"    ret\n"
".align 4\n"
".hidden __hook_plt_sigaction\n"
".globl __hook_plt_sigaction\n"
"__hook_plt_sigaction:\n"
"    cmp  w0, #31\n"
"    b.eq 7f\n"
"    adrp x16, g_got_sigaction\n"
"    ldr  x16, [x16, :lo12:g_got_sigaction]\n"
"    ldr  x17, [x16]\n"
"    br   x17\n"
"7:\n"
"    cbz  x2, 9f\n"
"    mov  x3, #152\n"
"8:\n"
"    subs x3, x3, #8\n"
"    str  xzr, [x2, x3]\n"
"    b.hi 8b\n"
"9:\n"
"    mov  w0, #0\n"
"    ret\n"
".align 4\n"
".hidden __hook_plt_pthread_sigmask\n"
".globl __hook_plt_pthread_sigmask\n"
"__hook_plt_pthread_sigmask:\n"
"    adrp x16, g_got_pthread_sigmask\n"
"    ldr  x16, [x16, :lo12:g_got_pthread_sigmask]\n"
"    b    10f\n"
".align 4\n"
".hidden __hook_plt_sigprocmask\n"
".globl __hook_plt_sigprocmask\n"
"__hook_plt_sigprocmask:\n"
"    adrp x16, g_got_sigprocmask\n"
"    ldr  x16, [x16, :lo12:g_got_sigprocmask]\n"
"10:\n"
"    cbz  x1, 11f\n"
"    cmp  w0, #1\n"
"    b.eq 11f\n"
"    sub  sp, sp, #144\n"
"    str  x30, [sp, #128]\n"
"    ldp  x3, x4, [x1]\n"
"    bic  x3, x3, #0x40000000\n"
"    stp  x3, x4, [sp]\n"
"    ldp  x3, x4, [x1, #16]\n"
"    stp  x3, x4, [sp, #16]\n"
"    ldp  x3, x4, [x1, #32]\n"
"    stp  x3, x4, [sp, #32]\n"
"    ldp  x3, x4, [x1, #48]\n"
"    stp  x3, x4, [sp, #48]\n"
"    ldp  x3, x4, [x1, #64]\n"
"    stp  x3, x4, [sp, #64]\n"
"    ldp  x3, x4, [x1, #80]\n"
"    stp  x3, x4, [sp, #80]\n"
"    ldp  x3, x4, [x1, #96]\n"
"    stp  x3, x4, [sp, #96]\n"
"    ldp  x3, x4, [x1, #112]\n"
"    stp  x3, x4, [sp, #112]\n"
"    mov  x1, sp\n"
"    ldr  x17, [x16]\n"
"    blr  x17\n"
"    ldr  x30, [sp, #128]\n"
"    add  sp, sp, #144\n"
"    ret\n"
"11:\n"
"    ldr  x17, [x16]\n"
"    br   x17\n"
".align 4\n"
".hidden __hook_plt_sigfillset\n"
".globl __hook_plt_sigfillset\n"
"__hook_plt_sigfillset:\n"
"    cbz  x0, 13f\n"
"    stp  x0, x30, [sp, #-16]!\n"
"    adrp x16, g_got_sigfillset\n"
"    ldr  x16, [x16, :lo12:g_got_sigfillset]\n"
"    ldr  x17, [x16]\n"
"    blr  x17\n"
"    ldp  x2, x30, [sp], #16\n"
"    cbnz w0, 12f\n"
"    ldr  x3, [x2]\n"
"    bic  x3, x3, #0x40000000\n"
"    str  x3, [x2]\n"
"12:\n"
"    ret\n"
"13:\n"
"    adrp x16, g_got_sigfillset\n"
"    ldr  x16, [x16, :lo12:g_got_sigfillset]\n"
"    ldr  x17, [x16]\n"
"    br   x17\n"
);

void jump_to_entry(uintptr_t entry, unsigned long *sp);

void c_entry(unsigned long *sp) {
    int argc = (int)*sp;
    char **argv = (char **)(sp + 1);
    char **host_env = &argv[argc + 1];
    char **p = host_env;
    while (*p++) ;
    Elf64_auxv_t *auxv = (Elf64_auxv_t *)p;

    int verify_only = 0;
    const char *v_env = get_env(host_env, "ELFPATCH_VERIFY");
    if (v_env && v_env[0] == '1') verify_only = 1;
    int verbose = verify_only;
    const char *dbg_env = get_env(host_env, "ELFPATCH_DEBUG");
    if (dbg_env && dbg_env[0] == '1') verbose = 1;

    char self_path[MAX_PATH_LEN];
    long n = sys_call(__NR_readlinkat, AT_FDCWD, (long)"/proc/self/exe", (long)self_path, sizeof(self_path) - 1, 0, 0);
    if (n <= 0) die("readlink /proc/self/exe failed", NULL);
    self_path[n] = '\0';

    /* Find dirname and basename of /proc/self/exe */
    int last_slash = -1;
    for (int i = 0; self_path[i]; i++) {
        if (self_path[i] == '/') last_slash = i;
    }
    if (last_slash < 0) die("invalid /proc/self/exe", self_path);
    const char *exe_name = self_path + last_slash + 1;

    char bin_dir[MAX_PATH_LEN];
    z_memcpy(bin_dir, self_path, (size_t)last_slash);
    bin_dir[last_slash] = '\0';

    /* Prefix dir is parent of bin_dir (or bin_dir if no parent) */
    char prefix_dir[MAX_PATH_LEN];
    int prev_slash = -1;
    for (int i = 0; i < last_slash; i++) {
        if (bin_dir[i] == '/') prev_slash = i;
    }
    if (prev_slash > 0) {
        z_memcpy(prefix_dir, bin_dir, (size_t)prev_slash);
        prefix_dir[prev_slash] = '\0';
    } else {
        z_strcpy(prefix_dir, bin_dir, sizeof(prefix_dir));
    }

    /* Config can be overridden by ELFPATCH_CONFIG, else <prefix>/libexec/<name>.elfpatch, else <self>.elfpatch */
    char conf_path[MAX_PATH_LEN];
    const char *override_conf = get_env(host_env, "ELFPATCH_CONFIG");
    if (override_conf && override_conf[0]) {
        z_strcpy(conf_path, override_conf, sizeof(conf_path));
    } else {
        z_strcpy(conf_path, prefix_dir, sizeof(conf_path));
        size_t l = z_strlen(conf_path);
        z_strcpy(conf_path + l, "/libexec/", sizeof(conf_path) - l);
        l = z_strlen(conf_path);
        z_strcpy(conf_path + l, exe_name, sizeof(conf_path) - l);
        l = z_strlen(conf_path);
        z_strcpy(conf_path + l, ".elfpatch", sizeof(conf_path) - l);
        if (sys_call(__NR_faccessat, AT_FDCWD, (long)conf_path, 0, 0, 0, 0) < 0) {
            z_strcpy(conf_path, self_path, sizeof(conf_path));
            l = z_strlen(conf_path);
            z_strcpy(conf_path + l, ".elfpatch", sizeof(conf_path) - l);
        }
    }

    static struct loader_config cfg;
    parse_config(conf_path, prefix_dir, &cfg);
    if (!cfg.program[0]) die("no PROGRAM specified in config", conf_path);

    static struct loaded_elf prog, interp;
    load_elf(cfg.program, &prog, &cfg, verbose);

    if (verify_only) {
        write_str(2, "[elf-patch] verification passed for ");
        write_str(2, cfg.program);
        write_str(2, "\n");
        sys_call(__NR_exit_group, 0, 0, 0, 0, 0, 0);
    }

    int has_interp = 0;
    char interp_path[MAX_PATH_LEN];
    interp_path[0] = '\0';
    if (cfg.interp[0]) {
        z_strcpy(interp_path, cfg.interp, sizeof(interp_path));
        has_interp = 1;
    } else {
        for (int i = 0; i < prog.ehdr.e_phnum; i++) {
            if (prog.phdr[i].p_type == PT_INTERP && prog.phdr[i].p_filesz < sizeof(interp_path)) {
                z_memcpy(interp_path, (void *)(prog.bias + prog.phdr[i].p_vaddr), prog.phdr[i].p_filesz);
                interp_path[prog.phdr[i].p_filesz] = '\0';
                has_interp = 1;
                break;
            }
        }
    }

    if (has_interp) {
        load_elf(interp_path, &interp, NULL, 0);
    }

    /* Build new stack if ENV entries are configured */
    unsigned long *new_sp = sp;
    if (cfg.env_count > 0) {
        static Elf64_auxv_t saved_auxv[128];
        int host_envc = 0;
        while (host_env[host_envc]) host_envc++;
        int auxc = 0;
        while (auxv[auxc].a_type != AT_NULL && auxc < 127) {
            saved_auxv[auxc] = auxv[auxc];
            auxc++;
        }
        saved_auxv[auxc].a_type = AT_NULL;
        saved_auxv[auxc].a_un.a_val = 0;
        auxc++;

        int extra_envs = cfg.env_count;
        unsigned long *shifted_sp = sp - (extra_envs * 2);
        shifted_sp = (unsigned long *)((uintptr_t)shifted_sp & ~15UL);
        new_sp = shifted_sp;
        new_sp[0] = (unsigned long)argc;
        char **dst_argv = (char **)(new_sp + 1);
        for (int i = 0; i < argc; i++) dst_argv[i] = argv[i];
        dst_argv[argc] = NULL;
        char **dst_env = dst_argv + argc + 1;
        int out_e = 0;
        for (int i = 0; i < host_envc; i++) dst_env[out_e++] = host_env[i];
        for (int i = 0; i < cfg.env_count; i++) {
            const char *kv = cfg.envs[i];
            const char *eq = kv;
            while (*eq && *eq != '=') eq++;
            size_t klen = (size_t)(eq - kv) + 1;
            int replaced = 0;
            for (int j = 0; j < out_e; j++) {
                if (z_strncmp(dst_env[j], kv, klen) == 0) {
                    dst_env[j] = (char *)kv;
                    replaced = 1;
                    break;
                }
            }
            if (!replaced) dst_env[out_e++] = (char *)kv;
        }
        dst_env[out_e] = NULL;
        Elf64_auxv_t *dst_aux = (Elf64_auxv_t *)(dst_env + out_e + 1);
        for (int i = 0; i < auxc; i++) dst_aux[i] = saved_auxv[i];
        auxv = dst_aux;
    }

    for (Elf64_auxv_t *av = auxv; av->a_type != AT_NULL; av++) {
        switch (av->a_type) {
        case AT_PHDR:   av->a_un.a_val = prog.phdr_va; break;
        case AT_PHNUM:  av->a_un.a_val = prog.ehdr.e_phnum; break;
        case AT_PHENT:  av->a_un.a_val = prog.ehdr.e_phentsize; break;
        case AT_ENTRY:  av->a_un.a_val = prog.entry; break;
        case AT_BASE:   av->a_un.a_val = has_interp ? interp.bias : 0; break;
        case AT_EXECFN: av->a_un.a_val = (uint64_t)argv[0]; break;
        }
    }

    if (cfg.trap_sigsys)
        install_sigsys_trap(verbose);

    sys_call(__NR_prctl, PR_SET_NAME, (long)exe_name, 0, 0, 0, 0);
    jump_to_entry(has_interp ? interp.entry : prog.entry, new_sp);
}
