class Rust < Formula
  desc "Safe, concurrent, practical language"
  homepage "https://www.rust-lang.org/"
  url "https://static.rust-lang.org/dist/rustc-1.96.0-src.tar.gz"
  sha256 "e90a9eb153b2948afac840dbe9d77b64e376706f2864387ee7717f7450043b44"
  license any_of: ["Apache-2.0", "MIT"]

  bottle do
    root_url "https://github.com/nknkol/harmonybrew-cask/releases/download/bottles%2Frust"
  end

  depends_on "llvm@21"
  depends_on "gpatch" => :build
  depends_on "llvm-gcc-compat" => :build
  depends_on "nknkol/cask/binary-sign-tool" => :build
  depends_on "pkgconf" => :build
  depends_on "python" => :build

  depends_on "curl"
  depends_on "libgit2"
  depends_on "libssh2"
  depends_on "libxml2"
  depends_on "ohos-sdk"
  depends_on "openssl@3"
  depends_on "sqlite"
  depends_on "xz"
  depends_on "zlib-ng-compat"
  depends_on "zstd"

  conflicts_with "rust", because: "both install cargo, rustc, rustfmt and the Rust toolchain"

  preserve_rpath

  link_overwrite "etc/bash_completion.d/cargo"
  link_overwrite "bin/cargo-fmt", "bin/git-rustfmt", "bin/rustfmt", "bin/rustfmt-*"

  patch do
    file "patches/rust/0001-enable-native-elf-tls.patch"
  end
  patch do
    file "patches/rust/0002-llvm-cmake-ohos-host.patch"
  end
  patch do
    file "patches/rust/0003-llvm-dist-no-linker-script.patch"
  end
  patch do
    file "patches/rust/0004-bootstrap-fork-on-ohos.patch"
  end
  patch do
    file "patches/rust/0005-fix-configure-rustflags-array.patch"
  end

  resource "rustc-bootstrap" do
    url "https://static.rust-lang.org/dist/2026-04-16/rustc-1.95.0-aarch64-unknown-linux-ohos.tar.xz", using: :nounzip
    sha256 "832d7e0ac5baaacfd3ff1b1f056cc05ec13f0665372eeb42a65efd8f868e9855"
  end

  resource "cargo-bootstrap" do
    url "https://static.rust-lang.org/dist/2026-04-16/cargo-1.95.0-aarch64-unknown-linux-ohos.tar.xz", using: :nounzip
    sha256 "2912b30e2d4fc3f51b4dec22de063f892d9418cb52c202e8aa9254ca68e48d4c"
  end

  resource "rust-std-bootstrap" do
    url "https://static.rust-lang.org/dist/2026-04-16/rust-std-1.95.0-aarch64-unknown-linux-ohos.tar.xz", using: :nounzip
    sha256 "b0db83f71e055acd6b54376262ed13e2dd50d4862b9364a5469885800ee1076a"
  end

  def llvm_root
    Formula["llvm@21"].opt_prefix
  end

  def ohos_llvm
    Formula["ohos-sdk"].opt_prefix/"native/llvm"
  end

  def sign_tool
    Formula["nknkol/cask/binary-sign-tool"].opt_bin/"binary-sign-tool-fix"
  end

  def objcopy
    llvm_root/"bin/llvm-objcopy"
  end

  def elf_file?(path)
    return false unless path.file?

    path.open("rb") { |f| f.read(4) } == "\x7fELF".b
  rescue
    false
  end

  def sign_elf!(path)
    return unless elf_file?(path)

    unsigned = path.sub_ext("#{path.extname}.unsigned")
    signed   = path.sub_ext("#{path.extname}.signed")

    rm_f unsigned
    rm_f signed
    chmod 0755, path

    if quiet_system objcopy, "--remove-section=.codesign", path, unsigned
      chmod 0755, unsigned
    else
      cp path, unsigned
    end

    system sign_tool, "sign",
           "-inFile", unsigned,
           "-outFile", signed,
           "-selfSign", "1"
    chmod 0755, signed
    mv signed, path, force: true
  ensure
    rm_f unsigned if defined?(unsigned) && unsigned
    rm_f signed   if defined?(signed)   && signed
  end

  def sign_tree!(root)
    return unless root.exist?

    root.find do |path|
      next if path.directory?

      sign_elf!(path)
    end
  end

  def install
    # Ensure that the `openssl` crate picks up the intended library.
    ENV["OPENSSL_DIR"] = Formula["openssl@3"].opt_prefix
    ENV["LIBGIT2_NO_VENDOR"] = "1"
    ENV["LIBSQLITE3_SYS_USE_PKG_CONFIG"] = "1"
    ENV["LIBSSH2_SYS_USE_PKG_CONFIG"] = "1"
    ENV["ZLIB_SYSTEM"] = "1"

    # Bootstrap binaries must find their shared libraries at runtime.
    bootstrap_lib_path = [
      Formula["openssl@3"].opt_lib,
      Formula["zlib-ng-compat"].opt_lib,
      Formula["libssh2"].opt_lib,
      Formula["libgit2"].opt_lib,
      Formula["curl"].opt_lib,
      Formula["sqlite"].opt_lib,
      Formula["xz"].opt_lib,
      Formula["zstd"].opt_lib,
      Formula["libxml2"].opt_lib,
    ].join(":")
    ENV["LD_LIBRARY_PATH"] = bootstrap_lib_path

    ca_file = HOMEBREW_PREFIX/"etc/ca-certificates/cert.pem"
    ENV["SSL_CERT_FILE"] = ca_file if ca_file.exist?

    ENV.delete("RUSTC_WRAPPER")
    ENV.delete("HOMEBREW_RUSTFLAGS")
    ENV.delete("RUSTFLAGS")

    ENV.prepend_path "PATH", Formula["nknkol/cask/binary-sign-tool"].opt_bin
    ENV.prepend_path "PATH", Formula["llvm-gcc-compat"].opt_bin

    # RUSTFLAGS: inject code-sign and runtime library search paths.
    runtime_rpaths = [
      "$ORIGIN/../lib",
      Formula["openssl@3"].opt_lib,
      Formula["zlib-ng-compat"].opt_lib,
      Formula["libssh2"].opt_lib,
      Formula["libgit2"].opt_lib,
      Formula["curl"].opt_lib,
      Formula["sqlite"].opt_lib,
      Formula["xz"].opt_lib,
      Formula["zstd"].opt_lib,
      Formula["libxml2"].opt_lib,
    ]
    zstd_lib = Formula["zstd"].opt_lib.to_s
    libxml2_lib = Formula["libxml2"].opt_lib.to_s
    rustflags = (["-Clink-arg=-Wl,--code-sign",
                  "-Clink-arg=-L", "-Clink-arg=#{zstd_lib}",
                  "-Clink-arg=-L", "-Clink-arg=#{libxml2_lib}"] +
                 runtime_rpaths.map { |p| "-Clink-arg=-Wl,-rpath,#{p}" }).join(" ")

    # Stage bootstrap resources
    cache_date = File.basename(File.dirname(resource("rustc-bootstrap").url))
    build_cache_directory = buildpath/"build/cache"/cache_date

    resource("rustc-bootstrap").stage build_cache_directory
    resource("cargo-bootstrap").stage build_cache_directory
    resource("rust-std-bootstrap").stage build_cache_directory

    # bootstrap.py patches sign bootstrap ELFs after extraction;
    # expose tool paths via environment variables.
    ENV["RUST_OHOS_OBJCOPY"] = objcopy.to_s
    ENV["RUST_OHOS_SIGN_TOOL"] = sign_tool.to_s

    # llvm@21's lib directory is in the linker search path, but zstd and
    # libxml2 (LLVM's transitive dependencies) are not.  Add them to
    # LIBRARY_PATH so clang/lld can find them.
    ENV["LIBRARY_PATH"] = [
      Formula["zstd"].opt_lib.to_s,
      Formula["libxml2"].opt_lib.to_s,
      ENV["LIBRARY_PATH"],
    ].compact.join(":")

    # Linker wrapper: llvm@21 clang with --code-sign for lld signing.
    llvm_bin = llvm_root/"bin"
    ohos_bin = ohos_llvm/"bin"
    target_triple = "aarch64-unknown-linux-ohos"

    linker_wrapper = buildpath/"ohos-linker-wrapper"
    linker_wrapper.atomic_write <<~SH
      #!/bin/sh
      "#{llvm_bin}/clang" -Wl,--code-sign "$@"
      rc=$?
      if [ "$rc" -eq 0 ]; then
        sleep "${RUST_LINK_SETTLE_SECONDS:-0.1}"
      fi
      exit "$rc"
    SH
    chmod 0755, linker_wrapper

    # Build tools (rust-analyzer and rust-demangler available in own formulae).
    tools = %w[
      analysis
      cargo
      clippy
      rustdoc
      rustfmt
      rust-analyzer-proc-macro-srv
      src
    ]

    args = %W[
      --prefix=#{prefix}
      --sysconfdir=#{etc}
      --build=#{target_triple}
      --host=#{target_triple}
      --target=#{target_triple}
      --tools=#{tools.join(",")}
      --llvm-root=#{llvm_root}
      --enable-profiler
      --enable-vendor
      --disable-cargo-native-static
      --disable-docs
      --disable-lld
      --enable-rpath
      --release-channel=stable
      --release-description=#{tap.user}
      --set=rust.jemalloc=false
      --set=rust.codegen-tests=false
      --set=target.#{target_triple}.cc=#{ohos_bin}/clang
      --set=target.#{target_triple}.cxx=#{ohos_bin}/clang++
      --set=target.#{target_triple}.ar=#{ohos_bin}/llvm-ar
      --set=target.#{target_triple}.ranlib=#{ohos_bin}/llvm-ranlib
      --set=target.#{target_triple}.linker=#{linker_wrapper}
      --set=rust.rustflags=#{rustflags}
    ]

    system "./configure", *args

    # Prepend llvm@21's bin to PATH so that any direct linker invocation
    # finds the code-sign-capable lld first.
    ENV.prepend_path "PATH", llvm_bin

    system "make"
    system "make", "install"

    # Post-install cleanup: install shell completions and source code.
    bash_completion.install etc/"bash_completion.d/cargo"
    (lib/"rustlib/src/rust").install "library"
    rm([
      bin.glob("*.old"),
      lib/"rustlib/install.log",
      lib/"rustlib/uninstall.sh",
      (lib/"rustlib").glob("manifest-*"),
    ])

    # Replace renamed llvm-objcopy with a symlink for libLLVM discovery.
    rust_objcopy = lib/"rustlib/#{target_triple}/bin/rust-objcopy"
    llvm_objcopy = llvm_root/"bin/llvm-objcopy"
    rm(rust_objcopy) if rust_objcopy.exist?
    ln_sf llvm_objcopy.relative_path_from(rust_objcopy.dirname), rust_objcopy
  end

  def post_install
    sign_tree!(prefix)
  end

  def caveats
    <<~EOS
      This formula builds Rust with native ELF TLS enabled for HarmonyOS.

      Link this toolchain with `rustup` under the name `native-tls` with:
        rustup toolchain link native-tls "#{opt_prefix}"
    EOS
  end

  test do
    require "utils/linkage"

    system bin/"rustdoc", "-h"
    system bin/"cargo", "-V"

    (testpath/"hello.rs").write <<~RUST
      fn main() {
        println!("Hello World!");
      }
    RUST
    system bin/"rustc", "hello.rs"
    assert_equal "Hello World!\n", shell_output("./hello")

    system bin/"cargo", "new", "hello_world", "--bin"
    assert_equal "Hello, world!",
                 cd("hello_world") { shell_output("#{bin}/cargo run").split("\n").last }

    # Verify native ELF TLS is used (not emulated).
    (testpath/"tls.rs").write <<~RUST
      thread_local! {
          static VALUE: std::cell::Cell<u32> = const { std::cell::Cell::new(7) };
      }

      fn main() {
          VALUE.with(|value| {
              assert_eq!(value.get(), 7);
              value.set(42);
              assert_eq!(value.get(), 42);
          });
      }
    RUST
    system bin/"rustc", "tls.rs"
    shell_output("./tls")
    assert_match(/TLS/, shell_output("#{llvm_root}/bin/llvm-readelf -l ./tls"))
    refute_match(/__emutls_(get_address|v\.)/,
                 shell_output("#{llvm_root}/bin/llvm-nm ./tls"))

    # Verify linkage against system libraries.
    expected_linkage = {
      bin/"cargo" => [
        Formula["libgit2"].opt_lib/shared_library("libgit2"),
        Formula["libssh2"].opt_lib/shared_library("libssh2"),
        Formula["curl"].opt_lib/shared_library("libcurl"),
        Formula["sqlite"].opt_lib/shared_library("libsqlite3"),
      ],
    }

    missing_linkage = []
    expected_linkage.each do |binary, dylibs|
      dylibs.each do |dylib|
        next if Utils.binary_linked_to_library?(binary, dylib)

        missing_linkage << "#{binary} => #{dylib}"
      end
    end

    assert missing_linkage.empty?, "Missing linkage: #{missing_linkage.join(", ")}"
  end
end
