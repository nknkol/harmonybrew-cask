class ClaudeCode < Formula
  desc "Anthropic's agentic coding tool"
  homepage "https://www.anthropic.com/claude-code"
  url "https://downloads.claude.ai/claude-code-releases/2.1.292/linux-arm64-musl/claude"
  sha256 "a17c919b13df206371a55de716ab81e3dcd7c039f66b79003ed87b7665fdc15f"
  version "2.1.292"

  bottle do
    root_url "https://github.com/nknkol/harmonybrew-cask/releases/download/bottles%2Fclaude-code"
    sha256 cellar: :any_skip_relocation, arm64_ohos: "fd3248e8db7d692cfca2784ef3d0f88c318f3589a6a21a88c0ce28b8d88a9e50"
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
    claude = buildpath/"claude"
    tap_root = Pathname.new(__FILE__).dirname.parent
    patcher = tap_root/"patches/claude-code/patch-bun-runtime.rb"

    chmod 0755, claude
    system RbConfig.ruby, patcher, claude
    sign_elf! claude
    bin.install claude
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/claude --version")
    assert_match "Usage:", shell_output("#{bin}/claude --help")
  end
end