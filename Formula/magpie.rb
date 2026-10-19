class Magpie < Formula
  desc "Every agent's model in one place"
  homepage "https://usemagpie.ai"
  url "https://github.com/yetone/magpie/releases/download/v0.1.1285/magpie-cli-linux-arm64"
  sha256 "1b57aa40ed2ed9484978ee14531de6d553644dc60ae581076a7f4de336f1c90b"
  version "0.1.1285"
  license "MIT"

  bottle do
    root_url "https://github.com/nknkol/harmonybrew-cask/releases/download/bottles%2Fmagpie"
    sha256 cellar: :any_skip_relocation, arm64_ohos: "71dab64d556dca3efd1daf6381cf70bcc920a71e164eb01f96014321b3b5b0c9"
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
    magpie = buildpath/"magpie-cli-linux-arm64"

    # Upstream ships a static Go binary with no shared libraries; only the
    # HarmonyOS code signature is missing.
    chmod 0755, magpie
    sign_elf! magpie

    bin.install magpie => "magpie"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/magpie --version")
    assert_match "one place", shell_output("#{bin}/magpie --help")
  end
end