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

  depends_on "cmake" => :build
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
    # Fix bun run / bun build traversal failing when parent directories
    # have no read permission (e.g. /storage/Users/ on HarmonyOS).
    file "patches/bun/0001-fix-run-command-traversal.patch"
    # Also fix the resolver's directory traversal (used by bun build / bun
    # run subprocesses spawned during codegen).
    file "patches/bun/0002-fix-resolver-traversal.patch"
  end

  resource "bootstrap" do
    url "https://raw.githubusercontent.com/nknkol/harmonybrew-cask/main/bootstrap/bun-1.3.14-aarch64-musl.tar.gz"
    version "1.3.14"
    sha256 "21ffa64416894ccd56d777a0d18abb50a0c2f13b8f1fea01e2fb3f3b0962d64b"
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
    # Avoid `rustup` dependency by removing usage of nightly Rust features
    inreplace "scripts/build/deps/lolhtml.ts", "if (cfg.release && canBuildStdImmediateAbort)", "if (false)"

    # Use native CPU target for HarmonyOS
    inreplace "scripts/build/zig.ts", "-Dcpu=${zigCpu(cfg)}", "-Dcpu=native"

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

    # hmdfs does not support hardlink(2). bun install tries hardlinks first
    # and fails with EPERM. TODO: bun should fall back to symlink on EPERM.
    # For now the build tolerates partial install — critical packages (esbuild,
    # typescript, mitata, react, prettier) do install successfully.

    fetch_webkit

    # WebKit cmake doesn't recognize HarmonyOS; treat as Linux-like UNIX.
    inreplace "vendor/WebKit/Source/cmake/WebKitCommon.cmake",
              "if (UNIX)",
              "if (UNIX OR CMAKE_SYSTEM_NAME MATCHES \"HarmonyOS\")"
    inreplace "vendor/WebKit/Source/cmake/WebKitCommon.cmake",
              'elseif (CMAKE_SYSTEM_NAME MATCHES "Linux")',
              'elseif (CMAKE_SYSTEM_NAME MATCHES "Linux" OR CMAKE_SYSTEM_NAME MATCHES "HarmonyOS")'

    # musl does not implement qsort_r (GNU extension). Undefine _GNU_SOURCE
    # so zstd cover.c uses the C90 qsort fallback instead.
    inreplace "scripts/build/deps/zstd.ts",
              'cflags: ["-DXXH_NAMESPACE=ZSTD_"]',
              'cflags: ["-DXXH_NAMESPACE=ZSTD_", "-U_GNU_SOURCE"]'

    resource("bootstrap").stage("bootstrap")
    ENV.prepend_path "PATH", buildpath/"bootstrap"

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
