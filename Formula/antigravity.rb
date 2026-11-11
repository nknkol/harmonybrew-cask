class Antigravity < Formula
  desc "Google Antigravity agentic coding CLI"
  homepage "https://antigravity.google/docs/cli"
  url "https://github.com/google-antigravity/antigravity-cli/releases/download/1.5.4/agy_cli_linux_arm64.tar.gz"
  sha256 "aa8870d1b93b646ed52fd0862752b3ec8c5e91afd22d943eb2a9a0b0671fd939"
  version "1.5.4"
  revision 1

  bottle do
    root_url "https://github.com/nknkol/harmonybrew-cask/releases/download/bottles%2Fantigravity"
    sha256 cellar: :any_skip_relocation, arm64_ohos: "7debe3e202e074ca0038706040f5cad7278ad98dc183f180b1dbbe1df8031a9c"
  end

  depends_on "nknkol/cask/binary-sign-tool" => :build
  depends_on "nknkol/cask/glibc"

  def sign_tool
    Formula["nknkol/cask/binary-sign-tool"].opt_bin/"binary-sign-tool-fix"
  end

  def install
    tap_root = Pathname.new(__FILE__).dirname.parent
    system RbConfig.ruby, (tap_root/"patches/elf-patch-loader/install_loader.rb").to_s,
           "--binary", (buildpath/"antigravity").to_s,
           "--config", (tap_root/"patches/antigravity/agy.elfpatch").to_s,
           "--prefix", prefix.to_s,
           "--name", "agy",
           "--glibc-lib", Formula["nknkol/cask/glibc"].opt_lib.to_s,
           "--sign-tool", sign_tool.to_s
  end

  def caveats
    <<~EOS
      Antigravity runs via the HarmonyOS ELF in-memory patch loader against the
      keg-only glibc runtime (#{Formula["nknkol/cask/glibc"].opt_lib}) with
      auto-update disabled and a resident SIGSYS -> -ENOSYS trap guard active
      in memory before execution. The upstream ELF binary in
      #{opt_libexec}/antigravity remains unmodified on disk.

      Sandbox unavailable on HarmonyOS; Antigravity runs unconfined.
    EOS
  end

  test do
    verify_out = shell_output("ELFPATCH_VERIFY=1 #{bin}/agy 2>&1")
    assert_match "verification passed", verify_out
    assert_match "sigsys-guard hooked", verify_out
    assert_match version.to_s, shell_output("#{bin}/agy --version")
    assert_match "Usage of agy:", shell_output("#{bin}/agy --help 2>&1")
  end
end
