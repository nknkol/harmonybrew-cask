class Sheldon < Formula
  desc "Fast, configurable, shell plugin manager"
  homepage "https://github.com/rossmacarthur/sheldon"
  url "https://github.com/rossmacarthur/sheldon/releases/download/0.8.5/sheldon-0.8.5-aarch64-unknown-linux-musl.tar.gz"
  sha256 "1f6b792e49e259f7c313e9921c8d4ad638d827abc2c023efe0588a55678f9a3e"
  license any_of: ["MIT", "Apache-2.0"]
  version "0.8.5"

  bottle do
    root_url "https://github.com/nknkol/harmonybrew-cask/releases/download/bottles%2Fsheldon"
    sha256 cellar: :any_skip_relocation, arm64_ohos: "d86bd4d10560d53e8dc0769534f643bb188b797ae8b072d592f3ddb4bccd6370"
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
    sheldon = buildpath/"sheldon"
    sign_elf! sheldon
    bin.install sheldon

    bash_completion.install "completions/sheldon.bash" => "sheldon"
    zsh_completion.install "completions/sheldon.zsh" => "_sheldon"
  end

  test do
    assert_match "sheldon #{version}", shell_output("#{bin}/sheldon --version")
  end
end
