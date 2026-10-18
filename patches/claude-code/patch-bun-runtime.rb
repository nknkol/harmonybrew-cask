#!/usr/bin/env ruby
# frozen_string_literal: true

# Patch Bun's process-initialisation sequence for HarmonyOS's musl/seccomp:
#   setvbuf(stdout, NULL, _IONBF, 0)  -> aborts on HarmonyOS
#   setvbuf(stderr, NULL, _IONBF, 0)  -> aborts on HarmonyOS
#   close_range(...)                  -> blocked by the syscall filter
#
# Signatures are version-specific. Each target lists one candidate per known
# Claude/Bun build; a build that matches none aborts instead of silently
# patching unrelated AArch64 instructions.

abort "usage: #{$PROGRAM_NAME} ELF" unless ARGV.length == 1

path = ARGV.fetch(0)
data = File.binread(path)
nop = ["1f2003d5"].pack("H*")
bytes = ->(hex) { [hex].pack("H*") }

targets = {
  "Bun close_range fallback" => [
    ["80368052e103142a0200b012830080528c54b294000100b4", { 4 => nop }],
    ["80368052e103142a0200b01283008052c9d0b294000100b4", { 4 => nop }],
  ],
  "Bun close_range wrapper" => [
    ["fd7bbfa9fd030091e303022ae203012ae103002a80368052fd7bc1a88152b214",
     { 5 => bytes.call("00008092"), 7 => bytes.call("c0035fd6") }],
    ["fd7bbfa9fd030091e303022ae203012ae103002a80368052fd7bc1a8a9ceb214",
     { 5 => bytes.call("00008092"), 7 => bytes.call("c0035fd6") }],
  ],
  "Bun close_range fd 3" => [
    ["803680526100805202008012830080525952b294", { 4 => nop }],
    ["8036805261008052020080128300805281ceb294", { 4 => nop }],
  ],
  "Bun process init" => [
    [
      [
        "887601f000b945f9e1031faa42008052e3031faabf52b294",
        "887601f000bd45f9e1031faa42008052e3031faab952b294",
        "8036805281008052020080128300805213008012bb4fb294",
        "a64fb294",
      ].join,
      { 5 => nop, 11 => nop, 17 => nop },
    ],
    [
      [
        "887701d000f145f9e1031faa42008052e3031faaebceb294",
        "887701d000f545f9e1031faa42008052e3031faae5ceb294",
        "8036805281008052020080128300805213008012e3cbb294",
        "cecbb294",
      ].join,
      { 5 => nop, 11 => nop, 17 => nop },
    ],
  ],
}

targets.each do |name, candidates|
  matches = candidates.filter_map do |signature_hex, replacements|
    signature = bytes.call(signature_hex)
    offsets = []
    cursor = 0
    while (offset = data.index(signature, cursor))
      offsets << offset
      cursor = offset + 1
    end
    [offsets, replacements] unless offsets.empty?
  end

  abort "no known #{name} signature matched" if matches.empty?
  abort "ambiguous #{name} signature (matched #{matches.length} candidates)" if matches.length > 1

  offsets, replacements = matches.first
  abort "expected exactly one #{name} signature, found #{offsets.length}" unless offsets.length == 1

  base = offsets.first
  replacements.each do |index, instruction|
    data[base + index * 4, 4] = instruction
  end
  warn format("patched %s at file offset 0x%x", name, base)
end

File.binwrite(path, data)
