class Starship < Formula
  desc "Cross-shell prompt for astronauts"
  homepage "https://starship.rs"
  url "https://github.com/starship/starship/releases/download/v1.26.0/starship-aarch64-unknown-linux-musl.tar.gz"
  sha256 "dc30189378d2f2e287384e8a692d3f95ad1df64cf0e8c36aa9201516028aed6b"
  license "ISC"

  bottle do
    root_url "https://github.com/nknkol/harmonybrew-cask/releases/download/bottles%2Fstarship"
    sha256 cellar: :any_skip_relocation, arm64_ohos: "4a52d0db5b59f1c3dee4951d31fe9acb44f95da5b582e4abe62299a20ff5b61d"
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
    starship = buildpath/"starship"
    sign_elf! starship
    bin.install starship

    generate_completions_from_executable(bin/"starship", "completions")

    pkgshare.mkpath
    (pkgshare/"ohos-init.zsh").write <<~'EOS'
      # HarmonyOS PC shell init glue from the starship formula; regenerated on upgrade.
      _starship_ohos_setup_tz() {
          [[ -n ${TZ:-} ]] && return
          local off sign hh mm
          off=$(date +%z 2>/dev/null) || return
          [[ $off == [+-][0-9][0-9][0-9][0-9] ]] || return
          sign=${off[1]} hh=${off[2,3]} mm=${off[4,5]}
          hh=${hh#0}
          [[ -z $hh ]] && hh=0
          # POSIX TZ sign is inverted: UTC+8 is written "UTC-8".
          [[ $sign == + ]] && sign=- || sign=+
          export TZ="UTC${sign}${hh}${mm:+:${mm}}"
      }
      _starship_ohos_setup_tz
      unset -f _starship_ohos_setup_tz

      _starship_ohos_brew="${HOMEBREW_PREFIX:-$(brew --prefix 2>/dev/null)}"
      _starship_ohos_f1="$_starship_ohos_brew/share/zsh/functions"
      _starship_ohos_f2="$_starship_ohos_brew/share/zsh/site-functions"
      if [[ -d $_starship_ohos_f1 ]] && (( ! ${fpath[(Ie)$_starship_ohos_f1]} )); then
          fpath=("$_starship_ohos_f1" $fpath)
      fi
      if [[ -d $_starship_ohos_f2 ]] && (( ! ${fpath[(Ie)$_starship_ohos_f2]} )); then
          fpath=("$_starship_ohos_f2" $fpath)
      fi

      autoload -Uz compinit && compinit -C 2>/dev/null
      # Init unconditionally zmodload zsh/mathfunc (missing in the system zsh); fallback below overrides __starship_get_time.
      eval "$($_starship_ohos_brew/bin/starship init zsh)" 2>/dev/null
      if ! zmodload -e zsh/mathfunc 2>/dev/null; then
          zmodload zsh/datetime 2>/dev/null
          __starship_get_time() {
              typeset -gi STARSHIP_CAPTURED_TIME
              (( STARSHIP_CAPTURED_TIME = EPOCHREALTIME * 1000 ))
          }
      fi
      unset _starship_ohos_brew _starship_ohos_f1 _starship_ohos_f2
    EOS
  end

  def caveats
    <<~EOS
      Add this line to ~/.zshrc to enable the bundled HarmonyOS PC shell init glue
      (timezone fallback, fpath, compinit, mathfunc fallback):

        [ -f "$(brew --prefix)/opt/starship/share/starship/ohos-init.zsh" ] && source "$(brew --prefix)/opt/starship/share/starship/ohos-init.zsh"
    EOS
  end

  test do
    assert_predicate pkgshare/"ohos-init.zsh", :file?
    assert_match "starship #{version}", shell_output("#{bin}/starship --version")
    ENV["STARSHIP_CONFIG"] = ""
    assert_equal "\e[1;32m❯\e[0m ", shell_output("#{bin}/starship module character")
  end
end
