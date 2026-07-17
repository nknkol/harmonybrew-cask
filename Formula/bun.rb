class Bun < Formula
  desc "Incredibly fast JavaScript runtime, bundler, test runner, and package manager"
  homepage "https://bun.com/"
  url "https://github.com/oven-sh/bun.git",
      tag:      "bun-v1.3.14",
      revision: "0d9b296af33f2b851fcbf4df3e9ec89751734ba4"
  license all_of: [
    "MIT",
    "LGPL-2.0-or-later", # JavaScriptCore
    "Apache-2.0",        # boringssl, simdutf, uSockets, highway, uWebsockets, Tigerbeetle
    "BSD-2-Clause",      # libarchive, libbase64, libspng
    "BSD-3-Clause",      # lol-html, libwebp, zstd
    "IJG",               # libjpeg-turbo
    "LGPL-2.1-or-later", # tinycc
    "Zlib",              # zlib-ng
    "Apache-2.0" => { with: "LLVM-exception" },
  ]

  bottle do
    root_url "https://github.com/nknkol/harmonybrew-cask/releases/download/bottles%2Fbun"
  end

  depends_on "bash" => :build
  depends_on "nknkol/cask/binary-sign-tool" => :build
  depends_on "cmake" => :build
  depends_on "libgcc" => :build
  depends_on "llvm@21" => :build
  depends_on "ninja" => :build
  depends_on "perl" => :build
  depends_on "ruby" => :build
  depends_on "rust" => :build
  depends_on "icu4c@78"

  fails_with :gcc do
    cause "uses clang-specific flags"
  end

  patch do
    # HarmonyOS platform/filesystem fixes for the bootstrap bun.
    file "patches/bun/0001-fix-platform-syscalls.patch"
  end

  patch do
    file "patches/bun/0002-fix-resolver-traversal.patch"
  end

  patch do
    file "patches/bun/0003-fix-hmdfs-filesystem.patch"
  end

  patch do
    file "patches/bun/0004-fix-harmonyos-path-permissions.patch"
  end

  resource "bootstrap" do
    url "https://raw.githubusercontent.com/nknkol/harmonybrew-cask/main/bootstrap/bun-1.3.14-aarch64-musl.tar.gz"
    version "1.3.14"
    sha256 "133d169ee980ca4a348fa0a711d6ebf3d4f76f11954f45d77a1248269171a550"
  end

  def fetch_webkit
    webkit_version = File.read("scripts/build/deps/webkit.ts")[/WEBKIT_VERSION = "(\h+)"/i, 1]
    odie "Unable to find WebKit version!" if webkit_version.blank?

    clone_args = %W[
      --branch=autobuild-#{webkit_version}
      --config=advice.detachedHead=false
      --config=core.fsmonitor=false
      --depth=1
    ]
    system "git", "clone", *clone_args, "https://github.com/oven-sh/WebKit.git", "vendor/WebKit"
  end

  def sign_tool
    Formula["nknkol/cask/binary-sign-tool"].opt_bin/"binary-sign-tool-fix"
  end

  def llvm_objcopy
    Formula["llvm@21"].opt_bin/"llvm-objcopy"
  end

  def elf_file?(path)
    return false unless path.file?

    path.open("rb") { |f| f.read(4) } == "\x7fELF".b
  rescue
    false
  end

  def sign_elf!(path)
    return unless elf_file?(path)

    unsigned = path.sub_ext("#{path.extname}.unsigned")
    signed = path.sub_ext("#{path.extname}.signed")

    rm_f unsigned
    rm_f signed
    chmod 0755, path

    if quiet_system llvm_objcopy, "--remove-section=.codesign", path, unsigned
      chmod 0755, unsigned
    else
      cp path, unsigned
    end

    # TODO: teach `bun build --compile` to regenerate OHOS .codesign after
    # it rewrites ELF output in src/exe_format/elf.zig.
    system sign_tool, "sign", "-selfSign", "1", "-inFile", unsigned, "-outFile", signed
    chmod 0755, signed
    mv signed, path, force: true
  ensure
    rm_f unsigned if defined?(unsigned) && unsigned
    rm_f signed if defined?(signed) && signed
  end

  def install
    ohos_sign_tool = sign_tool

    # Avoid `rustup` dependency by removing usage of nightly Rust features
    inreplace "scripts/build/deps/lolhtml.ts", "if (cfg.release && canBuildStdImmediateAbort)", "if (false)"

    # Use native CPU target for HarmonyOS
    inreplace "scripts/build/zig.ts", "-Dcpu=${zigCpu(cfg)}", "-Dcpu=native"

    inreplace "scripts/build/zig.ts",
              'import { mkdir, readdir, rename, rm, writeFile } from "node:fs/promises";',
              'import { chmod, mkdir, readdir, rename, rm, writeFile } from "node:fs/promises";'
    inreplace "scripts/build/zig.ts",
              "  assert(existsSync(resolve(dest, \"lib\")), `zig lib/ dir not found`, {\n    hint: \"Archive may be incomplete\",\n  });",
              "  assert(existsSync(resolve(dest, \"lib\")), `zig lib/ dir not found`, {\n    hint: \"Archive may be incomplete\",\n  });\n\n  const ohosSignTool = process.env.BUN_OHOS_SIGN_TOOL;\n  if (ohosSignTool) {\n    for (const exe of [zigExe, resolve(dest, \"zls\")]) {\n      if (!existsSync(exe)) continue;\n      const signed = `${exe}.signed`;\n      await rm(signed, { force: true });\n      const proc = Bun.spawn({\n        cmd: [ohosSignTool, \"sign\", \"-selfSign\", \"1\", \"-inFile\", exe, \"-outFile\", signed],\n        stdout: \"inherit\",\n        stderr: \"inherit\",\n      });\n      const exitCode = await proc.exited;\n      assert(exitCode === 0 && existsSync(signed), `HarmonyOS ELF signing failed for ${exe}`);\n      await chmod(signed, 0o755);\n      await rename(signed, exe);\n    }\n  }"

    zig_wrapper = buildpath/"scripts/zig-ohos"
    zig_wrapper.write <<~SH
      #!/usr/bin/env bash
      set -euo pipefail

      SIGN_TOOL="${BUN_OHOS_SIGN_TOOL:-#{ohos_sign_tool}}"

      cache="${ZIG_LOCAL_CACHE_DIR:-}"
      if [ -z "$cache" ]; then
        prev=""
        for arg in "$@"; do
          if [ "$prev" = "--cache-dir" ]; then
            cache="$arg"
            break
          fi
          prev="$arg"
        done
      fi

      attempts=0
      while true; do
        if "$@"; then
          exit 0
        fi
        status=$?
        attempts=$((attempts + 1))

        signed_any=0
        if [ -n "$cache" ] && [ -d "$cache" ]; then
          while IFS= read -r exe; do
            [ -f "$exe" ] || continue
            if "$SIGN_TOOL" display-sign -inFile "$exe" 2>&1 | grep -q "code signature is not found"; then
              signed="$exe.signed"
              rm -f "$signed"
              "$SIGN_TOOL" sign -selfSign 1 -inFile "$exe" -outFile "$signed"
              [ -f "$signed" ] || { echo "zig build runner sign failed: $exe" >&2; exit 1; }
              chmod 0755 "$signed"
              mv "$signed" "$exe"
              signed_any=1
              echo "[zig-ohos] signed build runner $exe" >&2
            fi
          done < <(find "$cache" -path "*/o/*/build" -type f 2>/dev/null)
        fi

        if [ "$signed_any" != "1" ] || [ "$attempts" -ge 5 ]; then
          exit "$status"
        fi
      done
    SH
    zig_wrapper.chmod 0755
    inreplace "scripts/build/zig.ts",
              'command: `${stream} ${consoleMode ? "--console" : "--zig-progress"} --env=ZIG_LOCAL_CACHE_DIR=$zig_local_cache --env=ZIG_GLOBAL_CACHE_DIR=$zig_global_cache${parallelSema} $zig build $step $args`,',
              "command: `${stream} ${consoleMode ? \"--console\" : \"--zig-progress\"} --env=ZIG_LOCAL_CACHE_DIR=$zig_local_cache --env=ZIG_GLOBAL_CACHE_DIR=$zig_global_cache${parallelSema} #{zig_wrapper} $zig build $step $args`,"
    inreplace "scripts/build/zig.ts",
              'command: `${stream} --console --stamp=$out --env=ZIG_LOCAL_CACHE_DIR=$zig_local_cache --env=ZIG_GLOBAL_CACHE_DIR=$zig_global_cache${parallelSema} $zig build $step $args`,',
              "command: `${stream} --console --stamp=$out --env=ZIG_LOCAL_CACHE_DIR=$zig_local_cache --env=ZIG_GLOBAL_CACHE_DIR=$zig_global_cache${parallelSema} #{zig_wrapper} $zig build $step $args`,"

    # HarmonyOS has llvm-strip but no GNU strip
    inreplace "scripts/build/tools.ts",
              'findTool({ names: ["strip"], required: true, hint: "Install binutils for your distro" })',
              'findTool({ names: ["llvm-strip"], required: true, hint: "Install binutils for your distro" })'

    # Bun.spawnSync uses memfd_create + fstat internally; HarmonyOS kernel
    # returns EACCES on fstat(memfd). Replace with async Bun.spawn.
    # TODO: upstream fix — bun should fall back to pipe when memfd fstat fails.
    inreplace "src/codegen/bundle-modules.ts",
              "const out = Bun.spawnSync({\n  cmd: config_cli,\n  cwd: process.cwd(),\n  env: process.env,\n  stdio: [\"pipe\", \"pipe\", \"pipe\"],\n});\nif (out.exitCode !== 0) {\n  console.error(out.stderr.toString());\n  process.exit(out.exitCode);\n}",
              "const proc = Bun.spawn({\n  cmd: config_cli,\n  cwd: process.cwd(),\n  env: process.env,\n  stdio: [\"pipe\", \"pipe\", \"pipe\"],\n});\nconst exitCode = await proc.exited;\nif (exitCode !== 0) {\n  console.error(await new Response(proc.stderr).text());\n  process.exit(exitCode);\n}"

    # Bun.spawnSync → Bun.spawn in bake-codegen.ts too
    inreplace "src/codegen/bake-codegen.ts",
              "function css(file: string, is_development: boolean): string {\n  const { success, stdout, stderr } = Bun.spawnSync({\n    cmd: [process.execPath, \"build\", file, \"--minify\"],\n    cwd: import.meta.dir,\n    stdio: [\"ignore\", \"pipe\", \"pipe\"],\n  });\n  if (!success) throw new Error(stderr.toString(\"utf-8\"));\n  return stdout.toString(\"utf-8\");\n}",
              "async function css(file: string, is_development: boolean): Promise<string> {\n  const proc = Bun.spawn({\n    cmd: [process.execPath, \"build\", file, \"--minify\"],\n    cwd: import.meta.dir,\n    stdio: [\"ignore\", \"pipe\", \"pipe\"],\n  });\n  const stdout = await new Response(proc.stdout).text();\n  const stderr = await new Response(proc.stderr).text();\n  const exitCode = await proc.exited;\n  if (exitCode !== 0) throw new Error(stderr);\n  return stdout;\n}"
    inreplace "src/codegen/bake-codegen.ts",
              "OVERLAY_CSS: css(",
              "OVERLAY_CSS: await css("

    # WebKit WTF headers use ICU U16_* macros while Bun's PCH includes them
    # through root.h. Include utf16.h first so the PCH compile sees the macros.
    inreplace "src/jsc/bindings/root-pch.h",
              "#include \"root.h\"",
              "#include <unicode/utf16.h>\n\n#include \"root.h\""

    # OHOS exposes pthread cancellation constants but not
    # pthread_setcancelstate in the Native SDK sysroot. Match Android's
    # behavior and skip the cancellation guard around vfork/exec.
    inreplace "src/jsc/bindings/bun-spawn.cpp",
              "#if !OS(ANDROID)\n    pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &cs);\n#endif",
              "#if !OS(ANDROID) && !defined(__OHOS__)\n    pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &cs);\n#endif"
    inreplace "src/jsc/bindings/bun-spawn.cpp",
              "#if !OS(ANDROID)\n    pthread_setcancelstate(cs, 0);\n#else",
              "#if !OS(ANDROID) && !defined(__OHOS__)\n    pthread_setcancelstate(cs, 0);\n#else"

    # OHOS exports libc's environ as an unaligned data symbol. Avoid direct
    # C++ access and use Bun's Zig environment pointer for spawn inheritance.
    inreplace "src/main.zig",
              "pub extern \"c\" var _environ: ?*anyopaque;\npub extern \"c\" var environ: ?*anyopaque;\n\npub fn main() void {",
              "pub extern \"c\" var _environ: ?*anyopaque;\npub extern \"c\" var environ: ?*anyopaque;\n\npub export fn Bun__getEnvironForSpawn() ?*anyopaque {\n    return @ptrCast(std.os.environ.ptr);\n}\n\npub fn main() void {"
    inreplace "src/jsc/bindings/bun-spawn.cpp",
              "extern char** environ;",
              "#if defined(__OHOS__)\nextern \"C\" char** Bun__getEnvironForSpawn();\n#else\nextern char** environ;\n#endif"
    inreplace "src/jsc/bindings/bun-spawn.cpp",
              "        if (!envp)\n            envp = environ;",
              "        if (!envp) {\n#if defined(__OHOS__)\n            envp = Bun__getEnvironForSpawn();\n#else\n            envp = environ;\n#endif\n        }"

    # hmdfs does not support hardlink(2). The bootstrap bun patches

    # bun install can hit transient tarball integrity/extraction failures on
    # HarmonyOS. Retry, but only stamp success after a completed install.
    inreplace "scripts/build/codegen.ts",
              ': `cd $dir && ${bun} install --frozen-lockfile && ${touch} $stamp`,',
              ': `cd $dir && (${bun} install --frozen-lockfile || ${bun} install --frozen-lockfile || ${bun} install --frozen-lockfile) && ${touch} $stamp`,'

    fetch_webkit

    # CMake 4.4 rejects the old WebKit condition when _linked_into is empty
    # because it expands to `WTF STREQUAL` and `NOT IN_LIST ...`.
    inreplace "vendor/WebKit/Source/cmake/WebKitMacros.cmake",
              "if ((NOT _linked_into) OR (${framework} STREQUAL ${_linked_into}) OR (NOT ${_linked_into} IN_LIST ${_target}_FRAMEWORKS))",
              "if ((NOT _linked_into) OR (\"${framework}\" STREQUAL \"${_linked_into}\") OR (NOT \"${_linked_into}\" IN_LIST ${_target}_FRAMEWORKS))"

    # stream.ts truncates WebKit build errors: out.write() is async but
    # process.exit() kills the buffer. Replace with writeSync.
    inreplace "scripts/build/stream.ts",
              "out.write(lead + text);",
              "writeSync(outFd, lead + text);"
    # Create a wrapper that signs the real binary before exec.
    esbuild_wrapper = buildpath/"scripts/esbuild-ohos"
    esbuild_wrapper.write <<~SH
      #!/usr/bin/env bash
      set -e
      BTS="#{HOMEBREW_PREFIX}/bin/binary-sign-tool-fix"
      REAL=$(find "#{buildpath}/node_modules/.bun" -path "*/@esbuild/linux-arm64/bin/esbuild" -type f 2>/dev/null | head -1)
      if [ ! -f "\$REAL" ]; then echo "esbuild not found" >&2; exit 1; fi
      SIGNED="\$REAL.signed"
      LOCK="\$REAL.signed.lock"
      if [ ! -f "\$SIGNED" ]; then
        exec 9>"\$LOCK"
        flock 9
        if [ ! -f "\$SIGNED" ]; then
          "\$BTS" sign -selfSign 1 -inFile "\$REAL" -outFile "\$SIGNED" 2>/dev/null || true
          [ -f "\$SIGNED" ] || { echo "esbuild sign failed" >&2; exit 1; }
        fi
        exec 9>&-
      fi
      exec "\$SIGNED" --preserve-symlinks "\$@"
    SH
    esbuild_wrapper.chmod 0755
    inreplace "scripts/build/configure.ts",
              'node_modules", ".bin", host.os === "windows" ? "esbuild.exe" : "esbuild"',
              'scripts", "esbuild-ohos"'
    # _GNU_SOURCE unconditionally — but skips it on Android. Use that path.
    inreplace "scripts/build/deps/zstd.ts",
              'cflags: ["-DXXH_NAMESPACE=ZSTD_"]',
              'cflags: ["-DXXH_NAMESPACE=ZSTD_", "-D__ANDROID__"]'

    # musl does not implement getservbyport_r / getservbyname_r (GNU).
    # Keep def1 call but pass empty array so generated config omits them.
    inreplace "scripts/build/deps/cares.ts",
              "const LINUX_NETDB_R = def1([\n  \"HAVE_GETSERVBYPORT_R\", \"HAVE_GETSERVBYNAME_R\",\n]);",
              "const LINUX_NETDB_R = def1([]);"

    # Bun's TypeScript build system does not pass Homebrew LDFLAGS through to
    # the final bun-profile link. Put non-default Homebrew library paths in
    # Bun's own system library list.
    libgcc_lib = Formula["libgcc"].opt_lib
    libatomic_a = Formula["libgcc"].opt_lib/"libatomic.a"
    icu_include = Formula["icu4c@78"].opt_include
    icu_lib = Formula["icu4c@78"].opt_lib
    inreplace "scripts/build/flags.ts",
              "  const includes: string[] = [\n",
              "  const includes: string[] = [\n    \"#{icu_include}\",\n"
    inreplace "scripts/build/flags.ts",
              'flag: ["-lstdc++", "-lgcc"],',
              "flag: [\"-L#{libgcc_lib}\", \"-lstdc++\", \"-lgcc\"],"
    inreplace "scripts/build/bun.ts",
              'libs.push("-l:libatomic.a");',
              "libs.push(\"#{libatomic_a}\");"
    inreplace "scripts/build/bun.ts",
              'libs.push("-licudata", "-licui18n", "-licuuc");',
              "libs.push(\"-L#{icu_lib}\", \"-Wl,-rpath,#{icu_lib}\", \"-licudata\", \"-licui18n\", \"-licuuc\");"

    # OHOS libc exports stdout/stderr as unaligned data symbols. Direct C++
    # access emits 64-bit absolute-load relocations that lld rejects on aarch64.
    inreplace "src/jsc/bindings/c-bindings.cpp",
              "#include \"root.h\"\n#include <cstdio>",
              "#include \"root.h\"\n#include <cstdio>\n#include <stdio.h>"
    inreplace "src/jsc/bindings/c-bindings.cpp",
              "extern \"C\" int ffi_vprintf(const char* fmt, va_list ap)\n{\n    int ret = vfprintf(stderr, fmt, ap);\n    fflush(stderr);\n    return ret;\n}",
              "extern \"C\" int ffi_vprintf(const char* fmt, va_list ap)\n{\n#if defined(__OHOS__)\n    return vdprintf(STDERR_FILENO, fmt, ap);\n#else\n    int ret = vfprintf(stderr, fmt, ap);\n    fflush(stderr);\n    return ret;\n#endif\n}"
    inreplace "src/jsc/bindings/c-bindings.cpp",
              "extern \"C\" int ffi_printf(const char* __restrict fmt, ...)\n{\n    va_list ap;\n    va_start(ap, fmt);\n    int r = vprintf(fmt, ap);\n    va_end(ap);\n    fflush(stdout);\n    return r;\n}",
              "extern \"C\" int ffi_printf(const char* __restrict fmt, ...)\n{\n    va_list ap;\n    va_start(ap, fmt);\n#if defined(__OHOS__)\n    int r = vdprintf(STDOUT_FILENO, fmt, ap);\n#else\n    int r = vprintf(fmt, ap);\n    fflush(stdout);\n#endif\n    va_end(ap);\n    return r;\n}"
    inreplace "src/jsc/bindings/BunProcess.cpp",
              "#include \"v8/node.h\"\n\n// Include the CMake-generated dependency versions header",
              "#include \"v8/node.h\"\n#include <stdio.h>\n#include <unistd.h>\n\n// Include the CMake-generated dependency versions header"
    inreplace "src/jsc/bindings/BunProcess.cpp",
              "    fprintf(stderr, \"process.execve failed with error code %s\\n\", errName ? errName : \"UNKNOWN\");\n    fprintf(stderr, \"SystemError [process.execve]: execve %s: %s\\n\", strerror(savedErrno), execPathUtf8.data());\n    fprintf(stderr, \"    at execve (node:internal/process/per_thread:0:0)\\n\");\n    fflush(stderr);",
              "#if defined(__OHOS__)\n    dprintf(STDERR_FILENO, \"process.execve failed with error code %s\\n\", errName ? errName : \"UNKNOWN\");\n    dprintf(STDERR_FILENO, \"SystemError [process.execve]: execve %s: %s\\n\", strerror(savedErrno), execPathUtf8.data());\n    dprintf(STDERR_FILENO, \"    at execve (node:internal/process/per_thread:0:0)\\n\");\n#else\n    fprintf(stderr, \"process.execve failed with error code %s\\n\", errName ? errName : \"UNKNOWN\");\n    fprintf(stderr, \"SystemError [process.execve]: execve %s: %s\\n\", strerror(savedErrno), execPathUtf8.data());\n    fprintf(stderr, \"    at execve (node:internal/process/per_thread:0:0)\\n\");\n    fflush(stderr);\n#endif"
    inreplace "src/jsc/bindings/napi.h",
              "#include \"root.h\"\n#include <JavaScriptCore/DeferGC.h>",
              "#include \"root.h\"\n#include <stdio.h>\n#include <unistd.h>\n#include <JavaScriptCore/DeferGC.h>"
    inreplace "src/jsc/bindings/napi.h",
              "                fprintf(stderr, \"FATAL ERROR: Finalizer is calling a function that may affect GC state.\\n\");\n                fprintf(stderr, \"The finalizers are run directly from GC and must not affect GC state.\\n\");\n                fprintf(stderr, \"Use `node_api_post_finalizer` from inside of the finalizer to work around this issue.\\n\");\n                fprintf(stderr, \"It schedules the call as a new task in the event loop.\\n\");\n                fflush(stderr);",
              "#if defined(__OHOS__)\n                dprintf(STDERR_FILENO, \"FATAL ERROR: Finalizer is calling a function that may affect GC state.\\n\");\n                dprintf(STDERR_FILENO, \"The finalizers are run directly from GC and must not affect GC state.\\n\");\n                dprintf(STDERR_FILENO, \"Use `node_api_post_finalizer` from inside of the finalizer to work around this issue.\\n\");\n                dprintf(STDERR_FILENO, \"It schedules the call as a new task in the event loop.\\n\");\n#else\n                fprintf(stderr, \"FATAL ERROR: Finalizer is calling a function that may affect GC state.\\n\");\n                fprintf(stderr, \"The finalizers are run directly from GC and must not affect GC state.\\n\");\n                fprintf(stderr, \"Use `node_api_post_finalizer` from inside of the finalizer to work around this issue.\\n\");\n                fprintf(stderr, \"It schedules the call as a new task in the event loop.\\n\");\n                fflush(stderr);\n#endif"
    inreplace "src/jsc/bindings/node/http/llhttp/api.c",
              "#include <stdio.h>\n#include <string.h>",
              "#include <stdio.h>\n#include <string.h>\n#include <unistd.h>"
    inreplace "src/jsc/bindings/node/http/llhttp/api.c",
              "    if (p == endp) {\n        fprintf(stderr, \"p=%p type=%d flags=%02x next=null debug=%s\\n\", s, s->type,\n            s->flags, msg);\n    } else {\n        fprintf(stderr, \"p=%p type=%d flags=%02x next=%02x   debug=%s\\n\", s,\n            s->type, s->flags, *p, msg);\n    }",
              "    if (p == endp) {\n#if defined(__OHOS__)\n        dprintf(STDERR_FILENO, \"p=%p type=%d flags=%02x next=null debug=%s\\n\", s, s->type,\n            s->flags, msg);\n#else\n        fprintf(stderr, \"p=%p type=%d flags=%02x next=null debug=%s\\n\", s, s->type,\n            s->flags, msg);\n#endif\n    } else {\n#if defined(__OHOS__)\n        dprintf(STDERR_FILENO, \"p=%p type=%d flags=%02x next=%02x   debug=%s\\n\", s,\n            s->type, s->flags, *p, msg);\n#else\n        fprintf(stderr, \"p=%p type=%d flags=%02x next=%02x   debug=%s\\n\", s,\n            s->type, s->flags, *p, msg);\n#endif\n    }"
    inreplace "src/jsc/bindings/workaround-missing-symbols.cpp",
              "#endif // glibc\n\n// musl",
              <<~'EOS'
                #endif // glibc

                #if defined(__OHOS__)
                #include <errno.h>
                #include <fcntl.h>
                #include <math.h>
                #include <stdarg.h>
                #include <stdlib.h>
                #include <sys/random.h>
                #include <sys/stat.h>
                #include <sys/syscall.h>
                #include <unistd.h>

                extern "C" {

                float __wrap_expf(float x) { return expf(x); }
                float __wrap_powf(float x, float y) { return powf(x, y); }
                float __wrap_logf(float x) { return logf(x); }
                float __wrap_log2f(float x) { return log2f(x); }
                double __wrap_exp(double x) { return exp(x); }
                double __wrap_exp2(double x) { return exp2(x); }
                double __wrap_pow(double x, double y) { return pow(x, y); }
                double __wrap_log(double x) { return log(x); }
                double __wrap_log2(double x) { return log2(x); }

                [[noreturn]] void __wrap_quick_exit(int code)
                {
                    _Exit(code);
                }

                ssize_t __wrap_getrandom(void* buf, size_t buflen, unsigned int flags)
                {
                    return syscall(SYS_getrandom, buf, buflen, flags);
                }

                int __wrap_fcntl64(int fd, int cmd, ...)
                {
                    va_list ap;
                    va_start(ap, cmd);
                    void* arg = va_arg(ap, void*);
                    va_end(ap);
                    return fcntl(fd, cmd, arg);
                }

                int lchmod(const char*, mode_t)
                {
                    errno = EOPNOTSUPP;
                    return -1;
                }

                } // extern "C"
                #endif

                // musl
              EOS
    inreplace "src/jsc/bindings/BunProcess.cpp",
              "#ifdef __GNU_LIBRARY__\n        header->putDirect(vm, JSC::Identifier::fromString(vm, \"glibcVersionCompiler\"_s), JSC::jsString(vm, makeString(__GLIBC__, '.', __GLIBC_MINOR__)), 0);",
              "#if defined(__GNU_LIBRARY__) && !defined(__OHOS__)\n        header->putDirect(vm, JSC::Identifier::fromString(vm, \"glibcVersionCompiler\"_s), JSC::jsString(vm, makeString(__GLIBC__, '.', __GLIBC_MINOR__)), 0);"
    inreplace "src/runtime/node/node_fs.zig",
              "        if (comptime Environment.isAndroid) {\n            // bionic has no lchmod(); symlink modes are meaningless on Linux",
              "        if (comptime Environment.isAndroid or Environment.isMusl) {\n            // bionic/musl have no lchmod(); symlink modes are meaningless on Linux"
    inreplace "src/napi/napi.zig",
              "} else if (bun.Environment.isMac or bun.Environment.isFreeBSD) struct {\n    // FreeBSD's base libc++ uses the same `std::__1::` inline namespace as Apple's.",
              "} else if (bun.Environment.isMac or bun.Environment.isFreeBSD or bun.Environment.isMusl) struct {\n    // FreeBSD's base libc++ and Harmonybrew's musl toolchain use the same `std::__1::` inline namespace as Apple's."

    # rustc_wrapper uses #!/bin/bash which doesn't exist on HarmonyOS.
    # (May already be fixed from a previous run — only inreplace if needed.)
    wrapper = HOMEBREW_LIBRARY/"Homebrew/shims/shared/rustc_wrapper"
    if File.read(wrapper).include?("#!/bin/bash")
      inreplace wrapper, "#!/bin/bash", "#!/usr/bin/env bash"
    end

    # mimalloc static.c compiled as C++; llvm@21's libc++ stddef.h wrapper
    # fails to define size_t (missing __need_size_t). Compile as C instead.
    inreplace "scripts/build/deps/mimalloc.ts",
              "lang: \"cxx\"",
              "lang: \"c\""

    build_fallbacks = "src/node-fallbacks/build-fallbacks.ts"
    inreplace build_fallbacks,
              "let commands: Promise<void>[] = [];\n",
              <<~'EOS'
                let commands: Promise<void>[] = [];

                const harmonyDebugResolver = process.env.BUN_HARMONY_DEBUG_RESOLVER;
                const harmonyDebugEnabled = harmonyDebugResolver === "1" || harmonyDebugResolver === "true";

                function harmonyDebugLog(message: string) {
                  if (!harmonyDebugEnabled) return;
                  console.error(`[bun-harmony-debug] build-fallbacks.${message}`);
                }

                harmonyDebugLog(`start cwd="${process.cwd()}" outdir="${outdir}" execPath="${process.execPath}" bunWhich="${Bun.which("bun") ?? ""}" debug="${harmonyDebugResolver ?? ""}" PATH="${process.env.PATH ?? ""}"`);
              EOS
    inreplace build_fallbacks,
              "  // Create the build command with all the specified options\n  const buildCommand =\n",
              "  // Create the build command with all the specified options\n  harmonyDebugLog(`child.start file=\"${name}\" mod=\"${mod}\" execPath=\"${process.execPath}\" bunWhich=\"${Bun.which(\"bun\") ?? \"\"}\"`);\n  const buildCommand =\n"
    inreplace build_fallbacks,
              "    buildCommand.then(async text => {\n",
              "    buildCommand.then(async text => {\n      harmonyDebugLog(`child.ok file=\"${name}\" stdout_len=${text.length}`);\n"
    inreplace build_fallbacks,
              "      await Bun.write(`${outdir}/${name}`, outfile);\n    }),\n",
              <<~'EOS'
                      await Bun.write(`${outdir}/${name}`, outfile);
                    }).catch(error => {
                      harmonyDebugLog(`child.fail file="${name}" execPath="${process.execPath}" bunWhich="${Bun.which("bun") ?? ""}"`);
                      const stdout = String(error?.stdout ?? "");
                      const stderr = String(error?.stderr ?? "");
                      if (stdout.length > 0) console.error(`[bun-harmony-debug] build-fallbacks.child.stdout file="${name}"\n${stdout}`);
                      if (stderr.length > 0) console.error(`[bun-harmony-debug] build-fallbacks.child.stderr file="${name}"\n${stderr}`);
                      throw error;
                    }),
              EOS

    resource("bootstrap").stage("bootstrap")
    ENV["BUN_OHOS_SIGN_TOOL"] = ohos_sign_tool.to_s
    ENV["BUN_HARMONY_DEBUG_RESOLVER"] = "1"
    # Prepend bootstrap to PATH BEFORE the superenv shims, so bun's configure
    # picks the right clang (shims resolve to OHOS SDK LLVM15, not llvm@21).
    ENV.prepend_path "PATH", buildpath/"bootstrap"

    # Force llvm@21 clang++ (C++23). Must be before shims in PATH.
    # clang doesn't auto-detect our C++ headers; clang++.cfg handles that.
    ENV.prepend_path "PATH", Formula["llvm@21"].opt_bin.to_s

    # cmake doesn't recognize HarmonyOS natively → CMAKE_SYSTEM_NAME stays
    # "HarmonyOS", UNIX=FALSE. That breaks every `if (UNIX)` check across
    # WebKit's cmake files (Socket.cmake picks Windows sources, options
    # default to C_LOOP, etc.). Force Linux so cmake sets UNIX=1,
    # CMAKE_SYSTEM_PROCESSOR=aarch64, and all platform detection works.
    inreplace "scripts/build/deps/webkit.ts",
              'ENABLE_FTL_JIT: "ON",',
              "ENABLE_FTL_JIT: \"ON\",\n      CMAKE_SYSTEM_NAME: \"Linux\",\n      CMAKE_SYSTEM_PROCESSOR: \"aarch64\","

    # ArithProfile.h uses `friend class JSC::LLIntOffsetsExtractor` (qualified)
    # which requires a prior declaration in C++23. Every other header uses
    # unqualified `friend class LLIntOffsetsExtractor`. Fix consistency.
    inreplace "vendor/WebKit/Source/JavaScriptCore/bytecode/ArithProfile.h",
              "friend class JSC::LLIntOffsetsExtractor;",
              "friend class LLIntOffsetsExtractor;"
    # Replace with /usr/bin/env bash which resolves via PATH.
    # Two passes: .sh/.pl/.py glob, then extensionless scripts in scripts dirs.
    Dir.glob("vendor/WebKit/**/*.{sh,pl,py}").each do |f|
      next unless File.read(f, 20)&.start_with?("#!/bin/bash")
      inreplace f, "#!/bin/bash", "#!/usr/bin/env bash"
    end
    Dir.glob("vendor/WebKit/Source/*/Scripts/*").each do |f|
      next unless File.file?(f) && File.read(f, 20)&.start_with?("#!/bin/bash")
      inreplace f, "#!/bin/bash", "#!/usr/bin/env bash"
    end

    # Link against OHOS SDK static runtime.
    ohos_lib = Formula["ohos-sdk"].opt_prefix/"native/llvm/lib/aarch64-linux-ohos"
    ENV.append "LDFLAGS",
      "-static-libstdc++ -static-libgcc -L#{ohos_lib}"

    # Bypass "bun run" — it walks up directories to find project root,
    # hitting /storage/Users/ which has no read permission on HarmonyOS.
    # Equivalent to: bun run build:release:local --canary=off
    system "bun", "scripts/build.ts", "--profile=release-local", "--build-dir=build/release-local", "--canary=off", "--abi=musl"
    sign_elf! buildpath/"build/release-local/bun"
    bin.install "build/release-local/bun"
    bin.install_symlink bin/"bun" => "bunx"

    bash_completion.install "completions/bun.bash" => "bun"
    fish_completion.install "completions/bun.fish"
    zsh_completion.install "completions/bun.zsh" => "_bun"

    # Work around patchelf corrupting the binary and causing segfault.
    if build.bottle?
      prefix.install bin/"bun"
      Utils::Gzip.compress(prefix/"bun")
      (bin/"bun").write <<~SHELL
        #!/usr/bin/env bash
        echo 'ERROR: Need to run `brew postinstall #{name}`' >&2
        exit 1
      SHELL
    end
  end

  def post_install
    if (prefix/"bun.gz").exist?
      system "gunzip", prefix/"bun.gz"
      (prefix/"bun").chmod 0755
      sign_elf! prefix/"bun"
      bin.install prefix/"bun"
    end
    sign_elf! bin/"bun"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/bun --version")
    refute_match "canary", shell_output("#{bin}/bun --revision")

    system bin/"bun", "init", "--yes"
    assert_equal "Hello via Bun!", shell_output("#{bin}/bun run index.ts").chomp

    system bin/"bun", "build", "--compile", "--outfile=test", "index.ts"
    assert_equal "Hello via Bun!", shell_output("./test").chomp

    assert_match "< hello bun >", shell_output("#{bin}/bunx cowsay hello bun")

    (testpath/"db.ts").write <<~TYPESCRIPT
      import { Database } from "bun:sqlite";
      const db = new Database(":memory:");
      db.run("create table students (name text, age integer)");
      db.run("insert into students (name, age) values ('Bob', 14)");
      db.run("insert into students (name, age) values ('Sue', 12)");
      db.run("insert into students (name, age) values ('Tim', 13)");
      const query = db.query("select name from students order by age asc");
      console.log(query.values().flat());
    TYPESCRIPT
    assert_equal '[ "Sue", "Tim", "Bob" ]', shell_output("#{bin}/bun run db.ts").chomp
  end
end
