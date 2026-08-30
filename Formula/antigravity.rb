class Antigravity < Formula
  desc "Google Antigravity CLI — AI coding agent for the terminal"
  homepage "https://github.com/google-antigravity/antigravity-cli"
  url "https://github.com/google-antigravity/antigravity-cli/releases/download/1.1.22/agy_cli_linux_arm64.tar.gz"
  sha256 "a68925bc7336eb0b90de1e1aefd44d535f5487b7cf606a76fdb982207aef9a2e"
  license "Apache-2.0"
  version "1.1.22"

  bottle do
    root_url "https://github.com/nknkol/harmonybrew-cask/releases/download/bottles%2Fantigravity"
    sha256 cellar: :any_skip_relocation, arm64_ohos: ""
  end

  # The upstream binary is linked against glibc (Go + cgo with Chromium
  # components), which cannot run on the musl-based HarmonyOS system natively.
  # We depend on the keg-only patched glibc runtime and rewrite the binary's
  # interpreter to point at it.
  depends_on "nknkol/cask/glibc"
  depends_on "nknkol/cask/binary-sign-tool" => :build
  depends_on "llvm@21" => :build
  depends_on "patchelf" => :build

  def sign_tool
    Formula["nknkol/cask/binary-sign-tool"].opt_bin/"binary-sign-tool-fix"
  end

  def llvm_objcopy
    Formula["llvm@21"].opt_bin/"llvm-objcopy"
  end

  def glibc
    Formula["nknkol/cask/glibc"]
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
    agy = buildpath/"antigravity"

    # Rewrite the ELF interpreter to the keg-only glibc loader, and set the
    # RUNPATH so the glibc shared libraries are found at runtime.
    glibc_lib = glibc.opt_lib
    system "patchelf", "--set-interpreter", "#{glibc_lib}/ld-linux-aarch64.so.1", agy.to_s
    system "patchelf", "--set-rpath", glibc_lib.to_s, agy.to_s

    sign_elf! agy

    bin.install agy => "agy"
  end

  def caveats
    <<~EOS
      Antigravity runs against the keg-only glibc runtime (#{glibc.opt_lib}).
      It has been patched to use that loader directly, so no LD_LIBRARY_PATH
      is needed.

      Sandbox unavailable on HarmonyOS; Antigravity runs unconfined.
    EOS
  end

  test do
    assert_match "1.1.22", shell_output("#{bin}/agy --version")
  end
end
