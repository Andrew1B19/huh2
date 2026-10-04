# Wire protocol

There are two layers here, both over the same Network Card and port:

```
PORT = 4477
```

1. **Boot protocol** -- `node/bios.lua` (the actual EEPROM image) speaks
   this, and only this, before it has anything else loaded. Plain
   `WORD <payload>` text, no serializer: `BOOT <node address>` from a
   worker, `CODE <i>/<n> <chunk>` back from the kernal (chunked -- see
   "Boot protocol" below for why). See "Boot protocol" below.
2. **Runtime protocol** -- everything in the Message types table below.
   Spoken by `node/runtime.lua` (what `bios.lua` fetches and runs) and
   `kernal/muxos.lua`. Every message is a Lua table, turned into text
   with a small serializer (`[key]=value` pairs good enough for
   nil/boolean/number/string/table -- no functions, no userdata) and
   sent as the single string payload of `modem.broadcast(PORT, text)`.
   The receiver reconstructs it with `load("return " .. text)`.

The runtime-protocol serializer is implemented twice, once per side, on
purpose: neither `node/runtime.lua` nor `kernal/muxos.lua` can `require`
another file (the former for the same EEPROM-era reasons as before, even
though it now arrives over the network instead of being flashed; the
latter to stay a single deployable file), so there is no shared module
to import. If you change the wire format, change both copies.

## Boot protocol

`node/bios.lua` is deliberately tiny (see "EEPROM size" below) and knows
nothing about the real wire protocol yet -- it just needs to get
`node/runtime.lua`'s source from the kernal and start running it:

1. Worker broadcasts `BOOT <its own address>`.
2. Kernal's `serveBoot()` reads `runtime.lua` off its own disk (a sibling
   file of `muxos.lua`, cached after the first read) and broadcasts it as
   a sequence of `CODE <i>/<n> <chunk>` messages (`BOOT_CHUNK_SIZE` =
   7000 bytes each, comfortably under `maxNetworkPacketSize` even with
   the `CODE <i>/<n> ` prefix -- `runtime.lua` is well past the
   8192-byte single-message budget, see "EEPROM size" below). Every
   worker still waiting on its own BOOT picks up these same broadcasts,
   not just the one that asked -- they all need the identical payload,
   so one set of broadcasts serves all of them.
