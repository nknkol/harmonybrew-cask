#!/usr/bin/env ruby
# frozen_string_literal: true

# Universal HarmonyOS ELF In-Memory Patch Loader installer.
#
# Usage from a Homebrew Formula:
#   tap_root = Pathname.new(__FILE__).dirname.parent
#   system RbConfig.ruby, (tap_root/"patches/elf-patch-loader/install_loader.rb").to_s,
#          "--binary", (buildpath/"antigravity").to_s,
#          "--config", (tap_root/"patches/antigravity/agy.elfpatch").to_s,
#          "--prefix", prefix.to_s,
#          "--name", "agy",
#          "--glibc-lib", Formula["nknkol/cask/glibc"].opt_lib.to_s,
#          "--sign-tool", sign_tool.to_s

require "fileutils"
require "optparse"
require "pathname"

options = {
  verify: true,
}

OptionParser.new do |opts|
  opts.on("--binary PATH", "Path to upstream unmodified ELF binary") { |v| options[:binary] = Pathname.new(v) }
  opts.on("--config PATH", "Path to .elfpatch configuration template") { |v| options[:config] = Pathname.new(v) }
  opts.on("--prefix PATH", "Formula prefix path") { |v| options[:prefix] = Pathname.new(v) }
  opts.on("--bin-dir PATH", "Optional wrapper directory (default: <prefix>/bin)") { |v| options[:bin_dir] = Pathname.new(v) }
  opts.on("--libexec-dir PATH", "Optional payload/config directory (default: <prefix>/libexec)") { |v| options[:libexec_dir] = Pathname.new(v) }
  opts.on("--payload-name NAME", "Optional installed payload filename") { |v| options[:payload_name] = v }
  opts.on("--program-rel PATH", "Optional @PROGRAM@ substitution value") { |v| options[:program_rel] = v }
  opts.on("--name NAME", "Installed wrapper executable name") { |v| options[:name] = v }
  opts.on("--glibc-lib PATH", "Path to glibc opt_lib directory") { |v| options[:glibc_lib] = Pathname.new(v) }
  opts.on("--sign-tool PATH", "Path to binary-sign-tool-fix") { |v| options[:sign_tool] = Pathname.new(v) }
  opts.on("--objcopy PATH", "Optional path to llvm-objcopy") { |v| options[:objcopy] = Pathname.new(v) }
  opts.on("--no-verify", "Skip build-time ELFPATCH_VERIFY run") { options[:verify] = false }
end.parse!(ARGV)

%i[binary config prefix name sign_tool].each do |req|
  abort "Missing required option --#{req.to_s.tr("_", "-")}" unless options[req]
end

loader_dir = Pathname.new(__FILE__).dirname.realpath
loader_src = loader_dir/"elf_patch_loader.c"
loader_prebuilt = loader_dir/"elf-patch-loader"

bin_dir = options[:bin_dir] || (options[:prefix]/"bin")
libexec_dir = options[:libexec_dir] || (options[:prefix]/"libexec")
FileUtils.mkdir_p([bin_dir, libexec_dir])

# 1. Install the upstream ELF binary untouched into libexec_dir/
payload_name = options[:payload_name] || options[:binary].basename.to_s
payload_dst = libexec_dir/payload_name
FileUtils.cp(options[:binary], payload_dst)
FileUtils.chmod(0644, payload_dst)

# 2. Render .elfpatch configuration into libexec_dir/<name>.elfpatch
conf_text = File.read(options[:config])
glibc_lib = options[:glibc_lib]&.to_s || "/storage/Users/currentUser/.harmonybrew/opt/glibc/lib"
program_rel = options[:program_rel] || "libexec/#{payload_name}"
conf_text = conf_text
  .gsub("@PROGRAM@", program_rel)
  .gsub("@GLIBC_INTERP@", "#{glibc_lib}/ld-linux-aarch64.so.1")
  .gsub("@GLIBC_LIB@", glibc_lib)

conf_dst = libexec_dir/"#{options[:name]}.elfpatch"
File.write(conf_dst, conf_text)
FileUtils.chmod(0644, conf_dst)

# 3. Build or copy the tiny AArch64 ELF patch loader into bin_dir/<name>
wrapper_dst = bin_dir/options[:name]
unsigned_path = Pathname.new("#{wrapper_dst}.unsigned")
signed_path = Pathname.new("#{wrapper_dst}.signed")

begin
  FileUtils.rm_f([unsigned_path, signed_path])

  if loader_prebuilt.exist?
    FileUtils.cp(loader_prebuilt, unsigned_path)
  elsif loader_src.exist?
    cc = ENV["CC"] || "/storage/Users/currentUser/.harmonybrew/bin/clang"
    ok = system(
      cc, "-O2", "-fPIE", "-pie", "-nostdlib", "-fno-builtin", "-fno-stack-protector",
      "-Wl,-z,max-page-size=4096", "-Wl,--no-dynamic-linker", "-o", unsigned_path.to_s, loader_src.to_s
    )
    abort "Failed to compile #{loader_src}" unless ok
  else
    abort "Neither #{loader_prebuilt} nor #{loader_src} found"
  end

  FileUtils.chmod(0755, unsigned_path)

  objcopy = options[:objcopy]
  if objcopy && objcopy.exist?
    stripped = Pathname.new("#{unsigned_path}.stripped")
    if system(objcopy.to_s, "--remove-section=.codesign", unsigned_path.to_s, stripped.to_s, out: File::NULL, err: File::NULL)
      FileUtils.mv(stripped, unsigned_path, force: true)
      FileUtils.chmod(0755, unsigned_path)
    else
      FileUtils.rm_f(stripped)
    end
  end

  ok = system(
    options[:sign_tool].to_s, "sign", "-selfSign", "1",
    "-inFile", unsigned_path.to_s, "-outFile", signed_path.to_s
  )
  abort "Failed to sign #{wrapper_dst}" unless ok

  FileUtils.chmod(0755, signed_path)
  FileUtils.mv(signed_path, wrapper_dst, force: true)
ensure
  FileUtils.rm_f([unsigned_path, signed_path])
end

# 4. Run build-time patch verification
if options[:verify]
  ok = system({ "ELFPATCH_VERIFY" => "1" }, wrapper_dst.to_s)
  abort "ELFPATCH_VERIFY failed for #{wrapper_dst}" unless ok
end
