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
| `REQUESTFULLSCREEN` | `from`, `to`, `id`                                | worker  | "let me bypass the compositor and INVOKE the real gpu/screen directly" |
| `RELEASEFULLSCREEN` | `from`, `to`, `id`                                | worker  | give that grant back |
| `RESULT`  | `from`, `to`, `id`, `result`                              | either  | success -- `JOB`'s return value, `LIST`'s address→type table, `INVOKE`'s list of return values, `GETPROCESSES`'s job list, `SPAWN`'s `{id, node}` handle, `CREATEWINDOW`'s window record, `GETWINDOWS`'s window list, or `REQUESTFULLSCREEN`/`RELEASEFULLSCREEN`'s `{granted/released = true}` |
| `ERROR`   | `from`, `to`, `id`, `error`                               | either  | failure -- load error, runtime error, invoke error, a bad `SPAWN`/`CREATEWINDOW` request, a blocked display-component `INVOKE`, or a refused fullscreen request |

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

**With one exception, added once the compositor existed to make it
matter (see "The compositor" below): `INVOKE` targeting the kernal's own
real gpu or the screen it's bound to is blocked unless the sender holds
the exclusive fullscreen grant.** Every other component, on either side,
is unaffected -- this is narrowly about the two component types the
compositor exists to own.

## The compositor: only one file in this project touches the real gpu

Every GPU method is a per-tick-budgeted `direct` call in OC's own source
(see "Call budget" below) -- "only the display node actually needs to
make those budgeted calls for real" is the actual design principle, and
`kernal/compositor.lua` is what makes that true **structurally**, not
just by convention: it's the only file, anywhere in this project, that
calls a real `gpu.*` method. `kernal/muxos.lua`'s `handleCreateWindow`/
`handleGetWindows` are thin wire plumbing around
`compositor.createWindow()`/`compositor.listWindows()`; nothing else in
`muxos.lua` touches `component.gpu` directly any more.

**How it actually composites, adapted from gmux's real desktop**
(`gmux/lib/gmux/frontend/graphics.lua`'s `Block`/`get_boxes`/
`subtract_rectangle` -- not just its bookkeeping shape this time):

- Windows are kept in `windowOrder`, a Z-ORDERED list (index 1 =
  topmost), same convention gmux uses. A new window is inserted above
  every existing window at the same or lower `layer`.
- **Occlusion culling**: before compositing a window, `visibleBoxes()`
  subtracts the rectangle of every window ABOVE it from its own
  rectangle (`subtractRectangle`, pure geometry, ported faithfully),
  leaving 0 (fully covered), 1 (unoccluded), or several disjoint
  fragments (partially covered) -- verified with a window fully
  interior to another, correctly splitting into exactly 4 strips whose
  combined area matches the expected remainder.
- **Dirty tracking**: a window only gets re-composited if `win.dirty` is
  true (set by `createWindow`, cleared once composited) -- this is the
  one-shot-draw analogue of gmux's `vgpu._is_dirty()` polling; we don't
  have a live source to poll, so "dirty" just means "changed since the
  last flush" instead of "changed since the last frame."
- **A persistent frame buffer**: windows composite into it (buffer-to-
  buffer `bitblt` -- confirmed from `GraphicsCard.scala`'s own doc
  comment that `bitblt`'s `dst` isn't limited to the screen), and
  `flush()` does exactly one `bitblt` from the frame buffer to the real
  screen (buffer 0) -- and only if anything actually changed
  (`frameDirty`). Verified: a flush with nothing dirty costs zero real
  GPU calls; a flush with one new window costs exactly one buffer
  composite plus one screen blit, not two separate screen writes.

This is what "batch draw calls responsibly, upper bound once per tick"
actually means in implementation: `flush()` doesn't rate-limit itself --
calling it twice in one tick just repeats the (cheap, now-dirty-free)
work -- the bound comes from *how often it's called*, which is the
background dispatcher thread below, not from anything in `compositor.lua`
itself.

This would be undermined by the generic `INVOKE` bridge, though: before
this, a worker's `gpu` face could reach the kernal's real gpu directly
through `INVOKE`, completely bypassing the compositor's window registry.
`handleInvoke` now checks `isDisplayComponent(address)` (true for the
kernal's own `component.gpu.address` or the screen it's bound to) and
refuses the call unless the sender currently holds
`exclusiveFullscreenOwner` -- a grant acquired via
`gmuxapi.request_fullscreen()`/released via
`gmuxapi.release_fullscreen()`, first-come-first-served, one holder at a
time. This exists for the one legitimate reason to go around the
compositor: a fullscreen app that wants to own the whole display and
draw without the compositor's buffer/blit indirection, not for every job
doing a stray `gpu.set()`. **Not released automatically if its holder
disappears** (reboots, crashes, loses power) -- a real gap, flagged
rather than silently handled; recovering from that today means
restarting the kernal.

