# muxos

A custom OS stack, built from the ground up, for an OpenComputers rack
running 4 Server blades on one shared component bus. It's a multi-core
system OS: the 3 worker nodes' custom firmware are its cores/threads, and
the kernal is the scheduler/front-end.

- **Kernal (1 node)** -- `kernal/bios.lua` is its entire EEPROM image
  (mirroring the mod's own stock bios.lua, adapted to load `/muxos.lua`
  instead of OpenOS's `/init.lua`), and `kernal/muxos.lua` is its
  "init" -- not a program running under OpenOS, a REPLACEMENT for it.
  There is no OpenOS anywhere on the kernal: no `require`, no `io`/`os`
  libraries, no `event`/`thread`/`keyboard` libraries, no
  `component.proxy()`/dot-shorthand component access. All of those are
  confirmed ABSENT from the mod's own native Lua sandbox (verified
  directly against its Scala source -- see docs/PROTOCOL.md), so
  `muxos.lua` builds every one of those itself from the real primitives
  (`component.list`/`component.invoke`, `coroutine.yield`) instead of
  assuming OpenOS is there to provide them -- the same bare-metal
  discipline `node/bios.lua`/`node/runtime.lua` always had to follow,
  just applied on the kernal too now, including its own minimal
  built-in text console (there is no `io`/`print`-to-screen without
  OpenOS either) and its own single-coroutine event loop (no
  `thread.create` -- there's no OpenOS thread library to fake
  concurrency with). It loads `kernal/compositor.lua` as a sibling file
  read directly off its own boot filesystem, not via `dofile`. The
  compositor is the ONLY file in this whole project that makes a real
  `gpu.*` call for window content -- "only the display node actually
  needs to make those budgeted calls for real" (every GPU method is a
  per-tick-budgeted call in OC's own source, see docs/PROTOCOL.md),
  enforced structurally rather than by convention, and it batches them:
  every window composites into a persistent frame buffer, with at most
  one real screen write per flush, called once per iteration of
  muxos.lua's own event loop. The kernal also holds `node/runtime.lua`
  on its own disk and serves it to workers at boot (see below) -- it's
  the authoritative source for what a worker runs.
- **Workers (3 nodes)** -- no OS, no disk, on purpose. `node/bios.lua` is
  the only thing flashed onto each one's EEPROM, and it's tiny: open a
  Network Card, ask the kernal for `node/runtime.lua`'s source, `load()`
  and run it. No local fallback -- if the kernal isn't up yet, it just
  keeps asking. `runtime.lua` is where job execution, the remote-component
  bridge, and the `gpu` face actually live; it arrives over the network
  fresh every boot instead of being baked into the EEPROM, so it isn't
  bound by the EEPROM's 4096-byte size limit the way the firmware is.
  Each worker is a physically separate computer, so job isolation between
  them is free -- no software sandboxing needed the way a single-process
  multiplexer requires.

See `docs/PROTOCOL.md` for the wire format, including the separate tiny
boot handshake `bios.lua` speaks before it has anything else loaded.

`smux/` and `gmux/` (both vendored below) are **reference material, not a
runtime dependency**. `smux/` is a real, OpenOS-standalone server-side
multiplexer (the "server version of gmux"), studied for its mechanisms
(the metatable-swap isolation trick in `patch.lua`, the job-console/
session/framing protocol for remote attach). `gmux/` (MIT, from
`aawwaaa/OpenPrograms`) is the real graphical multiplexer smux forked
its backend from -- vendored specifically for its **application-facing
API** (`gmux/lib/gmux/frontend/api.lua`, called by apps as
`component.gmuxapi.*`: `create_window`, `get_processes`, etc.), which
smux's backend-only fork never carried. muxos is its own implementation
of equivalent capability, built for a different substrate: physically
separate firmware nodes over a network, not coroutines multiplexed
inside one OpenOS process table. Neither runs on a worker node; nothing
here calls into their code directly -- `node/runtime.lua`'s `gmuxapi`
table is muxos's own implementation of (a growing subset of) gmux's API
shape, not gmux's code. See docs/PROTOCOL.md for what's translated so far
and what isn't yet.

## Layout

