class Bun < Formula
  desc "Incredibly fast JavaScript runtime, bundler, test runner, and package manager"
  homepage "https://bun.com/"
  url "https://github.com/oven-sh/bun/releases/download/bun-v1.4.2/bun-linux-aarch64.zip"
  sha256 "54328bbc2d9c8e0c9f892c544d66c57a83b84139e34909e5ee81758f1ac8fda7"
  version "1.4.2"
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
    sha256 cellar: :any_skip_relocation, arm64_ohos: "05d483ed2e23c0a7a502d5573bf2d5a443a8a1585ad06fc332d6db957909e53d"
  end

  depends_on "nknkol/cask/glibc"
  depends_on "nknkol/cask/binary-sign-tool" => :build
  depends_on "llvm@21" => :build

  def glibc
    Formula["nknkol/cask/glibc"]
  end

  def sign_tool
    Formula["nknkol/cask/binary-sign-tool"].opt_bin/"binary-sign-tool-fix"
  end

  def llvm_objcopy
    Formula["llvm@21"].opt_bin/"llvm-objcopy"
  end

  def sign_elf!(path)
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

    system sign_tool, "sign", "-selfSign", "1", "-inFile", unsigned, "-outFile", signed
    chmod 0755, signed
    mv signed, path, force: true
  ensure
    rm_f unsigned if defined?(unsigned) && unsigned
    rm_f signed if defined?(signed) && signed
  end

  def install
    bun = buildpath/"bun"
    tap_root = Pathname.new(__FILE__).dirname.parent
    patcher = tap_root/"patches/bun/patch-binary-runtime.rb"

    system RbConfig.ruby, patcher, bun
    sign_elf! bun
    libexec.install bun
    (bin/"bun").write_env_script libexec/"bun", LD_LIBRARY_PATH: glibc.opt_lib
  end

  def post_install
    loader = Pathname.new("/data/storage/el2/base/ld")
    loader.dirname.mkpath
    ln_sf glibc.opt_lib/"ld-linux-aarch64.so.1", loader
  end

  def caveats
    <<~EOS
      Bun uses the HarmonyOS shell application's short loader link:
        /data/storage/el2/base/ld
      Homebrew recreates this link during post-install.
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/bun --version")
    assert_equal "bun-js-ok\n", shell_output("#{bin}/bun -e 'console.log(\"bun-js-ok\")'")
    assert_equal "bun-spawn-ok\n", shell_output(<<~EOS)
      #{bin}/bun -e 'const p = Bun.spawn(["/bin/sh", "-c", "printf bun-spawn-ok"], { stdout: "pipe" }); console.log(await new Response(p.stdout).text()); process.exit(await p.exited)'
    EOS
  end
end
