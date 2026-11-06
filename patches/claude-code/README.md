# Claude Code on HarmonyOS

`patch-bun-runtime.rb` supports the previously packaged 2.1.281 / 2.1.292
Bun builds and the 2.1.318 linux-arm64-musl binary. Each target must match
exactly one known AArch64 instruction signature. ELF architecture is checked
before patching, and all changes stay in memory until every target passes.
Unknown or already patched inputs fail without rewriting the file.

For 2.1.318 the upstream binary SHA-256 is
`a5ec862f882101dbe3e959ec166ab144e902a8e8e76215a2345b3860fe92ad28`
(from the upstream release manifest). Its sites are:

| File offset | Change |
| --- | --- |
| `0x59607e8` | Skip the direct close_range syscall so the existing fallback runs |
| `0x5833100` | Make the close_range wrapper return failure |
| `0x699eca4` | Skip the fd-3 close_range call |
| `0x699f9d8` | Skip the two process-initialisation setvbuf calls |
| `0x699fa9c` | Skip the separate process-initialisation close_range call |

The newer Bun inserts signal setup between setvbuf and close_range, so the
startup calls now need separate signatures. The formula signs the patched ELF
afterwards. Historical formulae retain the earlier signatures in this patcher.
