#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"

# Codex 0.167.0 aarch64-linux-musl reserves /tmp/codex-daemon-<uid>.
# HarmonyOS /tmp is read-only. Redirect only the daemon directory format to
# the app's writable cache. Path::join replaces the /tmp base for absolute RHS.
# The shared directory function is also used by sandbox path exclusion, so
# listener/client discovery and sandbox protection continue to agree.
#
# Put the new Rust format literal in the zero padding after .init's return,
# and extend .init to cover it so llvm-objcopy/signing preserve those bytes.
# No ELF segment moves, and owner/mode/socket validation remains unchanged.
# Keep cd- short: even a 10-digit uid plus / and the 64-digit socket hash must
# fit Linux sockaddr_un.sun_path (108 bytes including the terminator).

abort "usage: #{$PROGRAM_NAME} ELF" unless ARGV.length == 1
path = ARGV.fetch(0)
data = File.binread(path)
profiles = {
  "2fe94d848540ff2a6868c7ebcc494126a974aa409711676d14fa0379e49e6143" => {
    name: "codex", format_offset: 0xb3d1320, literal_offset: 0xcf31dca,
    signature: "00db009000283791e8030091e1630091a6082d97",
    close_range_sites: {
      0xb4717b4 => "803680528300805227d5689480fbffb4",
      0xb4717c8 => "8036805261008052020080128300805220d56894e02100b4",
    },
    calls: [0xb4717bc, 0xb4717d8],
  },
  "020b3f9a9ee5cf589a4c5b8e9cb1d48a755693b3534943cc38e59bbe7261e4e7" => {
    name: "codex-exec-server", format_offset: 0x1f660a4, literal_offset: 0x3128485,
    signature: "008e00d000141291e8030091e1630091c9998997",
    close_range_sites: {
      0x1f98b3c => "8036805283008052f146459480fbffb4",
      0x1f98b50 => "80368052610080520200801283008052ea464594e02100b4",
    },
    calls: [0x1f98b44, 0x1f98b60],
  },
}
profile = profiles[Digest::SHA256.hexdigest(data)]
abort "unsupported Codex binary; expected pristine 0.167.0 aarch64-musl" unless profile
abort "expected aarch64 ELF64 ET_EXEC" unless data[0, 6] == "\x7fELF\x02\x01" &&
  data[16, 4].unpack("v2") == [2, 183]

signature = [profile.fetch(:signature)].pack("H*")
offset = data.index(signature)
abort "daemon format instruction signature mismatch" unless offset == profile.fetch(:format_offset) &&
  data.index(signature, offset + 1).nil?
abort "daemon format literal mismatch" unless data[profile.fetch(:literal_offset), 16] == "\x0dcodex-daemon-\xc0\x00".b
abort "reserved .init padding is occupied" unless data[0x1a0, 0x60] == "\x00" * 0x60

section_headers = data[40, 8].unpack1("Q<")
section_size = data[58, 2].unpack1("v")
init_header = section_headers + section_size
abort "unexpected .init layout" unless section_size == 64 &&
  data[init_header + 16, 24].unpack("Q<3") == [0x400190, 0x190, 0x10]

# HarmonyOS kills close_range with SIGSYS instead of returning an errno.
# Make both calls report failure so upstream uses /proc/self/fd + fcntl.
# Verify the syscall number, arguments, call and conditional fallback first.
profile.fetch(:close_range_sites).each do |site, hex|
  expected_code = [hex].pack("H*")
  abort "close_range instruction mismatch at #{site.to_s(16)}" unless data[site, expected_code.bytesize] == expected_code
end

prefix = "/data/storage/el2/base/cache/cd-"
literal = [prefix.bytesize].pack("C") + prefix + "\xc0\x00".b
abort "daemon socket path too long" unless prefix.bytesize + 10 + 1 + 64 < 108
data[0x1a0, literal.bytesize] = literal
data[init_header + 32, 8] = [0x70].pack("Q<")

# ADRP x0, 0x400000; ADD x0, x0, #0x1a0. Change only the format pointer.
pc = offset + 0x400000
page_delta = (0x400000 - (pc & ~0xfff)) >> 12
imm = page_delta & 0x1fffff
adrp = 0x90000000 | ((imm & 3) << 29) | ((imm >> 2) << 5)
add = 0x91000000 | (0x1a0 << 10)
data[offset, 8] = [adrp, add].pack("V2")
# MOV X0, #-1 replaces only BL syscall. The following CBZ selects fallback.
profile.fetch(:calls).each { |site| data[site, 4] = [0x92800000].pack("V") }
File.binwrite(path, data)
warn "patched #{profile.fetch(:name)} daemon socket root to #{prefix}<uid>"
warn "patched both close_range calls to use upstream descriptor cleanup fallback"
