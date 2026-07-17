class Reasonix < Formula
  desc "DeepSeek-native AI coding agent for your terminal"
  homepage "https://github.com/esengine/DeepSeek-Reasonix"
  version "1.17.14"
  url "https://github.com/esengine/DeepSeek-Reasonix/releases/download/v1.17.14/reasonix-linux-arm64.tar.gz"
  sha256 "971b08ec51b9d1e61187fdaca4dc3cab1b5cd343972d7283a9bfee14e78c95d8"
  license "MIT"

  bottle do
    root_url "https://github.com/nknkol/harmonybrew-cask/releases/download/bottles%2Freasonix"
  end

  depends_on "nknkol/cask/binary-sign-tool" => :build
  depends_on "llvm@21" => :build

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
    reasonix = buildpath/"reasonix"
    sign_elf! reasonix

    bin.install reasonix
    pkgshare.install "README.md", "README.zh-CN.md", "CHANGELOG.md"
  end

  def post_install
    (Pathname.new(Dir.home)/".reasonix").mkpath
  end

  def caveats
    <<~EOS
      Sandbox unavailable on HarmonyOS; Reasonix runs unconfined.
    EOS
  end

  test do
    assert_match "reasonix v#{version}", shell_output("#{bin}/reasonix --version")
  end
end
