class Glibc < Formula
  desc "GNU glibc and GCC runtime libraries for running Linux binaries on HarmonyOS"
  homepage "https://www.gnu.org/software/libc/"
  url "https://raw.githubusercontent.com/nknkol/harmonybrew-cask/main/bootstrap/glibc-2.38-gcc-12.3.1-harmonyos-arm64.tar.gz"
  sha256 "35d328c8c2698488ec02d144267e59e497de2181532e6fb8b60c94d466e5e79b"
  license all_of: ["LGPL-2.1-or-later", "GPL-3.0-or-later" => { with: "GCC-exception-3.1" }]
  version "2.38"
  revision 1

  # keg_only: this is a glibc runtime used to run glibc-linked binaries
  # (e.g. Google Antigravity CLI) on the musl-based HarmonyOS system.  It must
  # not be linked into the system, which would conflict with the native musl.
  keg_only "glibc runtime for glibc-linked binaries; not meant to replace musl"

  bottle do
    root_url "https://github.com/nknkol/harmonybrew-cask/releases/download/bottles%2Fglibc"
    rebuild 1
    sha256 cellar: :any_skip_relocation, arm64_ohos: "90dd90fd4f7fe6324e785d43a113087af9e21e621c7d41cae765f68156814137"
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
    # The tarball contains the stripped, patched glibc 2.38 runtime libraries:
    #   ld-linux-aarch64.so.1  libc.so.6  libm.so.6  libpthread.so.0
    #   libdl.so.2             libresolv.so.2  librt.so.1
    # and the openEuler GCC 12.3.1 glibc runtime libraries:
    #   libgcc_s.so.1          libstdc++.so.6    libatomic.so.1
    #
    # Keep the canonical SONAME files as regular files. HarmonyOS validates
    # the file opened by the loader, and materialized files avoid hmdfs symlink
    # and signature inconsistencies.
    # All must be signed before they can be executed on HarmonyOS.
    lib.mkpath
    Dir[buildpath/"*.so*"].each do |so|
      next if File.symlink?(so)
      sign_elf! Pathname.new(so)
      lib.install so
    end
  end

  test do
    %w[
      ld-linux-aarch64.so.1
      libc.so.6
      libgcc_s.so.1
      libstdc++.so.6
      libatomic.so.1
    ].each do |runtime|
      assert_predicate lib/runtime, :exist?
    end

    assert_match(/GNU (?:C Library|libc)/, shell_output("#{lib}/ld-linux-aarch64.so.1 --version"))
  end
end
