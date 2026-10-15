class Codex < Formula
  desc "OpenAI Codex CLI"
  homepage "https://github.com/openai/codex"
  url "https://github.com/openai/codex/releases/download/rust-v0.162.1/codex-package-aarch64-unknown-linux-musl.tar.gz"
  sha256 "53a9ce0b94beb27a63fdeb2f7704d95199e17b3898aa33b60461a1a93ac0d88b"
  license "Apache-2.0"
  revision 1

  bottle do
    root_url "https://github.com/nknkol/harmonybrew-cask/releases/download/bottles%2Fcodex"
    sha256 cellar: :any_skip_relocation, arm64_ohos: "3fe3db1dab4a9dfc52b50c48fe0762e94c111ee7eac944284bb1085e61f44d10"
  end

  depends_on "nknkol/cask/binary-sign-tool" => :build
  depends_on "llvm@21" => :build
  depends_on "nknkol/cask/glibc"
  depends_on "zsh"

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
    # Keep the upstream package layout so daemon startup can discover and copy
    # the complete local package, including its manifest and bundled tools.
    libexec.install "bin", "codex-package.json", "codex-path", "codex-resources"
    # These helpers in the upstream musl archive still use glibc. Invoke its
    # private loader explicitly rather than relying on a system Linux loader.
    glibc_lib = Formula["nknkol/cask/glibc"].opt_lib
    %w[codex-path/rg codex-resources/voice/bin/codex-voice-host].each do |relative|
      helper = libexec/relative
      mv helper, "#{helper}.bin"
      helper.write <<~SH
        #!/bin/sh
        helper_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
        exec "#{glibc_lib}/ld-linux-aarch64.so.1" \
          --library-path "#{glibc_lib}:$helper_dir/../lib" \
          "$helper_dir/#{helper.basename}.bin" "$@"
      SH
      chmod 0755, helper
    end

    # Use native zsh: the bundled Linux zsh also requires Linux libtinfo.
    zsh = libexec/"codex-resources/zsh/bin/zsh"
    rm zsh
    zsh.write <<~SH
      #!/bin/sh
      exec "#{Formula["zsh"].opt_bin}/zsh" "$@"
    SH
    chmod 0755, zsh

    # Codex's PID backend asks ps for stat/lstart; HarmonyOS toybox ps has no
    # lstart field. Use the kernel start tick as a stable process identity.
    # Keep this shim private to Codex's package PATH and delegate other queries.
    (libexec/"codex-path/ps").write <<~'SH'
      #!/bin/sh
      if [ "$#" -eq 6 ] && [ "$1" = -p ] && [ "$3" = -o ] &&
         [ "$4" = stat= ] && [ "$5" = -o ] && [ "$6" = lstart= ]; then
        case "$2" in ''|*[!0-9]*) exit 1 ;; esac
        IFS= read -r process_stat < "/proc/$2/stat" || exit 1
        # Strip pid and comm (which can contain spaces and parentheses).
        set -f
        set -- ${process_stat##*) }
        state="$1"
        shift 19
        printf '%s %s\n' "$state" "$1"
        exit
      fi
      if [ -x /system/bin/ps ]; then
        exec /system/bin/ps "$@"
      fi
      exec /usr/bin/ps "$@"
    SH
    chmod 0755, libexec/"codex-path/ps"

    tap_root = Pathname.new(__FILE__).dirname.parent
    system RbConfig.ruby, tap_root/"patches/codex/patch-harmonyos.rb", libexec/"bin/codex"

    libexec.find do |path|
      next unless path.file? && !path.symlink?
      next unless path.open("rb") { |file| file.read(4) } == "\x7FELF"

      sign_elf! path
    end
    bin.install_symlink libexec/"bin/codex", libexec/"bin/codex-code-mode-host"
  end

  def post_install
    Pathname.new("/data/storage/el2/base/files/.codex").mkpath
  end

  # Exercise the same non-PTY setup path that failed with SIGSYS on HarmonyOS.
  def assert_pipe_command(executable)
    require "socket"
    require "timeout"

    control, child_control = Socket.pair(:UNIX, :STREAM, 0)
    output, child_output = IO.pipe
    shell = Formula["zsh"].opt_bin/"zsh"
    parent_pid = Process.pid
    # Explicit fork/exec avoids the OHOS Ruby posix_spawn descriptor remapping.
    pid = fork do
      control.close
      output.close
      child_control.close_on_exec = false
      Process.exec({}, executable.to_s, "--codex-run-as-process-setup",
                   child_control.fileno.to_s, parent_pid.to_s, "pipe", "",
                   testpath.to_s, shell.to_s, "zsh", "-fc",
                   "printf 'stdout\\n'; printf 'stderr\\n' >&2; exit 7",
                   out: child_output, err: child_output,
                   close_others: false, unsetenv_others: true)
    end
    child_control.close
    child_output.close
    Timeout.timeout(15) do
      control.write([0].pack("V"))
      assert_equal "\x00", control.read
      assert_equal "stdout\nstderr\n", output.read
      _, status = Process.wait2(pid)
      pid = nil
      assert_equal 7, status.exitstatus
    end
  rescue Errno::EPIPE, Errno::ECONNRESET => e
    _, status = Process.wait2(pid)
    pid = nil
    raise "pipe setup failed (#{status.inspect}): #{e.message}; #{output.read}"
  ensure
    if pid
      Process.kill("KILL", pid) rescue nil
      Process.wait(pid) rescue nil
    end
    [control, child_control, output, child_output].compact.each { |io| io.close unless io.closed? }
  end

  def caveats
    <<~EOS
      Daemon sockets use /data/storage/el2/base/cache/cd-<uid> on HarmonyOS.

      Sandbox unavailable on HarmonyOS; Codex runs unconfined.
      To suppress the warning:
        export CODEX_NO_SANDBOX=1

      To persist config across sessions:
        export CODEX_HOME=/data/storage/el2/base/files/.codex
    EOS
  end

  test do
    ENV["CODEX_NO_SANDBOX"] = "1"
    (testpath/"codex-home").mkpath
    ENV["CODEX_HOME"] = (testpath/"codex-home").to_s
    assert_match "codex-cli #{version}", shell_output("#{bin}/codex --version")

    assert_match "codex-cli #{version}", shell_output("#{bin}/codex --no-daemon --version")
    assert_match "resume", shell_output("#{bin}/codex resume --help")
    assert_match "fork", shell_output("#{bin}/codex fork --help")
    assert_match "ripgrep", shell_output("#{libexec}/codex-path/rg --version")
    assert_equal "ok", shell_output("#{libexec}/codex-resources/zsh/bin/zsh -fc 'printf ok'")
    assert_pipe_command libexec/"bin/codex"

    # Exercise the package discovery and copying that --version does not cover.
    begin
      output = shell_output("#{bin}/codex app-server daemon start 2>&1")
      assert_match "started", output
      package = testpath/"codex-home/packages/app-server-daemon/current"
      assert_path_exists package/"codex-package.json"
      assert_match "codex-cli #{version}", shell_output("#{package}/bin/codex --version")
      assert_pipe_command package/"bin/codex"
    ensure
      system bin/"codex", "app-server", "daemon", "stop"
    end
  end
end