```
kernal/bios.lua       the kernal's own EEPROM image: mirrors the mod's stock bios.lua, loads
                       and runs /muxos.lua directly off the boot filesystem -- muxos REPLACES
                       OpenOS on the kernal, there's no OpenOS /init.lua in this picture.
kernal/muxos.lua      kernal "init": boot-serving + discovery + round-robin job dispatch +
                       job registry (jobs) + a minimal built-in REPL/text console, all built
                       on raw component.list/invoke + coroutine.yield, no OpenOS libraries.
kernal/compositor.lua  the only file that touches the real gpu for window content: window
                       registry, Z-order, occlusion culling, dirty tracking, a persistent
                       frame buffer, draw-code execution, blit-to-screen. Read off the boot
                       filesystem by muxos.lua's loadSibling(), not require()/dofile().
kernal/bitmap.lua      half-block/braille pixel-grid encoder for "bit windows" -- OC's gpu
                       hardware has no pixel API, so this is sub-cell encoding on top of the
                       same character grid. Loaded by compositor.lua via loadSibling().
node/bios.lua         worker EEPROM image: tiny network-boot stub, fetches node/runtime.lua
node/runtime.lua       worker's real runtime, served by the kernal (installed as its sibling,
                       NOT flashed anywhere) -- job execution, remote-component bridge, gpu
                       face, gmuxapi (muxos's own, gmux-API-shaped)
docs/PROTOCOL.md      shared wire format: the boot handshake + the main message protocol +
                       the gmux API translation + the bare-metal kernal design
test/emu/              a 4-node (1 kernal + 3 workers) test environment, emulating this
                       project's own verified native primitives -- not the community OCEmu
                       (needs LÖVE2D, not installable headless here). Boots the REAL,
                       unmodified repo files and drives the kernal's REPL like a human would.
smux/                 reference only (see above): a real, standalone OpenOS multiplexer,
                       forked from gmux's backend. Not run on any node in this project.
gmux/                 reference only (see above): the real graphical multiplexer, vendored
                       for its application API shape. Not run on any node in this project.
```

All four kernal-side files (`bios.lua`, `muxos.lua`, `compositor.lua`,
`bitmap.lua`) plus `runtime.lua` need to sit together at the ROOT of the
kernal's boot filesystem (`/bios.lua` flashed to the EEPROM, the rest as
plain files) -- fixed, hardcoded root paths now, not resolved relative
to wherever the install happens to live the way a normal OpenOS install
could, since there's no real filesystem path to resolve a sibling
directory from any more (`muxos.lua` is loaded from a plain string under
a synthetic chunk name, not `@/muxos.lua`).

### smux's one external dependency

`smux/gertinet.lua` (its GERTi transport) requires `hmi/proto.lua`, a
shared wire codec from the monorepo smux was extracted from. `hmi` is
its own separate program, not a dependency of muxos -- `smux/` itself
is reference-only (see above), so this is just an inherited gap in the
reference material's own test suite, not something muxos needs to
resolve. `smux/test/test_gertinet.lua` fails on `require` as a result;
everything else (33 of smux's own tests: framing, session, job_console,
serve, the installer) passes standalone.

## Flashing a worker

From an OpenOS shell that has an EEPROM component available (either the
worker's own, before you've wiped its default BIOS, or via an EEPROM
programmer):

```
eeprom node/bios.lua
```

Then boot that node with no filesystem attached -- it never looks for
one. It will sit broadcasting `BOOT` every 5 seconds until the kernal
answers; that's expected, not a hang.

## Running the kernal

`kernal/bios.lua` is the kernal's EEPROM image -- flash it the same way
as a worker's:

```
eeprom kernal/bios.lua
```

Then copy `kernal/muxos.lua`, `kernal/compositor.lua`,
`kernal/bitmap.lua`, **and** `node/runtime.lua` onto the ROOT of the
kernal's filesystem (as `/muxos.lua`, `/compositor.lua`, `/bitmap.lua`,
`/runtime.lua` -- fixed paths, see "Layout" above) and boot the kernal
with that filesystem attached. There is no OpenOS shell to run
`muxos.lua` from any more -- `kernal/bios.lua` loads and runs it
directly as the kernal's entire resident environment. Workers fetch
`runtime.lua`'s source from the kernal's disk at boot -- it is never
installed on a worker itself; `compositor.lua`/`bitmap.lua` likewise
never leave the kernal.

It discovers workers automatically, then drops into a prompt:

```
muxos> discover
muxos> nodes
muxos> ping 1
muxos> ping 1 10
muxos> run return 1 + 1
muxos> runall return computer.address()
muxos> processes
muxos> spawn 1 return 42
muxos> window hello 5 5 20 5 gpu.set(1,1,"hi from the kernal")
muxos> windows
muxos> bitdemo halfblock 5 5
muxos> bitdemo braille 30 5
muxos> components 1
muxos> call 1 <component addr> getResolution
muxos> quit
```

`processes` shows the kernal's own job registry (`jobs`) -- every job
ever dispatched via `run`/`runall`/`spawn`, with its status, node, and
result or error. This is also what answers a worker's
`gmuxapi.get_processes()` call (see below): the kernal is the only
place that actually knows about every job across every node, so it's
the real implementation, not a per-worker guess.

