# glibc HarmonyOS 补丁

`glibc-harmonyos.patch` 是相对于 **glibc 2.38 官方源码** 的补丁（`diff -ruN a b`
格式，用 `patch -p1` 应用），用于让 glibc 能在 HarmonyOS（HongMeng 内核）上正确
加载并运行 glibc-linked Linux ELF。

> 重新生成补丁时，先在官方源码上改好，再用
> `diff -u a/<file> b/<file> --label a/<file> --label b/<file>` 逐文件输出，
> 保证补丁可直接 `patch -p1` 打到 2.38 源码根目录。

## 背景：鸿蒙内核与标准 Linux 内核的三处不兼容

1. **mmap(PROT_EXEC) 范围限制**：带执行权限的文件映射必须完全落在 ELF 第一个可执行
   LOAD 段内。glibc 的 `_dl_map_segments` 快速路径会一次性映射全部段（含段间空洞）
   并沿用第一段的 `PROT_EXEC`，越界 → `EACCES`。
2. **禁止事后 mprotect 加执行权限**：不能先映射再 `mprotect` 改成可执行。
3. **未实现的 syscall 直接发 SIGSYS**：`rseq`、`clone3`、`close_range` 等新 syscall
   在鸿蒙内核上不返回 `ENOSYS`，而是直接 `SIGSYS` 杀进程，于是 glibc「仅在 ENOSYS
   时回退」的逻辑永远走不到。

## 补丁内容（5 处）

| 文件 | 改动 |
|---|---|
| `elf/dl-map-segments.h` | 整段先以不带 EXEC 映射，再用 `MAP_FIXED` 只对第一个可执行段的精确范围恢复 EXEC |
| `sysdeps/unix/sysv/linux/rseq-internal.h` | 完全跳过 rseq syscall，直接标记注册失败 |
| `sysdeps/unix/sysv/linux/clone-internal.c` | `__clone_internal` 不再尝试 clone3，直接走 legacy clone |
| `sysdeps/unix/sysv/linux/spawni.c` | `posix_spawn` 不再直接调用 clone3，也不再直接 `INLINE_SYSCALL_CALL (close_range, ...)`，分别走 `__clone_internal_fallback` / `__closefrom_fallback` |
| `sysdeps/unix/sysv/linux/syscalls.list` | 注释掉 `close_range` 条目，让 `io/close_range.c` 的 `close(2)` 循环实现生效，不再生成 syscall stub |

关键点：aarch64 的 `sysdeps/unix/sysv/linux/aarch64/sysdep.h` **定义了
`HAVE_CLONE3_WRAPPER`**，所以 clone3 在 `clone-internal.c`（`__clone_internal`，
线程创建路径）和 `spawni.c`（`posix_spawn`）**两处**都会被直接调用，两处都必须改。
`close_range` 则由 `syscalls.list` 生成 syscall stub，覆盖了 `io/close_range.c`，
所以要改的是 `syscalls.list` 而不是 `io/close_range.c`。

## 构建：在 loh 的 openEuler 24.03 LTS-SP3 内原生编译

**loh 子系统是构建机，不是产物来源。** 子系统自带的 glibc 是 openEuler 发行版二进制
（`.comment` 为 `GCC 12.3.1 (openEuler ...)`），带自己的发行版改动，且**不含本补丁**
（实测其 `libc.so.6` 里有 `clone3`、`close_range` syscall）。不要把子系统里的
`.so` 直接提取出来当产物。

```sh
# 依赖（一次即可）
dnf install -y gcc gcc-c++ make binutils glibc-devel kernel-headers bison flex patch cpio

# 源码：锁定 2.38
curl -fSLO https://mirrors.tuna.tsinghua.edu.cn/gnu/glibc/glibc-2.38.tar.xz
# sha256 fb82998998b2b29965467bc1b69d152e9c307d2cf301c9eafb4555b770ef3fd2
tar -xf glibc-2.38.tar.xz
cd glibc-2.38
patch -p1 < ../glibc-harmonyos.patch

# 树外构建
mkdir ../build && cd ../build
../glibc-2.38/configure --prefix=/usr --with-headers=/usr/include \
    --disable-werror --disable-nscd
make -j"$(nproc)"
```

打包（strip 后使用 canonical SONAME，且必须是常规文件而非软链；`Formula/glibc.rb`
会跳过符号链接）：

- `elf/ld.so` → `ld-linux-aarch64.so.1`
- `libc.so` → `libc.so.6`、`math/libm.so` → `libm.so.6`、
  `nptl/libpthread.so` → `libpthread.so.0`、`dlfcn/libdl.so` → `libdl.so.2`、
  `resolv/libresolv.so` → `libresolv.so.2`、`rt/librt.so` → `librt.so.1`
- 同一 openEuler 基线的 GCC 运行库：
  `/usr/lib64/{libgcc_s.so.1,libstdc++.so.6,libatomic.so.1}`
  （`libgcc/libstdc++/libatomic-12.3.1-111.oe2403sp3`，提供到 `GLIBCXX_3.4.30`）

产物归档：`bootstrap/glibc-2.38-gcc-12.3.1-harmonyos-arm64.tar.gz`（10 个文件，无顶层目录）。

## 构建后回归检查（必做）

按 aarch64 的 syscall 号反汇编断言：rseq=293、clone3=435、close_range=436。

```sh
objdump -d build/libc.so.6 | grep -E 'mov[[:space:]]+x8, #(293|435|436)'
# 期望：只命中 __clone3 内部一处（见下）
objdump -d build/elf/ld.so | grep -E 'mov[[:space:]]+x8, #(293|435|436)'   # 应为空
```

本补丁构建结果：

- `ld.so` **完全干净**；`libc.so.6` 中 `rseq`、`close_range` 均**已消除**。
- 只剩一个 clone3 site，位于 `aarch64/clone3.S` 的 `__clone3` 内。它唯一的调用者
  `__clone3_internal` 已**没有任何调用者**（属于不可达代码）。CS 层面无法把
  `clone3.S` 从 `sysdeps/unix/sysv/linux/Makefile` 的 `sysdep_routines` 里去掉，
  但该路径不会被执行。
- 运行时冒烟：在 `ld.so --library-path <build>` 下跑 `pthread_create/join` 与
  `posix_spawn` + `addclosefrom_np` 均通过。

## 关键结论

- 鸿蒙 ELF/共享库都必须签名（`binary-sign-tool-fix sign -selfSign 1`）。
- 文件需放在非 hmdfs 锁权限的挂载（如 `/data/storage/el2/base/files`），或通过 HAP
  沙盒权限决定执行权限。
- 符号链接需要实体化（鸿蒙按文件名实体做签名校验）。
- `Formula/glibc.rb` 把所有 glibc/GCC 运行库装到同一个 keg；后续 Linux ELF 只需把
  解释器指向该 keg 的 `ld-linux-aarch64.so.1`，并把该 `lib` 目录加入 RUNPATH。
