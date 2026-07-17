class Adbcli < Formula
  desc "Rust ADB client CLI without USB backend"
  homepage "https://github.com/cocool97/adb_client"
  url "https://github.com/cocool97/adb_client/archive/refs/tags/v3.2.2.zip"
  sha256 "134983e228acef7ee03737fa1a2e01dbe53ddf801842d3eb5ab01f649d3e3c17"
  license "MIT"

  bottle do
    root_url "https://github.com/nknkol/harmonybrew-cask/releases/download/bottles%2Fadbcli"
  end

  depends_on "rust" => :build

  patch do
    file "patches/adbcli/0001-disable-usb-feature.patch"
  end

  def install
    ENV["CARGO_HOME"] = buildpath/".cargo"

    system "cargo", "build", "--release", "--package", "adb_cli"

    bin.install "target/release/adb_cli" => "adbcli"
    ln_s "adbcli", bin/"adb_cli"

    pkgshare.install "README.md", "adb_cli/README.md"
  end

  test do
    assert_match "adb_cli #{version}", shell_output("#{bin}/adbcli --version")
    assert_match "TCP device related commands", shell_output("#{bin}/adbcli --help")
    refute_match "USB device related commands", shell_output("#{bin}/adbcli --help")
  end
end
