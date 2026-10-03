# smux: server multiplexer for OpenComputers (design v0.2 - the Gmux fork)

## 1. Overview

smux ('server mux', vs. Gmux's graphical mux) is a headless multiplexer for OpenComputers/OpenOS:
one powerful server-tier node runs several programs side by side instead of needing one small node
per job. v0.1 (superseded - see history below) built this from scratch with hand-rolled job-table
bookkeeping and no real process isolation. v0.2 forks Gmux's actual, working backend instead.

## 2. What's forked from Gmux, and why

Gmux (`reference/gmux/` in this repo, mirrored from `aawwaaa/OpenPrograms`, MIT) is a real,
working OpenComputers graphical multitasking OS. Its `backend/` layer - process scheduling,
per-process patched environments, virtual components - is genuine OpenOS process isolation,
already proven in production use; its `frontend/` layer is the graphical desktop, which smux has
no use for (headless, remote-only access instead).

Ported into `smux/backend/`, adapted only where headless requires it:
- **`process.lua`** (unchanged from Gmux except OCEmu's missing `ocelot` component, already
  handled gracefully by the original code): each job is an OpenOS `process.load()` coroutine with
  its own patched `component`/`computer`/`event`/`thread` instances, round-robin scheduled,
  crash-contained via `xpcall` + a per-job `error_handler`.
- **`patch.lua`** (unchanged mechanism): the actual isolation trick - `package.loaded["component"]`
  etc. get a metatable swap so every `require("component")` call, from host code or job code,
  transparently resolves to whichever job is "current" at call time, falling back to the real
  module otherwise. No manual threading of an "instances" table through call sites needed.
- **`patchs/00-04`** (`package`, `computer`, `event`, `component`, `thread` - unchanged): the
  per-process environment patches themselves. `40_keyboard`, `50_tty`, `60_io`, `91_gpu`,
  `92_keyboard`, `93_term` were NOT ported - Gmux's graphical/terminal-display support, out of
  scope here.
- **`virtual_components/filesystem.lua`** (unchanged): per-job filesystem rooted at a `path`,
  wrapping/canonicalizing every call so a job can't path-traverse outside its own root.
- **`core.lua`** (host loop, rewritten but same mechanism as Gmux's): see section 3 - this is the
  one piece that is genuinely new/adapted, not a verbatim port, because Gmux's version also drives
  a GUI update callback smux doesn't have.

NOT ported, deliberately: `frontend/*` (graphical desktop/windows), the gpu/screen/keyboard virtual
components, and the graphical patches listed above.

## 3. The host loop (core.lua) - the actual design question this took the longest to settle

A previous attempt at this file got stuck for many iterations re-deriving the same question
without ever writing it down: how does the host loop avoid busy-spinning while still resuming the
right job at the right time, when `pullSignal` returning `queue_empty` can mean either "a real
deadline passed" or "still legitimately blocked waiting for input"?

**The answer, once actually read from Gmux's own working code**: the host loop does not need to
solve this at all. Each `Process:update()` (process.lua, unchanged) already tracks its own
`pull_timeout` and only resumes itself when that has elapsed or a signal is queued for it - that
logic already exists, per-process, and doesn't need to be duplicated at the host level. The host
loop is dumb on purpose: call `process.next()` in a tight loop (cheap - a process that isn't ready
just no-ops), and only do a real (but still non-blocking, `computer.pullSignal(0)`) signal poll
every `config.loop_yield_timeout` seconds (1s, from Gmux's own default) or immediately once every
process is already waiting (`process.all_waiting()` - nothing to gain by spinning with nothing
ready). CPU cost is bounded by that yield timeout, not by trying to compute an exact wake deadline.

Verified under the real emulator (not just reasoned about) - see section 5.

## 4. Remote console layer - session/framing/transport all built and verified end to end under the
real emulator; only io_patch's per-process-fd wiring remains unverified

A follow-up dispatch (qwen3.8:27b) built the session/framing/routing side from `rshell/docs/spec.md`
(this repo's rshell was itself only ever a spec document, never a real implementation - see
below). It hit its iteration budget before finishing documentation or the GERTi transport wiring;
Claude finished the one remaining test failure and this doc update directly rather than spend
another dispatch cycle on what was already 34/35 tests passing.

Built and pure-tested (plain lua5.3, no OpenOS/GERTi dependencies):
- **`framing.lua`**: RSH1-style wire framing from the rshell spec (type/seq/token-len/body-len
  header, chunking at MAX_BODY).
- **`session.lua`**: auth (constant-time compare, native lua5.3 `~`/`&`/`|` - NOT a `bit` library,
  that's a 5.1/LuaJIT convention this codebase doesn't use), lockout after 5 consecutive failures,
  duplicate-sequence replay, idle expiry - the exact rshell spec behaviours.
- **`job_console.lua`**: per-job input queue/output buffer, `read_input()` pops one line with the
  newline stripped (standard `io.read("l")` convention - a test briefly asserted the newline should
  stay, which was the test being wrong, not the code; fixed).
- **`serve.lua`**: the actual bridge - AUTH/ATTACH/INPUT/OUTPUT/DETACH/BYE frame types, routes a
  remote peer's input into the right job's console and a job's output back out, last-attach-wins
  semantics when two peers attach to the same job.
- **`io_patch.lua`**: per-job `io.input`/`io.output`/`io.error`/`io.write`/`print` redirection into
  the job's console buffer, following the same load/unload-hook pattern as Gmux's own `60_io.lua`
  (ported in section 2) rather than the screen-oriented original.

**Transport: DONE and verified end-to-end under the real emulator.**
- **`smux/gertinet.lua`**: smux's OWN GERTi transport endpoint (module `smux_gertinet`, PORT=100,
  PORTS=4 - a local numbering convention for this node only), modeled closely on hmi/b9bbbb9net.lua's
  structure (same openSocket/signal/retry-backoff/trust-list mechanism) but NOT reusing it - different
  protocol, different port range, and per the task they never share a node. Unit-tested with a fake
  injected GERTi object under plain lua5.3 (`smux/test/test_gertinet.lua`, 11 tests: trusted-only
  send/receive, retry backoff timing, connection close handling, id allocation within 100..103).
- **`smux/init.lua`** (was a placeholder): now the real entry point - `M.new(opts)` builds a real
  gertinet endpoint over `require("GERTiClient")` when no endpoint is injected, and still accepts an
  injected fake endpoint for tests (serve.lua's existing test suite is unchanged and passes).
- **Verified end to end under the real OCEmu emulator** (`tools/ocemu/net.py`, three real nodes: MNC +
  server + client, all running real GERTiClient/GERTiMNC over OCEmu's modem board - not plain lua5.3):
  `tools/ocemu/scenarios/smux_server.lua` (a real job process via smux/backend/core+process) and
  `smux_client.lua` complete a full AUTH -> ATTACH -> INPUT ("hello smux") -> OUTPUT ("echo hello
  smux") round trip, twice, then DETACH/BYE - PASS. This is the first time serve.lua has been exercised
  through a real GERTi transport rather than its fake endpoint object.
- Two real bugs found and fixed getting this to pass: (1) `smux/gertinet.lua`'s `poll()` gated
  `accept_pending()` on an empty inbox - if any frame was already queued, incoming connections were
  never opened and the first write was silently dropped by GERTiClient; now always runs. (2) The
  scenario's trust list pointed at a nil address (net.py only exposes earlier-stage daemons' addresses
  to later nodes via `_peers.lua`, so a stage-1 server can't learn its stage-2 client's address that
  way) - the connection was never accepted at all; fixed by configuring the peer address explicitly,
  as refinery-power/main.lua does with settings.hmi_address.

**Still open (honestly flagged)**:
- `io_patch.lua`'s real-OpenOS wiring is NOT yet proven end to end: it swaps handles on the GLOBAL
  `io` table, but OpenOS stores per-process file descriptors in process.info().data.io (lib/io.lua's
  io.stream), so a global-io swap does not intercept a job's print()/io.read() under real OpenOS. The
  e2e scenario above therefore feeds/drains the job's console object directly instead of going through
  io_patch - the transport path is proven, but "a real job's print() lands in its console buffer" is
  still unverified. (A `flush()` method was added to io_patch's stream objects while investigating this
  - OpenOS's print calls stdout:flush(), which would have crashed without it; that part IS fixed and
  unit-tested, but the per-process-fd gap above remains.)
- `job_table.lua` and `console_protocol.lua` from v0.1 are still sitting unused alongside the new
  files above - `console_protocol.lua` in particular looks like it covers similar ground to the new
  `framing.lua`/`session.lua` and should probably be removed rather than kept as of this version;
  not done here, flag for whoever does the transport wiring next.

**rshell itself** (`rshell/docs/spec.md`) has only ever been a specification, never a real
implementation, in this repo - the same gap discovered independently for Gmux and oppm earlier the
same night. Decision (user, 2026-10-01): don't treat this smux work as merely "inspired by" the
spec - treat `session.lua`/`framing.lua` as rshell's actual first real implementation, and promote
them to `rshell/session.lua`/`rshell/codec.lua` once this lands cleanly, so the separate Gateway
project (which needs the identical auth/lockout/dedup/chunking logic) reuses the same code instead
of building a third copy from the same spec.

## 5. What's actually verified, vs. designed-but-not-run

Two scenarios run under the real emulator (`tools/ocemu/run.sh`), not just plain lua5.3 unit tests
- process.lua/patch.lua/core.lua fundamentally depend on real OpenOS process/component APIs, so
  there's no meaningful fake/injected version of "spawn a real coroutine with a real patched
  component table" that runs under plain lua5.3:

- **`smux/test/ocemu_crash_isolation.lua`**: two jobs, one errors deliberately, the other completes
  normally - confirms the crash doesn't take down the other job or the host. PASS.
- **`smux/test/ocemu_fs_isolation.lua`**: two jobs with separate virtual filesystem roots on the
  same real backing disk - confirms job B can't see job A's file, and a path-traversal attempt from
  job B doesn't escape its own root. PASS, with a real gap found and documented, not fixed: when
  `filesystem.lua`'s `wrap()` blocks a path (returns `nil`), none of its methods check for that
  before calling the real `fs.X(nil, ...)` - which raises a raw, uncaught error instead of a clean
  "access denied" return. The escape is still blocked (no data crosses roots, confirmed), just via
  an ugly crash rather than graceful handling - worth fixing in the follow-up, not done here to keep
  this pass scoped to proving the core mechanism, not polishing every method's error handling.

Two real bugs were found and fixed getting these to pass, beyond the gap above:
1. `core.lua`'s loop-exit condition was accidentally changed from Gmux's `process.is_empty() OR
   exited` to `AND` while porting - meaning the loop never ended once jobs naturally finished
   unless something ALSO explicitly called `exit()`, hanging forever. Fixed back to `OR`.
2. The `ocemu_fs_isolation.lua` scenario itself initially called the filesystem API the wrong way
   (`handle.write(...)`, an `io.open()`-style assumption) - the real convention here is a raw
   numeric handle (`comp.write(handle, data)`), matching the actual component API this virtual
   filesystem wraps. Fixed in the test, not the code - the code was right, the test was wrong.

**NOT verified, explicitly flagged rather than silently skipped**: a job spawning sub-processes
and the parent/child kill ordering (`core.lua`'s `kill_with_children`, ported unchanged from Gmux
but never exercised by either scenario above); component-visibility scoping specifically (both scenarios
only exercise filesystem isolation, not "job A can't see job B's virtual eeprom" - the mechanism
(`component._add_component`/`setPrimary`, per-process `components` table) is the same one that
made filesystem isolation work, so it should hold, but it hasn't been separately exercised). The remote
console layer end to end IS now verified under the emulator (section 4: smux_server.lua/smux_client.lua
over real GERTi), except for its io_patch half - see section 4's "Still open" list.

## 7. Production entrypoint and installer (main.lua, smux/installer/, 2026-10-02)

smux had NO deployable program at all until now - section 4's remote-console layer was real and
tested, but only through a test-only OCEmu scenario (`tools/ocemu/scenarios/smux_server.lua`), not
something meant to be installed and run for real.

### 7.1 `smux/main.lua` - the real entrypoint

Mirrors `refinery-power/main.lua`'s pattern (floppy detection via a `.smux-floppy` marker file,
rotating event/error logs via `nodelib/logs.lua`, Ctrl+Alt+C hold-and-exit, crash-restart with its
own backoff following the exact same shape as `refinery-power/app.lua`'s `M.supervise` - not
reused directly, since that one is tied to refinery-power's own `M.run`). Reads `smux.config.lua`
for `secret`/`trusted`/`jobs`, calls `backend/core.load()`, spawns each configured job via
`backend/process.create_process`, and builds the serve object via `require("smux").new(...)`
(section 4). Runs the host loop (`process.next()` + `serve:step()`, idle-sleeping like
`core.lua`'s own `loop_yield_timeout`).

### 7.2 Dry mode - a real design decision, not a mechanical port

refinery-power's dry/live distinction exists because a dry run must not touch real redstone
outputs. smux drives no hardware outputs at all - it just runs job programs and serves a remote
console - so that distinction doesn't map onto it directly. Decision made and implemented here:
**dry mode validates the config and would-be jobs (checks each job file compiles, resolves paths)
but does NOT actually spawn them or open the real GERTi transport** - so an install can be verified
end to end (config is sane, job files exist and compile) without running untrusted job code or
opening a real network endpoint. Live mode proceeds past validation to actually spawn jobs and
build the real transport. Mode selection follows the same `<dir>/mode` file / `--dry-run` flag
convention as refinery-power, plus a config-level `endpoint = "off"` switch.

### 7.3 `smux/installer/` - the floppy installer

Adapted from `refinery-power/installer/installer.lua`'s pattern (own `HOME` = `/home/smux`, own
`/etc/noinstall` marker, own `.shrc` autostart line pointing at `smux/main.lua`, own motd text,
same floppy-logging/spool-copy/VERSION-skip-if-current logic). `smux/installer/test/test_installer.lua`
mirrors refinery-power's own test approach - pure, env-injected, 11 tests, all passing.

### 7.4 What's verified vs. not

Verified: `smux/installer/test/test_installer.lua` (11/11, plain lua5.3) and the existing
`smux/test_all.lua` suite (unaffected, all passing) prove the installer logic and that nothing in
the remote-console/backend layers regressed. **NOT verified**: `main.lua` itself has not been run
end to end under the real OCEmu emulator (a dispatch attempt ran out of iteration budget mid-way
through setting up that exact scenario, debugging a path-resolution mismatch between `net.py`'s
test harness and `main.lua`'s own `debug.getinfo`-based home-directory detection -
`tools/ocemu/scenarios/smux_main_server.lua` is the unfinished scaffold for this). The remote
console layer's OWN transport path is already proven end to end (section 4, via the test-only
scenario) - what's specifically unverified is `main.lua`'s own job-spawning/config-loading glue
around it. Flagged as real follow-up work, not glossed over.

## 6. History

- v0.1 (2026-09-30/10-01): built from scratch, no Gmux fork, no real process isolation - rejected
  the next morning for not being what was actually asked for.
- v0.2 (2026-10-01, this doc): Gmux's real backend forked in. A second redo dispatch attempt at
  this got stuck re-deriving the host-loop design question (section 3) for 33 iterations without
  writing a single file - Claude then wrote `smux/backend/` directly (this section's files) as
  verified scaffolding, handing the remote console layer (section 4) back to a follow-up dispatch
  to build on top of now-proven ground rather than open design space.
