class ClaudeCode < Formula
  desc "Anthropic's agentic coding tool"
  homepage "https://www.anthropic.com/claude-code"
  url "https://downloads.claude.ai/claude-code-releases/2.1.322/linux-arm64-musl/claude"
  sha256 "b8a07ebb71cd612bd1ed80eabd2084ded98cadbae298d068a4a1307f0448c40c"
  version "2.1.322"

  bottle do
    root_url "https://github.com/nknkol/harmonybrew-cask/releases/download/bottles%2Fclaude-code"
    sha256 cellar: :any_skip_relocation, arm64_ohos: "30b6085243378d0c5d3a465db2af2c4ee32206dba950f2b978d777bf5b4cf615"
  end

  depends_on "nknkol/cask/binary-sign-tool" => :build

  def sign_tool
    Formula["nknkol/cask/binary-sign-tool"].opt_bin/"binary-sign-tool-fix"
  end

  def install
    tap_root = Pathname.new(__FILE__).dirname.parent
    system RbConfig.ruby, (tap_root/"patches/elf-patch-loader/install_loader.rb").to_s,
           "--binary", (buildpath/"claude").to_s,
           "--config", (tap_root/"patches/claude-code/claude.elfpatch").to_s,
           "--prefix", prefix.to_s,
           "--name", "claude",
           "--sign-tool", sign_tool.to_s
  end

  def caveats
    <<~EOS
      Claude Code runs via the HarmonyOS ELF in-memory patch loader with Bun
      musl/seccomp startup syscalls patched in memory before execution. The
      upstream ELF binary in #{opt_libexec}/claude remains unmodified on disk.
    EOS
  end

  test do
    assert_match "verification passed", shell_output("ELFPATCH_VERIFY=1 #{bin}/claude 2>&1")
    assert_match version.to_s, shell_output("#{bin}/claude --version")
    assert_match "Usage:", shell_output("#{bin}/claude --help")
  end
end
