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
  depends_on "binary-sign-tool" => :build
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
    file "patches/bun/0002-fix-resolver-traversal.patch"
    file "patches/bun/0003-fix-hmdfs-filesystem.patch"
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

  def install
    ohos_sign_tool = Formula["nknkol/cask/binary-sign-tool"].opt_bin/"binary-sign-tool-fix"

    # Avoid `rustup` dependency by removing usage of nightly Rust features
    inreplace "scripts/build/deps/lolhtml.ts", "if (cfg.release && canBuildStdImmediateAbort)", "if (false)"

    # Use native CPU target for HarmonyOS
    inreplace "scripts/build/zig.ts", "-Dcpu=${zigCpu(cfg)}", "-Dcpu=native"

    sign_elf_script = buildpath/"scripts/sign-ohos-elf"
    sign_elf_script.write <<~SH
      #!/usr/bin/env bash
      set -euo pipefail

      BTS="#{ohos_sign_tool}"

      is_elf() {
        [ -f "$1" ] || return 1
        [ "$(dd if="$1" bs=4 count=1 2>/dev/null)" = "$(printf '\\177ELF')" ]
      }

      sign_one() {
        local file="$1"
        local signed="${file}.signed.$$"

        is_elf "$file" || return 0
        case "$file" in
          *.o|*.a|*.rlib) return 0 ;;
        esac

        if "$BTS" display-sign -inFile "$file" 2>/dev/null | grep -q "code signature is self-sign"; then
          return 0
        fi

        rm -f "$signed"
        "$BTS" sign -selfSign 1 -inFile "$file" -outFile "$signed" >/dev/null
        chmod 0755 "$signed"
        mv -f "$signed" "$file"
      }

      for root in "$@"; do
        [ -e "$root" ] || continue
        if [ -f "$root" ]; then
          sign_one "$root"
          continue
        fi

        find "$root" -type f ! -name '*.o' ! -name '*.a' ! -name '*.rlib' -print0 |
          while IFS= read -r -d '' file; do
            sign_one "$file"
          done
      done
    SH
    sign_elf_script.chmod 0755

    inreplace "scripts/build/zig.ts",
              "  // ─── Write stamp ───\n  await writeFile(stampPath, commit + \"\\n\");",
              "  const ohosSignElf = process.env.BUN_OHOS_SIGN_ELF;\n  if (ohosSignElf) {\n    const proc = Bun.spawn({ cmd: [ohosSignElf, dest], stdout: \"inherit\", stderr: \"inherit\" });\n    const exitCode = await proc.exited;\n    assert(exitCode === 0, `HarmonyOS ELF signing failed for ${dest}`);\n  }\n\n  // ─── Write stamp ───\n  await writeFile(stampPath, commit + \"\\n\");"

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

    # hmdfs does not support hardlink(2). The bootstrap bun patches

    # bun install can hit transient tarball integrity/extraction failures on
    # HarmonyOS. Retry, but only stamp success after a completed install.
    inreplace "scripts/build/codegen.ts",
              ': `cd $dir && ${bun} install --frozen-lockfile && ${touch} $stamp`,',
              ': `cd $dir && (${bun} install --frozen-lockfile || ${bun} install --frozen-lockfile || ${bun} install --frozen-lockfile) && "' +
                sign_elf_script.to_s +
                '" "' +
                (buildpath/".brew_home/.bun/install/cache").to_s +
                '" "$dir/node_modules" && ${touch} $stamp`,'

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
    ENV["BUN_OHOS_SIGN_ELF"] = sign_elf_script.to_s
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

    # Link against libgcc + OHOS SDK static runtime.
    libgcc_prefix = Formula["libgcc"].opt_prefix
    ohos_lib = Formula["ohos-sdk"].opt_prefix/"native/llvm/lib/aarch64-linux-ohos"
    ENV.append "LDFLAGS",
      "-static-libstdc++ -static-libgcc -l:libatomic.a " \
      "-L#{libgcc_prefix}/lib/gcc/aarch64-unknown-linux-musl/16 " \
      "-L#{ohos_lib}"

    # Bypass "bun run" — it walks up directories to find project root,
    # hitting /storage/Users/ which has no read permission on HarmonyOS.
    # Equivalent to: bun run build:release:local --canary=off
    system "bun", "scripts/build.ts", "--profile=release-local", "--build-dir=build/release-local", "--canary=off"
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
        #!/bin/bash
        echo 'ERROR: Need to run `brew postinstall #{name}`' >&2
        exit 1
      SHELL
    end
  end

  def post_install
    if (prefix/"bun.gz").exist?
      system "gunzip", prefix/"bun.gz"
      (prefix/"bun").chmod 0755
      bin.install prefix/"bun"
    end
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