`spawn <node> <lua code>` dispatches a job and returns immediately with
its id, without waiting for it to finish (unlike `run`) -- the REPL
exposes this mainly to exercise the same fire-and-forget path a
worker's `gmuxapi.create_headless_process()` uses. `window <title> <x>
<y> <width> <height> <lua code>` allocates a GPU buffer, runs the code
against it (with `gpu` bound to the buffer), and marks it dirty; the
actual real screen write happens in the background dispatcher's next
`compositor.flush()` (at most once per tick), not immediately when you
run the command. `windows` lists what's been created. Overlapping
windows are handled correctly -- occlusion culling means a window
covered by another doesn't get needlessly re-composited, and a
partially-covered one blits only its actually-visible fragments. See
docs/PROTOCOL.md's "The compositor" section for the mechanism, adapted
from gmux's real `graphics.lua`.

`bitdemo <halfblock|braille> <x> <y>` draws a small test pattern as a
**bit window** -- OC's GPU hardware has no pixel API at all (confirmed
from source: every draw method operates on a character+color cell,
never a raw pixel), so `kernal/bitmap.lua` encodes a pixel grid into
half-block (`▀`, two real colors per cell, 1x2 sub-pixels -- good for
multi-color content like a wallpaper or gradient) or braille (`⠿`, one
effective color per cell but 4x the sub-pixel density, 2x4 per cell --
good for a toolbar and small icons, which are almost always monochrome
silhouettes anyway, so the density matters more than the color limit)
character runs instead. `createWindow`'s `options.pixels`/
`mode`/`bg` go through the exact same registry, Z-order, occlusion, and
frame-buffer pipeline as a character-mode window -- `bitdemo` is just
the REPL's way to see it work without typing a pixel grid by hand.

`ping <node> [count]` times a round-trip PING/PONG with that node (default
3 tries) and reports min/avg/max in milliseconds -- useful for measuring
the rack's actual message latency directly, since OpenComputers doesn't
document whether a Rack's internal bus behaves like a Switch's relay
(see docs/PROTOCOL.md).

`components`/`call` are a thin "remote component" layer: they let you
address a worker's own hardware (`components 1` lists what's attached to
node `[1]`, `call 1 <addr> <method> [args]` invokes a method on it) without
writing one-off job code. It still only works because of the Network Card
message-passing underneath -- see `docs/PROTOCOL.md` for why OpenComputers
doesn't allow direct cross-machine component access at all, Rack or not.

`LIST`/`INVOKE` are symmetric -- either side can ask the other to act on
its own components -- which is what lets a worker fall back to the
kernal's hardware when it has none locally. `node/runtime.lua` exposes
this as a `gpu` face: `gpu.set(x, y, text)` etc. use a local `gpu`
component if one happens to be attached (zero network hops), and only
call back to the kernal, caching the discovered address, when the node
has none. This is the first slice of "run OpenOS-API-shaped code on a
worker, as close to native as makes sense, forwarding to the kernal only
when something genuinely isn't local" -- not full OpenOS-library
compatibility yet, just the dispatch pattern proven on one component
type (`gpu`). The old gap here (the kernal only serviced an incoming
request while something was actively polling, not while the REPL was
blocked at its prompt) is resolved now by routing every wait -- the
REPL idling at its prompt included -- through the same `tick()`
primitive, since muxos is bare-metal and there's no OpenOS thread
library to run a separate background poller on any more; see
docs/PROTOCOL.md for the full design.

**One exception to that symmetry**: `INVOKE` targeting the kernal's real
gpu or its bound screen is blocked -- those are the compositor's, and
going around it defeats the point of having one. Calling `gpu.set(...)`
etc. from a worker without a grant now fails with "direct gpu/screen
access is blocked" instead of quietly drawing on the kernal's live
screen; use `gmuxapi.create_window()` for ordinary output.
`gmuxapi.request_fullscreen()`/`release_fullscreen()` are the one way
through, for a fullscreen app that genuinely wants to own the display
directly -- first-come-first-served, one holder at a time, NOT released
automatically if its holder disappears. See docs/PROTOCOL.md's
"The compositor" section.

`node/runtime.lua`'s `gmuxapi` table is muxos's translation of gmux's
actual *application* API (`component.gmuxapi.*` in gmux itself -- see
`gmux/lib/gmux/frontend/api.lua`) for a networked substrate rather than
gmux's one-process-table assumption. All five pieces built so far are
remote calls, never local-first like `gpu`, since no worker could ever
answer any of them from its own state alone:

- `get_processes()` -- the kernal's job registry, as before.
- `create_headless_process(options)` / `create_graphics_process(options)`
  -- dispatch a new job (`options.code`, a Lua source string, replacing
  gmux's `options.main`/`main_path` -- a function or file path can't
  cross the network). Fire-and-forget, like gmux's own versions: you get
  `{process = {id, node}}` back immediately, not the result.
  `create_graphics_process` also creates a window sized to
  `options.width`/`height`, but does **not** wire the job's own `gpu`
  face to that window's buffer yet -- flagged in docs/PROTOCOL.md, not
  silently assumed to work.
- `create_window(options)` -- also stands in for gmux's separate
  `create_window_buffer`: `options.code` (run ON the kernal, drawing
  into the allocated buffer) replaces gmux's `func(gpu)` callback, since
  a function value can't cross the network either.
- `get_windows()` -- the kernal's window registry (`kernal/compositor.lua`).
- `request_fullscreen()` / `release_fullscreen()` -- not part of gmux's
  real API (it never needs this; its apps already share the host
  process's real gpu/screen directly). Added because direct gpu/screen
  `INVOKE` is blocked by default now -- this is how a node gets let
  through, for a fullscreen app that wants to bypass the compositor's
  buffer/blit indirection on purpose.

See docs/PROTOCOL.md for exactly what's NOT translated: this is not
gmux's real desktop (no layering, dragging, resizing, or input routing
-- `gmux/lib/gmux/frontend/windows.lua`/`graphics.lua` weren't ported),
and `get_backend`/`get_graphics`/`get_process`/`show_error` don't exist
here at all.

## Status

First working slice: network-boot handshake (tiny EEPROM stub + a
kernal-served runtime, chunked since the runtime now exceeds one modem
message's size budget) + discovery + synchronous round-robin job
dispatch with a kernal-side job registry (shared by `submit()` and the
fire-and-forget `SPAWN` path, completion recorded generically either
way) + a symmetric remote-component bridge (kernal<->worker, used by
workers to reach kernal hardware they don't have locally, e.g. `gpu`),
gated so direct gpu/screen access requires an exclusive fullscreen grant
(with a Ctrl+Alt+C local escape hatch to force-release a grant whose
holder disappeared) + a compositor module (`kernal/compositor.lua`)
that's the sole real gpu-touching code in the project for window
content, with Z-order, occlusion culling, dirty tracking, and a
persistent frame buffer flipped to the real screen with one `bitblt`
per flush, adapted from gmux's real `graphics.lua` + a single-coroutine
event loop (`tick()`) that every wait in the program funnels through,
replacing OpenOS's thread library entirely now that the kernal is
bare-metal + every message over the modem generically chunked (not
just boot's `CODE`), with stale-partial sweeping on both sides + five
translated pieces of gmux's application API (`get_processes`,
`create_headless_process`, `create_graphics_process`, `create_window`,
`get_windows`) plus the fullscreen-grant pair + latency probing +
"bit window" support (`kernal/bitmap.lua`: half-block and braille
pixel-grid encoders, both verified dot-by-dot and run-length-batched
into the fewest `gpu.set` calls possible, slotted into the same
window/compositor pipeline as character-mode windows) + the kernal
itself now fully bare-metal (`kernal/bios.lua` + a `muxos.lua` built
entirely on native primitives, with its own minimal text console and
keyboard-modifier tracking replacing OpenOS's io/keyboard libraries) +
protection against OC's real non-yielding timeout for dispatched `JOB`
code (a voluntary `yield()` a job can call to cooperate, plus a hard
instruction-budget circuit breaker that kills a non-cooperating job
before it risks the mod killing the whole worker -- see
docs/PROTOCOL.md for why the obvious "force a yield from a debug hook"
fix doesn't actually work in Lua 5.3) + a 4-node test environment
(`test/emu/`) that boots the real, unmodified files end to end and
drives the kernal's REPL like a human would, which caught two genuine
bugs no isolated unit mock could have (a compositor `flush()` that
wiped the console's own output, and a job-preemption design that could
hang a job calling `gmuxapi.*` forever -- see docs/PROTOCOL.md's
"Hardening found by actually running the real files together").
Not yet built: a real scheduler (load balancing beyond round-robin, async
futures/callbacks for `submit()` itself, not just `SPAWN`), node
health/failure handling, the fullscreen grant's no-automatic-release-on-
crash gap, broader OpenOS-compatibility-shim coverage for legacy
programs beyond `gpu` (see docs/PROTOCOL.md's OpenOS-compatibility
section for the intended shape), dragging/resizing/input routing (still
not gmux's full desktop), per-job isolated drawing surfaces (so
`create_graphics_process`'s job and its window are actually wired
together -- true for bit windows too now), an actual toolbar/icons/
wallpaper built with the bit-window encoder (the encoder works, nothing
composites a desktop with it yet, and closing a window to a toolbar
icon isn't built either -- see docs/PROTOCOL.md for the intended
semantics), the REPL's own line editor (append/backspace only -- no
history, no cursor movement within a line), multi-monitor support
(explicitly deferred until the single-GPU case works end to end), and
anything workload-specific.
