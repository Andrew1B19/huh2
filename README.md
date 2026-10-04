# muxos

A custom OS stack, built from the ground up, for an OpenComputers rack
running 4 Server blades on one shared component bus. It's a multi-core
system OS: the 3 worker nodes' custom firmware are its cores/threads, and
the kernal is the scheduler/front-end.

- **Kernal (1 node)** -- boots a normal OpenOS, is the bootstrap/scheduler
  and the only node you actually interact with. Runs `kernal/muxos.lua`
  plus `kernal/compositor.lua`, a sibling module it loads via `dofile`.
  The compositor is the ONLY file in this whole project that makes a
  real `gpu.*` call -- "only the display node actually needs to make
  those budgeted calls for real" (every GPU method is a per-tick-budgeted
  call in OC's own source, see docs/PROTOCOL.md), enforced structurally
  rather than by convention. The kernal also holds `node/runtime.lua` on
  its own disk and serves it to workers at boot (see below) -- it's the
  authoritative source for what a worker runs.
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
kernal/muxos.lua    kernal program: boot-serving + discovery + round-robin job dispatch +
                       job registry (jobs) + REPL
kernal/compositor.lua  the only file that touches the real gpu: window registry, buffer
                       allocation, draw-code execution, blit-to-screen. Loaded by muxos.lua
                       via dofile() as a sibling file.
node/bios.lua         worker EEPROM image: tiny network-boot stub, fetches node/runtime.lua
node/runtime.lua       worker's real runtime, served by the kernal (installed as its sibling,
                       NOT flashed anywhere) -- job execution, remote-component bridge, gpu
                       face, gmuxapi (muxos's own, gmux-API-shaped)
docs/PROTOCOL.md      shared wire format: the boot handshake + the main message protocol +
                       the gmux API translation
smux/                 reference only (see above): a real, standalone OpenOS multiplexer,
                       forked from gmux's backend. Not run on any node in this project.
gmux/                 reference only (see above): the real graphical multiplexer, vendored
                       for its application API shape. Not run on any node in this project.
```

### smux's one external dependency

`smux/gertinet.lua` (its GERTi transport) requires `hmi/proto.lua`, a
shared wire codec from the monorepo smux was extracted from. That file
isn't vendored here, so `smux/test/test_gertinet.lua` fails on `require`
until it's added -- everything else (33 of smux's own tests: framing,
session, job_console, serve, the installer) passes standalone.

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

Copy `kernal/muxos.lua`, `kernal/compositor.lua`, **and**
`node/runtime.lua` onto the kernal's filesystem as siblings (e.g. all
three in `/home/`) and run `muxos.lua` from the OpenOS shell. Workers
fetch `runtime.lua`'s source from the kernal's disk at boot -- it is
never installed on a worker itself; `compositor.lua` likewise never
leaves the kernal.

```
muxos.lua
```

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
against it (with `gpu` bound to the buffer), blits it onto the kernal's
real screen once, and remembers it; `windows` lists what's been created.

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
type (`gpu`). See docs/PROTOCOL.md for the one known gap (the kernal only
services an incoming boot/remote request while something is actively
polling, not while the REPL is blocked at its prompt).

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
+ a compositor module (`kernal/compositor.lua`) that's the sole real
gpu-touching code in the project + five translated pieces of gmux's
application API (`get_processes`, `create_headless_process`,
`create_graphics_process`, `create_window`, `get_windows`) plus the
fullscreen-grant pair + latency probing.
Not yet built: a real scheduler (load balancing beyond round-robin, async
futures/callbacks for `submit()` itself, not just `SPAWN`), node
health/failure handling, a real multi-threading kernel API (the
REPL-blocks-the-network gap still stands, and so does the fullscreen
grant's no-automatic-release-on-crash gap), broader OpenOS-library-shaped
coverage beyond `gpu`, a real windowing system (layering/dragging/
resizing/input routing) rather than the current one-shot-blit registry,
per-job isolated drawing surfaces (so `create_graphics_process`'s job and
its window are actually wired together), multi-monitor support
(explicitly deferred until the single-GPU case works end to end), and
anything workload-specific.
