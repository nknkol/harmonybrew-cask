#!/usr/bin/env ruby
# frozen_string_literal: true

# Patch Bun's process-initialisation sequence for HarmonyOS's musl/seccomp:
#   setvbuf(stdout, NULL, _IONBF, 0)  -> aborts on HarmonyOS
#   setvbuf(stderr, NULL, _IONBF, 0)  -> aborts on HarmonyOS
#   close_range(4, ~0U, CLOEXEC)      -> blocked by the syscall filter
#
# The complete instruction signature is deliberately version-specific. A
# Claude/Bun update must fail closed instead of silently patching unrelated
# AArch64 instructions.

abort "usage: #{$PROGRAM_NAME} ELF" unless ARGV.length == 1

path = ARGV.fetch(0)
data = File.binread(path)
nop = ["1f2003d5"].pack("H*")

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

# close_range(start_fd, INT_MAX, CLOEXEC): force the existing fallback path.
patch_unique!(data, "Bun close_range fallback", [
  "80368052e103142a0200b012830080528c54b294000100b4",
].join, { 4 => nop })

# Out-of-line close_range wrapper: return -1 without entering the forbidden
# syscall. Callers use the failure result to select their fallback.
patch_unique!(data, "Bun close_range wrapper", [
  "fd7bbfa9fd030091e303022ae203012ae103002a80368052fd7bc1a88152b214",
].join, { 5 => ["00008092"].pack("H*"), 7 => ["c0035fd6"].pack("H*") })

# close_range(3, ~0U, CLOEXEC): its result is intentionally ignored upstream.
patch_unique!(data, "Bun close_range fd 3", [
  "803680526100805202008012830080525952b294",
].join, { 4 => nop })

init_signature = [
  "887601f000b945f9e1031faa42008052e3031faabf52b294",
  "887601f000bd45f9e1031faa42008052e3031faab952b294",
  "8036805281008052020080128300805213008012bb4fb294",
  "a64fb294",
].join

patch_unique!(data, "Bun process init", init_signature, { 5 => nop, 11 => nop, 17 => nop })
File.binwrite(path, data)