`node/runtime.lua`'s `gpu` face is affected by this too: its remote
fallback (used when a worker has no local gpu) goes through the exact
same `INVOKE` path, so calling `gpu.set(...)` etc. from a worker without
holding the fullscreen grant now fails with "direct gpu/screen access is
blocked" instead of quietly drawing onto the kernal's live screen. Use
`gmuxapi.create_window()` for ordinary output; reach for
`request_fullscreen()` only when actually building a fullscreen app.

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
pointed at the allocated buffer -- `compositor.lua`'s `drawIntoBuffer`),
and this single call stands in for both of gmux's -- there's no
meaningful distinction between "draw once into a buffer"
(`create_window_buffer`) and "bind a live source" (`create_window`) when
drawing is already a one-shot remote call by construction, so muxos
doesn't expose two separate functions for it.

`kernal/compositor.lua` does adapt real pieces of gmux's actual desktop
now, not just its bookkeeping shape -- see "The compositor" above for
the full mechanism (z-order, occlusion culling via rectangle
subtraction, dirty tracking, a persistent frame buffer composited into
and flipped to the real screen with one `bitblt` per `flush()`, adapted
from `gmux/lib/gmux/frontend/graphics.lua`'s `Block`/`get_boxes`/
`subtract_rectangle`). **Still not gmux's full desktop**: no dragging,
no resizing, no input routing (`gmux/lib/gmux/frontend/windows.lua`, 482
lines, wasn't touched) -- and still character-cell only, like gmux
itself and like the real GPU hardware (`get`/`set`/`copy`/`fill`/
`bitblt` all operate on an `api.internal.TextBuffer` in
`GraphicsCard.scala` -- there is no pixel/framebuffer API in OC at all).
A window also never redraws itself; "updating" one means calling
`create_window` again, which marks it dirty for the next `flush()`.

**`get_backend`/`get_graphics`/`get_process`/`show_error`**: not
translated at all. The first two return gmux's own backend/graphics
modules directly, which don't exist in muxos's model (they're
same-process internals, not something a remote job could hold a
reference to); `get_process`/`show_error` are plausible small
additions but haven't been done.

**Resolved**: the kernal used to only service an incoming request while
something was actively polling the modem (`discover`, `awaitReply`,
`pingOnce`), which meant a worker's boot or remote call could sit
unanswered while the REPL was blocked on `io.read()` at the prompt. Fixed
with a real background dispatcher thread (`thread.create(...)` near the
bottom of `muxos.lua`) that calls `pump()` continuously and `compositor.flush()`
once per iteration, paced by `os.sleep(0.05)` (~1 tick). Confirmed from
OpenOS's own source this actually works while the REPL blocks: `lib/
thread.lua` implements threads as real coroutines cooperatively scheduled
through the same `event.pull` mechanism, and `os.sleep` (`boot/02_os.lua`:
`repeat event.pull(deadline - computer.uptime()) until deadline`) always
yields at least once, even for `os.sleep(0)` -- so the background thread
keeps running regardless of what the foreground is doing.

This introduced a real hazard that needed a specific fix, not just "add
a thread": two independent pollers both calling
`event.pull(0, "modem_message")` would race over the same queue --
whichever drains a given reply first keeps it, silently starving the
other. So `pump()` is now the ONLY function allowed to touch the event
queue at all, called exclusively from the background thread. Every
synchronous wait (`awaitReply`/`pingOnce`, via the shared `waitForReply`)
no longer polls the modem itself -- it just checks a shared table
(`replyBox`, filled in by `pump()`) and yields with `os.sleep(0)` between
checks. Verified with a mocked harness: a reply queued before a wait
starts, a reply arriving mid-wait, an unsolicited request serviced
directly without ever landing in `replyBox`, and the timeout path.

The background loop is `pcall`-wrapped around its per-iteration work --
without that, an uncaught error in any handler (a bad `INVOKE`, a window
draw-code bug, anything) would silently kill the thread forever, quietly
disabling boot-serving, every remote-component handler, AND the
compositor for the rest of the kernal's uptime, with no symptom beyond
"nothing responds any more." One real gap left: if the thread itself
fails to start, or OpenOS's thread scheduler misbehaves, there's no
watchdog restarting it -- not handled, same honesty-over-coverage
standard as everything else flagged in this doc.

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
room. `runtime.lua` (**11710 bytes** as of the fullscreen-grant API)
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

## Character cells, not pixels -- and what "bitmap windows" means given that

Confirmed from `GraphicsCard.scala`: `get`/`set`/`copy`/`fill`/`bitblt`
all operate on an `api.internal.TextBuffer` -- a codepoint plus a
foreground and background color per cell. There is no pixel or raw
framebuffer API anywhere in OC's GPU/screen hardware. gmux's own desktop
is character-mode for exactly this reason -- there's no lower level to
drop to.

The intended direction for muxos is a **hybrid** desktop: character-mode
windows work the same way (this is what's built), but the compositor
should also be able to composite bitmap-ish content -- a toolbar, icons,
a desktop background image -- and support dedicated "bit windows." Given
the hardware constraint above, that can only ever mean sub-cell encoding
on top of the same character grid, not a real framebuffer. The two
established techniques:

- **Half-block** (`▀`/`▄`/`█`/space, U+2580-range): 1 column x 2 rows of
  sub-pixels per cell, with TWO real colors per cell (foreground = top
  half, background = bottom half). Best fit for a toolbar/icons/wallpaper,
  where distinct color matters more than raw density.
- **Braille** (U+2800 + an 8-bit dot pattern): 2 columns x 4 rows of
  sub-pixels per cell -- higher density, but only one effective color
  per cell (dots are one color against the background), so it's suited
  to line art/outlines, not full-color images.

Neither is built yet. A "bit window" would need an encoder (pixel grid
-> character+fg+bg triples, run-length-batched into as few `gpu.set`
calls as possible -- the same call-minimization lesson as everything
else in this doc) sitting alongside `compositor.lua`'s existing
character-mode `drawIntoBuffer`, with the window registry's model
(buffer, dirty flag, Z-order, occlusion) applying equally to both kinds
of window -- that part of the redesign above was written generically
enough to not need changing when bit windows arrive, but the encoder
itself is a distinct, not-yet-started piece of work.

## Call budget: what's actually rate-limited, and what isn't

Verified against the real mod source (`MightyPirates/OpenComputers`,
`li.cil.oc.server.machine.Machine.scala` and
`li.cil.oc.server.component.{NetworkCard,GraphicsCard}.scala`), not just
inferred from config:

- A computer's entire Lua state is one coroutine. Anything that blocks
  (`os.sleep`, `event.pull`, `computer.pullSignal`) does a real
  `coroutine.yield(...)`, caught by the mod's own `Machine`/`Architecture`
  driver (`NativeLuaArchitecture.runThreaded`) -- not by OpenOS, which is
  just Lua code running inside that same coroutine. Ordinary execution
  happens on a worker thread per computer, off the main Minecraft server
  thread; it only hops onto the main thread for a `SynchronizedCall` (a
  call that needs to touch the actual game world).
- `callBudget` (reset once per tick, `Machine.scala:520`, alongside
  `uptime += 1`) only applies to methods annotated
  `@Callback(direct = true)` -- calls cheap/safe enough to run with NO
  yield at all, straight-line, which is exactly why they need a separate
  cap instead of self-limiting via yield overhead.
- **`modem.send`/`broadcast` are NOT `direct`** (confirmed: no
  `direct = true` in `NetworkCard.scala`). Every send yields and gets
  dispatched normally -- no `LimitReachedException` risk, ever. The real
  cost is a yield/dispatch/resume round trip per call, not a hard
  ceiling: chatty messaging is slow, not failure-prone.
- **Every GPU drawing method IS `direct = true`** -- `set`, `fill`,
  `copy`, `bitblt`, `setActiveBuffer`, `allocateBuffer`,
  `setBackground`/`setForeground`, all of it (`GraphicsCard.scala`).
  These run with no yield and draw from the shared per-tick budget pool.
  `component.invoke(address, method, ...)` costs exactly the same budget
  as calling the method directly -- same annotation-checked path
  (`Machine.scala:372-380`) -- so `handleInvoke`/`faceGpu` forwarding is
  exposed to this exactly like native code would be.

**So the budget-bound resource in this project is GPU calls, not
network bandwidth.** A straight-line Lua loop calling `gpu.set` many
times in one resume can exhaust a tick's budget and start failing a
call partway through; the same loop calling `modem.broadcast` can't hit
that wall at all.

What's NOT verified from this source tree: the exact Lua-visible
failure signature of a budget-exceeded direct call (a catchable
`error()`, or a silent falsy return) -- the native fast-path dispatch
for direct calls lives in the native Lua binding glue, not in this
Scala repository. Not asserted here rather than guessed.

**Why our protocol is already shaped correctly for this**: `JOB` and
`CREATEWINDOW` both carry a whole `code` string executed as one batch,
rather than the network being used per individual primitive. That's
right on both axes that matter -- fewer messages (fewer yield/dispatch
round trips) *and* confining GPU calls to one local resume on the
kernal instead of one network round trip per draw call. The one place
this risk is actually reachable in our own code:
`compositor.lua`'s `drawIntoBuffer` runs
`code` as one uninterrupted resume with no yields, so draw code doing a
big fill via many individual `gpu.set` calls instead of one
`gpu.fill`/`bitblt` is exactly the "many direct calls, same tick, no
yield" shape that can exhaust budget mid-draw -- prefer
`fill`/`copy`/`bitblt` over `set`-loops in window draw code for this
reason, not just speed.

## Measured vs. documented latency

The config numbers in OC's `application.conf` (`maxNetworkPacketSize`,
`maxSignalQueueSize`, a Switch's `defaultRelayDelay`/`defaultMaxQueueSize`)
are documented and confirmed. What is *not* confirmed from available docs
is whether a Rack's internal bus between its 4 Server slots applies that
same Switch-style relay delay, or is instantaneous. Rather than guess,
`muxos.lua`'s `ping <node> [count]` REPL command times real PING/PONG
round trips so this can be measured directly on actual hardware instead
of assumed from source.
