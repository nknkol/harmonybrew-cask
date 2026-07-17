class Codex < Formula
  desc "OpenAI Codex CLI"
  homepage "https://github.com/openai/codex"
  url "https://github.com/openai/codex/releases/download/rust-v0.144.5/codex-aarch64-unknown-linux-musl.tar.gz"
  sha256 "5433789cd66e0db3b78cccd218d894471ed9e92fe93465120d1356508952084d"
  license "Apache-2.0"

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
