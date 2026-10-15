#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"

# Codex 0.162.1 aarch64-linux-musl reserves /tmp/codex-daemon-<uid>.
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
expected = "071cbe8d821cf1b02b6d8ba6c8b7991b228fcb8519dcb68a37d31222bb8cabe5"
abort "unsupported Codex binary; expected pristine 0.162.1 aarch64-musl" unless Digest::SHA256.hexdigest(data) == expected
abort "expected aarch64 ELF64 ET_EXEC" unless data[0, 6] == "\x7fELF\x02\x01" &&
  data[16, 4].unpack("v2") == [2, 183]

signature = ["60d800f000c01091e8030091e16300915e397397"].pack("H*")
offset = data.index(signature)
abort "daemon format instruction signature mismatch" unless offset == 0xa2470b0 &&
  data.index(signature, offset + 1).nil?
abort "daemon format literal mismatch" unless data[0xbd56430, 16] == "\x0dcodex-daemon-\xc0\x00".b
abort "reserved .init padding is occupied" unless data[0x1a0, 0x60] == "\x00" * 0x60

section_headers = data[40, 8].unpack1("Q<")
section_size = data[58, 2].unpack1("v")
init_header = section_headers + section_size
abort "unexpected .init layout" unless section_size == 64 &&
  data[init_header + 16, 24].unpack("Q<3") == [0x400190, 0x190, 0x10]

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
File.binwrite(path, data)
warn "patched Codex daemon socket root to #{prefix}<uid>"
