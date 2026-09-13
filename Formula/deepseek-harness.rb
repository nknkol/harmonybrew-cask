class DeepseekHarness < Formula
  desc "Open-source agent harness developed by DeepSeek AI"
  homepage "https://github.com/deepseek-ai/deepseek-harness"
  url "https://registry.npmjs.org/@deepseek-ai/dsh/-/dsh-0.1.5-rc.2.tgz"
  sha256 "f4c54839d69e82bf1c3a5a41a910c3ce1405cd9e9d97d753c0c04f406c7d7480"
  license "MIT"
  revision 2

  bottle do
    root_url "https://github.com/nknkol/harmonybrew-cask/releases/download/bottles%2Fdeepseek-harness"
    sha256 cellar: :any_skip_relocation, arm64_ohos: "36a5ed593216846218148e51ba3c7a76e0e73b7c68d29b9f999169cbc8d3242e"
  end

  # The npm `next` dist-tag carries the rc line while `latest` lags behind it.
  # Track published rc releases while filtering out earlier prerelease stages.
  livecheck do
    url "https://registry.npmjs.org/@deepseek-ai/dsh"
    strategy :json do |json|
      json["versions"].keys.grep_v(/-(?:alpha|beta|dev)\./i)
    end
  end

  depends_on "cmake" => :build
  depends_on "nknkol/cask/binary-sign-tool" => :build
  depends_on "ohos-sdk" => :build
  depends_on "bash"
  depends_on "node"
  depends_on "ripgrep"

  def sign_tool
    Formula["nknkol/cask/binary-sign-tool"].opt_bin/"binary-sign-tool-fix"
  end

  def llvm_objcopy
    Formula["ohos-sdk"].opt_prefix/"native/llvm/bin/llvm-objcopy"
  end

  def elf_file?(path)
    return false unless path.file?

    path.open("rb") { |file| file.read(4) } == "\x7fELF".b
  rescue
    false
  end

  def sign_elf!(path)
    return unless elf_file?(path)

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
    require "json"

    # Homebrew's npm helper normally rejects packages published less than one
    # day ago. dsh releases its scoped packages together, so allow fresh ones.
    system "npm", "install", *std_npm_args(ignore_scripts: true), "--min-release-age=0", "@img/sharp-wasm32"

    Dir.chdir(libexec/"lib/node_modules/@deepseek-ai/dsh") do
      # The installed CLI does not need unpublished workspace devDependencies.
      manifest = JSON.parse(File.read("package.json"))
      manifest.delete("devDependencies")
      File.write("package.json", JSON.pretty_generate(manifest) + "\n")
      system "npm", "install", "--ignore-scripts"

      # OpenHarmony CMake does not identify clang and therefore misses the
      # requested C++20 mode while building koffi.
      koffi_cmake = "node_modules/koffi/src/koffi/CMakeLists.txt"
      inreplace koffi_cmake, "set(CMAKE_CXX_STANDARD 20)",
                "set(CMAKE_CXX_STANDARD 20)\nset(CMAKE_CXX_FLAGS \"${CMAKE_CXX_FLAGS} -std=c++20\")"
      system "npm", "rebuild", "koffi", "node-pty"
    end

    # Future local fixes can be kept as patches against the scoped packages
    # materialised by npm install. Formula lives directly under Formula/.
    patch_dir = File.expand_path("../patches/deepseek-harness", __dir__)
    dsh_modules = libexec/"lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai"
    Dir[File.join(patch_dir, "*.patch")].sort.each do |patch_file|
      system "patch", "-p1", "-d", dsh_modules, "-i", patch_file
    end

    # Native Node add-ons are ELF shared objects and must carry an OpenHarmony
    # code signature before the bottle is packed.
    libexec.find do |path|
      sign_elf!(path) if elf_file?(path)
    end

    (bin/"dsh").write <<~EOS
      #!/bin/sh
      export OPENSSL_armcap=0
      exec "#{formula_opt_bin("node")/"node"}" \\
        --expose-internals \\
        "#{libexec/"lib/node_modules/@deepseek-ai/dsh/lib/bin.js"}" \\
        "$@"
    EOS
    (bin/"dsh").chmod 0755
  end

  def caveats
    <<~EOS
      Run `dsh` command to use deepseek-harness:

        Web UI:   dsh web
        One-shot: dsh --profile headless "..."
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/dsh --version")

    log = testpath/"dsh-web.log"
    pid = spawn({}, "#{bin}/dsh", "web", "--no-open", "--port", "0", out: log.to_s, err: log.to_s)
    alive = lambda do
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end
    begin
      url = nil
      60.times do
        url = log.exist? ? log.read[/dsh web: (\S+)/, 1] : nil
        break if url
        raise "dsh web exited before serving" unless alive.call

        sleep 0.5
      end
      assert url, "dsh web did not print its URL within 30s"

      jar = testpath/"cookies.txt"
      html = testpath/"index.html"
      code = shell_output("curl -sL -c #{jar} -b #{jar} -o #{html} -w %{http_code} '#{url}'").strip
      assert_equal "200", code
      assert_match(/<!doctype html/i, html.read)
    ensure
      begin
        Process.kill("TERM", pid) if pid
      rescue Errno::ESRCH, Errno::EPERM
        # Server already exited.
      end
    end
  end
end
