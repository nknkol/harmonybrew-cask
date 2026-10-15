# Codex 0.162.1 on HarmonyOS

Upstream: https://github.com/openai/codex/releases/tag/rust-v0.162.1

The formula installs the complete `codex-package-aarch64-unknown-linux-musl`
archive under `libexec`. Keeping `codex-package.json`, `bin`, `codex-path`, and
`codex-resources` together lets the daemon discover and copy its local package.
The old two-binary installation could not pass this check.

`patch-harmonyos.rb` redirects the format used by
`codex-rs/uds/src/daemon_directory.rs::shared_daemon_socket_directory` from
`codex-daemon-<uid>` to `/data/storage/el2/base/cache/cd-<uid>`.
The absolute right-hand side of `Path::join` replaces the canonical `/tmp` base.
The resulting root remains fixed, independent of CWD, HOME, TMPDIR, and CODEX_HOME.
Both socket creation and sandbox directory exclusion use this same function.
The existing owner, mode 0700, socket, and peer checks remain in place.

The patch changes two AArch64 instructions at file offset `0xa2470b0` to point
to a new Rust format literal at `0x1a0`. The literal occupies verified zero
padding after `.init`'s return; extending `.init` to `0x70` bytes preserves it
through llvm-objcopy and signing, without moving any load segments. The shortened
`cd-` prefix keeps a 10-digit UID plus the 64-digit socket name within Linux's
108-byte `sockaddr_un.sun_path` limit, including its terminator.

Before mutation, the patcher verifies the pristine binary's SHA-256, ELF
architecture, instruction signature, original literal, padding, and section
layout. A different upstream binary fails without modification. A future version
requires inspection and updated guards. All ELF files are signed after patching.

The same guarded patch replaces the two `BL syscall` instructions used for
`close_range(..., CLOSE_RANGE_CLOEXEC)` with `MOV X0, #-1` at file offsets
`0xa2e2f80` and `0xa2e2f9c` (virtual addresses `0xa6e2f80` and `0xa6e2f9c`).
Both calls and their surrounding arguments/branches are verified before writing.
The existing conditional branches then select upstream's `/proc/self/fd` +
`fcntl(FD_CLOEXEC)` fallback, preserving descriptor cleanup and the keep-list.
HarmonyOS terminates syscall 436 with SIGSYS, so waiting for an errno cannot
reach that fallback. No syscall wrapper or unrelated call is changed.

On the affected host, unpatched 0.159.3 and 0.162.1 both fail before shell exec
through the non-PTY setup path. PTY execution succeeds through its alternate
launch path. A re-signed isolated patch restores ordinary pipes, stdout/stderr,
exit-code propagation and nested shell execution. This failure is in CLI process
setup, rather than Code Mode Host's JavaScript execution.

The package also contains a private `ps` shim for the daemon's exact
`-p PID -o stat= -o lstart=` query. HarmonyOS toybox lacks `lstart`; the shim reads
state and start ticks from `/proc/PID/stat`, retaining stable process identity.
Other queries delegate to the system ps. The bundled Linux rg and voice helper
use the private glibc loader; zsh uses the native Harmonybrew zsh.

Build in loh's `codex-bottle2` Docker container with `scripts/build-bottle.sh`.
The formula test covers package discovery/copying, version, rg, zsh, resume/fork
argument parsing, and daemon start/stop. It also launches a real non-PTY shell via
the private setup protocol, verifies its report prefix, stdout/stderr and exit
code, and repeats this test using the daemon's copied package.
Host validation must use CODEX_HOME in
the app's private `/data/storage/el2/base/files` directory: shared `/storage`
directories do not provide the socket ownership/mode semantics Codex requires.