3. Worker collects chunks by index (`chunks[i] = chunk`, not by arrival
   order -- delivery order isn't assumed), and once all `n` are present,
   `table.concat`s them, `load()`s the result, and calls it.
   `node/runtime.lua` becomes that node's actual runtime, with no
   further involvement from `bios.lua`. A worker only re-broadcasts
   `BOOT` when a wait times out with nothing received, not after every
   single chunk -- otherwise a slow trickle of chunks would keep
   restarting the kernal's whole send.

**No local fallback, by design**: if a `BOOT` goes unanswered (kernal not
up yet, or busy -- see the `pump()` caveat below), the worker just waits
5 seconds and re-broadcasts, indefinitely. The kernal is the
authoritative source for what a worker runs; there's nothing sensible
for a worker to fall back to on its own.

## Message types

| type      | fields                                                  | sent by | meaning                                          |
|-----------|-----------------------------------------------------------|---------|----------------------------------------------------|
| `HELLO`   | `from`                                                    | worker  | "I just booted, here's my address"                |
| `PING`    | `from`                                                    | kernal  | "who's out there"                                  |
| `PONG`    | `from`, `to`                                              | worker  | reply to `PING`                                    |
| `JOB`     | `from`, `to`, `id`, `code`, `args`                        | kernal  | run `code` (a Lua chunk) with `args`               |
| `LIST`    | `from`, `to`, `id`                                        | either  | "list the components attached to you"             |
| `INVOKE`  | `from`, `to`, `id`, `address`, `method`, `args`           | either  | call `component.invoke(address, method, args...)` on the receiver's own component |
| `GETPROCESSES` | `from`, `to`, `id`                                   | worker  | "list every job you know about" (gmux API's `get_processes()`, muxos-shaped) |
| `SPAWN`   | `from`, `to`, `id`, `code`, `args`, `node`                | worker  | "dispatch a new job" (gmux API's `create_headless_process`/`create_graphics_process`); replies immediately with a handle, doesn't wait for the job to finish |
| `CREATEWINDOW` | `from`, `to`, `id`, `title`, `x`, `y`, `width`, `height`, `code` | worker | "allocate a gpu buffer, optionally run `code` against it, blit it to your screen" (gmux API's `create_window`/`create_window_buffer`) |
| `GETWINDOWS` | `from`, `to`, `id`                                      | worker  | "list every window you know about" (gmux API's `get_windows()`) |
| `RESULT`  | `from`, `to`, `id`, `result`                              | either  | success -- `JOB`'s return value, `LIST`'s address→type table, `INVOKE`'s list of return values, `GETPROCESSES`'s job list, `SPAWN`'s `{id, node}` handle, `CREATEWINDOW`'s window record, or `GETWINDOWS`'s window list |
| `ERROR`   | `from`, `to`, `id`, `error`                               | either  | failure -- load error, runtime error, invoke error, or (`SPAWN`/`CREATEWINDOW`) a bad request |

`code` is compiled on the worker as `local args = ...` followed by your
code, then called as `chunk(args)` inside a `pcall`, so a job can refer to
`args` directly:

```lua
return args.x + args.y
```

`id` is chosen by the kernal per job and echoed back so the kernal can
match a `RESULT`/`ERROR` to the `submit()`/`listComponents()`/`invoke()`
call that's waiting on it.

## Why there's a "remote component" layer at all

OpenComputers does not let one computer's Lua sandbox see another
computer's components -- each Server blade has its own isolated
`component` graph, by design, even though all 4 blades sit in the same
Rack (that isolation is literally what makes 4 independent computers fit
in one block). The only bridge between two computers is message-passing
over a Network Card, which is what `PING`/`PONG`/`JOB`/etc. already are.

`LIST` and `INVOKE` don't change that; they just save you from writing a
one-off `JOB` chunk every time you want to poke at a worker's hardware.
`LIST` asks the receiver for its own `component.list()`, and `INVOKE`
asks it to run `component.invoke(address, method, ...)` on the sender's
behalf and ship the return values back. From the kernal's REPL this
reads like a single addressable bus (`components 1`, `call 1 <addr>
getResolution`), but under the hood every call is still a round-trip
message over a Network Card -- there is no way to make it a direct,
zero-hop component call across the machine boundary in this mod.

**Both message types are symmetric** -- either side can send them, and
whichever side receives one services it against its *own* components
(`kernal/muxos.lua`'s `handleList`/`handleInvoke` mirror
`node/runtime.lua`'s handling exactly). This is what lets a worker fall
back to the kernal's hardware when it has none of its own:
`node/runtime.lua`'s `gpu` face
(`gpu.set(x, y, text)`, etc.) checks for a local `gpu` component first --
zero network hops if the node happens to have one -- and only sends a
`LIST`/`INVOKE` to the kernal, caching the discovered address, when it
doesn't. "Lowest overhead": local when local makes sense, one round trip
to the kernal otherwise, never more than that.

## The gmux application API, translated

`gmux/` (vendored, MIT, from `aawwaaa/OpenPrograms`) is a real OC
graphical multiplexer. Its application-facing API is
`gmux/lib/gmux/frontend/api.lua`, reachable from an app as
`component.gmuxapi.*` -- `create_window`, `create_window_buffer`,
`create_headless_process`, `create_graphics_process`, `get_processes`,
`get_windows`, `get_backend`, `get_graphics`, `show_error`,
`get_process`. In gmux this is all same-process, zero-hop: an app and
the window system share one Lua process table, so `api.get_processes()`
just reads `backend.process.processes` directly.

That assumption doesn't hold for muxos: a "process" is a job on some
other physical node, so **the kernal is the only place that actually
knows about all of them** (it's already the scheduler -- `jobs` in
`kernal/muxos.lua` is the real answer `get_processes()` needs, not a
per-worker guess). `node/runtime.lua`'s `gmuxapi.get_processes()` is
therefore always a remote call (`GETPROCESSES`), never local-first like
`gpu` -- there's no local component that could answer it. `handleGetProcesses`
mirrors `handleList`/`handleInvoke`'s shape, serving `jobs` as a plain
list (serializable as-is: ids, node addresses, status, code, result).

**`create_headless_process`/`create_graphics_process`** (`SPAWN`): gmux's
versions take `options.main` (a function) or `options.main_path` (a
`dofile` path) and return a process handle immediately, without waiting
for it to finish. Neither a function value nor a local file path can
cross the network, so muxos's version takes `options.code` (a Lua
source string, the same convention `JOB` already uses) instead -- the
one deliberate shape difference from the real API. `handleSpawn` reuses
`dispatchJob()` (the same dispatch-and-record logic `submit()` itself
is built on) and replies with `{id, node}` right away; the job's actual
completion is recorded later, generically, by the same `jobs[msg.id]`
bookkeeping that a synchronous `submit()` triggers -- whichever side
notices the `RESULT`/`ERROR` first (nothing is synchronously waiting on
a `SPAWN`ed job the way `submit()` waits on its own). `create_graphics_process`
additionally asks for a window (below) sized to `options.width`/
`options.height`, but **does not** wire the spawned job's own `gpu` face
to that window's buffer -- the job still draws to the kernal's primary
screen directly. gmux's version gives the process a genuinely private
vgpu/vscreen; muxos's doesn't have that per-job isolated surface yet.

**`create_window`/`create_window_buffer`** (`CREATEWINDOW`): gmux draws
into a window via a `func(gpu)` callback -- a function value, which
can't cross the network either. muxos's `create_window` takes
`options.code` instead (run ON the kernal, with a `gpu` local already
pointed at the allocated buffer -- `drawIntoBuffer`), and this single
call stands in for both of gmux's -- there's no meaningful distinction
between "draw once into a buffer" (`create_window_buffer`) and "bind a
live source" (`create_window`) when drawing is already a one-shot
remote call by construction, so muxos doesn't expose two separate
functions for it. `createWindow` allocates a GPU buffer
(`gpu.allocateBuffer`, erroring cleanly on a Tier 1 GPU that doesn't
support buffers), runs `code` against it if given, blits it onto the
kernal's real screen ONCE at `(x, y)` (`gpu.bitblt(0, x, y, w, h, buffer,
1, 1)` -- the exact call shape gmux's own `graphics.lua` uses), and
remembers it in `windows`. **This is not gmux's desktop**: no layering,
no dragging, no resizing, no input routing by topmost-window-under-cursor
(`gmux/lib/gmux/frontend/windows.lua`/`graphics.lua`, 482 + 345 lines,
none of it ported) -- just enough bookkeeping to make `create_window`/
`get_windows` real. A window also never redraws itself; "updating" one
means calling `create_window` again.

**`get_backend`/`get_graphics`/`get_process`/`show_error`**: not
translated at all. The first two return gmux's own backend/graphics
modules directly, which don't exist in muxos's model (they're
same-process internals, not something a remote job could hold a
reference to); `get_process`/`show_error` are plausible small
additions but haven't been done.

One real limitation of this symmetric design as built: the kernal only
services an incoming `BOOT`/`LIST`/`INVOKE` request while something is
actively polling the modem (`discover`, `awaitReply`, `pingOnce`). While
the REPL is blocked on `io.read()` at the `muxos>` prompt, nothing pumps
the modem at all, so a worker's boot or remote call can sit unanswered
until the next REPL command happens to trigger a poll. A worker's own
boot loop retries every 5s, so it recovers once a command does -- but a
kernal that's sitting idle at the prompt the moment a worker powers on
will stall that worker's boot for a while. Fixing that for real needs the
kernal to service the network in the background while still reading the
prompt -- exactly what a "multi-threading kernel API" would need to
provide generally, not something patched in just for this.

## Assumptions this depends on

- All 4 nodes are Servers in the same Rack, each with its own Network
  Card. The rack's internal relay carries that traffic between blades
  with no extra cabling -- if that's not how your rack is wired (e.g.
  you're using Linked Cards instead, which are point-to-point and have no
  ports/broadcast), the networking code in both files needs to change.
- Worker nodes have no filesystem and no OS; `node/bios.lua` *is* the
  entire firmware, flashed straight onto the EEPROM, and `node/runtime.lua`
  is what it fetches and runs.
- The kernal boots a normal OpenOS and runs `muxos.lua` as a regular
  program, with `runtime.lua` installed alongside it as a sibling file on
  its own disk (not on any worker).

## EEPROM size

Stock `eepromSize` (the max bytes of code an EEPROM can hold, confirmed
from `application.conf`) is **4096**. This is why `node/bios.lua` and
`node/runtime.lua` are split the way they are: `bios.lua` is the only
thing actually bound by that limit, and at **2806 bytes** (grew a bit
for chunk-reassembly logic, still comfortably clear) it has plenty of
room. `runtime.lua` (**10765 bytes** as of the gmux API additions)
carries everything that used to make the combined file blow past 4096 --
it's fetched into RAM over the modem instead, so `eepromSize` doesn't
apply to it.

It already exceeds `maxNetworkPacketSize` (8192) as a single message,
though -- this was hit for real once `gmuxapi` was added, not just a
theoretical ceiling. `serveBoot()` now sends it as multiple `CODE
<i>/<n> <chunk>` messages (`BOOT_CHUNK_SIZE` = 7000 bytes/chunk) instead
of one `CODE <source>`, and `bios.lua`'s boot loop reassembles them by
index regardless of arrival order (see "Boot protocol" above) -- this
needed to actually be built, not just flagged, once `runtime.lua`
crossed the line.

## Measured vs. documented latency

The config numbers in OC's `application.conf` (`maxNetworkPacketSize`,
`maxSignalQueueSize`, a Switch's `defaultRelayDelay`/`defaultMaxQueueSize`)
are documented and confirmed. What is *not* confirmed from available docs
is whether a Rack's internal bus between its 4 Server slots applies that
same Switch-style relay delay, or is instantaneous. Rather than guess,
`muxos.lua`'s `ping <node> [count]` REPL command times real PING/PONG
round trips so this can be measured directly on actual hardware instead
of assumed from source.
