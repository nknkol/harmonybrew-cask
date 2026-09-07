class CodexAT01531 < Formula
  desc "OpenAI Codex CLI"
  homepage "https://github.com/openai/codex"
  url "https://github.com/openai/codex/releases/download/rust-v0.153.1/codex-aarch64-unknown-linux-musl.tar.gz"
  sha256 "7c26e9f6e424bf618c33ae8263f3b3a1c1cc32c82bfbfd5f27b6c81402618664"
  license "Apache-2.0"
  keg_only :versioned_formula

  resource "code-mode-host" do
    url "https://github.com/openai/codex/releases/download/rust-v0.153.1/codex-code-mode-host-aarch64-unknown-linux-musl.tar.gz"
    sha256 "25e2160818706e48c5115501d5986fb8c3e85ac72267f619c4944b5e1465cc40"
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
    codex = buildpath/"codex-aarch64-unknown-linux-musl"
    sign_elf! codex
    bin.install codex => "codex"

    resource("code-mode-host").stage do
      cmh = Pathname.pwd/"codex-code-mode-host-aarch64-unknown-linux-musl"
      sign_elf! cmh
      bin.install cmh => "codex-code-mode-host"
    end
  end

  def post_install
    Pathname.new("/data/storage/el2/base/files/.codex").mkpath
  end

  def caveats
    <<~EOS
      Sandbox unavailable on HarmonyOS; Codex runs unconfined.
      To suppress the warning:
        export CODEX_NO_SANDBOX=1

      To persist config across sessions:
        export CODEX_HOME=/data/storage/el2/base/files/.codex
    EOS
  end

  test do
    assert_match "codex-cli #{version}", shell_output("CODEX_NO_SANDBOX=1 #{bin}/codex --version")
  end
end
