#!/usr/bin/env ruby
# frozen_string_literal: true

# Disable Linux close_range syscall 436 in Bun's AArch64 glibc binary. The
# HarmonyOS syscall filter terminates the process instead of returning ENOSYS.
# Every signature is version-specific and must match exactly once.

abort "usage: #{$PROGRAM_NAME} ELF" unless ARGV.length == 1

path = ARGV.fetch(0)
data = File.binread(path)
nop = ["1f2003d5"].pack("H*")

original_interpreter = "/lib/ld-linux-aarch64.so.1\0".b
ohos_interpreter = "/data/storage/el2/base/ld\0\0".b
abort "interpreter replacement changed size" unless original_interpreter.bytesize == ohos_interpreter.bytesize
abort "expected exactly two ELF interpreter strings" unless data.scan(original_interpreter).length == 2

data.gsub!(original_interpreter, ohos_interpreter)

def patch_unique!(data, name, signature_hex, replacements)
  signature = [signature_hex].pack("H*")
  offsets = []
  cursor = 0
  while (offset = data.index(signature, cursor))
    offsets << offset
    cursor = offset + 1
  end

  abort "expected exactly one #{name} signature, found #{offsets.length}" unless offsets.length == 1

  base = offsets.first
  replacements.each do |instruction_index, instruction|
    data[base + instruction_index * 4, 4] = instruction
  end
  warn format("patched %s at file offset 0x%x", name, base)
end

# close_range(start_fd, INT_MAX, CLOEXEC): force Bun's existing fd fallback.
patch_unique!(data, "Bun close_range fallback",
              "80368052e103142a0200b0128300805283d9a394000100b4",
              { 4 => nop })

# Generic close_range wrapper: return -1 without entering the forbidden
# syscall. Its callers treat the negative return as unsupported.
patch_unique!(data, "Bun close_range wrapper",
              "fd7bbfa9fd030091e303022ae203012ae103002a80368052fd7bc1a8b5d7a314",
              { 5 => ["00008092"].pack("H*"), 7 => ["c0035fd6"].pack("H*") })

# close_range(3, ~0U, CLOEXEC): the upstream caller ignores its result.
patch_unique!(data, "Bun close_range fd 3",
              "8036805261008052020080128300805285d7a394",
              { 4 => nop })

# Process initialisation close_range(4, ~0U, CLOEXEC).
patch_unique!(data, "Bun process init close_range",
              "803680528100805202008012830080521300801217bddd94f2bcdd94",
              { 5 => nop })

File.binwrite(path, data)
