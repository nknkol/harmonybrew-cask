class Adbcli < Formula
  desc "Rust ADB client CLI without USB backend"
  homepage "https://github.com/cocool97/adb_client"
  url "https://github.com/cocool97/adb_client/archive/refs/tags/v3.2.2.zip"
  sha256 "134983e228acef7ee03737fa1a2e01dbe53ddf801842d3eb5ab01f649d3e3c17"
  license "MIT"

  bottle do
    root_url "https://github.com/nknkol/harmonybrew-cask/releases/download/bottles%2Fadbcli"
    sha256 cellar: :any_skip_relocation, arm64_ohos: "61ca811957c776b2ff6582f50014253a3d8b4d67cd86591fd67e18433283decf"
  end

  skip_clean "bin/adbcli"

  depends_on "nknkol/cask/binary-sign-tool" => :build
  depends_on "llvm@21" => :build
  depends_on "rust" => :build

  patch do
    file "patches/adbcli/0001-disable-usb-feature.patch"
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
    ENV["CARGO_HOME"] = buildpath/".cargo"

    system "cargo", "build", "--release", "--package", "adb_cli"

    bin.install "target/release/adb_cli" => "adbcli"
    sign_elf! bin/"adbcli"

    ln_s "adbcli", bin/"adb_cli"

    pkgshare.install "README.md", "adb_cli/README.md"
  end

  test do
    assert_match "adb_cli #{version}", shell_output("#{bin}/adbcli --version")
    assert_match "TCP device related commands", shell_output("#{bin}/adbcli --help")
    refute_match "USB device related commands", shell_output("#{bin}/adbcli --help")
  end
end
