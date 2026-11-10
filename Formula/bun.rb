class Bun < Formula
  desc "Incredibly fast JavaScript runtime, bundler, test runner, and package manager"
  homepage "https://bun.com/"
  url "https://github.com/oven-sh/bun/releases/download/bun-v1.4.4/bun-linux-aarch64.zip"
  sha256 "baa6bb36f51d6e58561e02bbea825038a9df454f673d6d776e8bbf86f8c7850e"
  version "1.4.4"
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
    sha256 cellar: :any_skip_relocation, arm64_ohos: "82b638d64919d12acc8cefc545d552595929136c8ec7e7e5504e66354c146888"
  end

  depends_on "nknkol/cask/binary-sign-tool" => :build
  depends_on "nknkol/cask/glibc"

  def sign_tool
    Formula["nknkol/cask/binary-sign-tool"].opt_bin/"binary-sign-tool-fix"
  end

  def install
    tap_root = Pathname.new(__FILE__).dirname.parent
    system RbConfig.ruby, (tap_root/"patches/elf-patch-loader/install_loader.rb").to_s,
           "--binary", (buildpath/"bun").to_s,
           "--config", (tap_root/"patches/bun/bun.elfpatch").to_s,
           "--prefix", prefix.to_s,
           "--name", "bun",
           "--glibc-lib", Formula["nknkol/cask/glibc"].opt_lib.to_s,
           "--sign-tool", sign_tool.to_s
  end

  def caveats
    <<~EOS
      Bun runs via the HarmonyOS ELF in-memory patch loader against the
      keg-only glibc runtime (#{Formula["nknkol/cask/glibc"].opt_lib}) with
      close_range syscalls patched in memory before execution. The upstream ELF
      binary in #{opt_libexec}/bun remains unmodified on disk.
    EOS
  end

  test do
    assert_match "verification passed", shell_output("ELFPATCH_VERIFY=1 #{bin}/bun 2>&1")
    assert_match version.to_s, shell_output("#{bin}/bun --version")
    assert_equal "bun-js-ok\n", shell_output("#{bin}/bun -e 'console.log(\"bun-js-ok\")'")
    assert_equal "bun-spawn-ok\n", shell_output(<<~EOS)
      #{bin}/bun -e 'const p = Bun.spawn(["/bin/sh", "-c", "printf bun-spawn-ok"], { stdout: "pipe" }); console.log(await new Response(p.stdout).text()); process.exit(await p.exited)'
    EOS
  end
end
