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
   nil/boolean/number/string/table -- no functions, no userdata) --
   and, since every message over the modem is chunked now, not just
   boot's `CODE`, that serialized string is itself wrapped as one or
   more `MSG <id> <i>/<n> <chunk>` wire frames (`CHUNK_SIZE` = 7000
   bytes/chunk, same convention as boot's `BOOT_CHUNK_SIZE`) rather than
   sent as a single `modem.broadcast(PORT, text)` call. Even a message
   that fits in one chunk still gets this framing (`i=1, n=1`) -- one
   wire shape, always, rather than two depending on size. `<id>` is a
   per-sender counter; reassembly is keyed by `(sender's real network
   address, id)`, where the address comes free from the `modem_message`
   signal itself (before any payload is even parsed), not from
   anything inside the message -- this is what lets two different
   senders reuse the same counter value without colliding. The receiver
   reconstructs the original message with `load("return " .. text)`
   only once every chunk of it has arrived.

The runtime-protocol serializer (and the chunking/reassembly logic
around it) is implemented twice, once per side, on purpose: neither
`node/runtime.lua` nor `kernal/muxos.lua` can `require` another file
(the former for the same EEPROM-era reasons as before, even though it
now arrives over the network instead of being flashed; the latter to
stay a single deployable file), so there is no shared module to
import. If you change the wire format, change both copies.

A partial reassembly whose sender never finishes sending (it rebooted
mid-send, say) would sit forever otherwise, so both sides sweep entries
older than 10 seconds -- the kernal from its background dispatcher loop
(already running once per tick for other reasons), the worker from its
main loop (changed from an unbounded `computer.pullSignal()` to
`computer.pullSignal(10)` specifically so this sweep still happens
periodically even with nothing else arriving).

One place this needed its OWN copy of the reassembly logic, not just
the main dispatch loop's: `node/runtime.lua`'s `remoteRequest()` runs
its own nested wait loop (pulling signals directly while blocking on a
specific reply), bypassing the main loop entirely -- so a chunked reply
to an RPC call needs the identical `reassemble()` call inline there
too, not just in the main loop's dispatch.

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

## The kernal is bare-metal

muxos **replaces** OpenOS on the kernal; it does not run under one.
`kernal/bios.lua` is the kernal's entire EEPROM image, and
`kernal/muxos.lua` is what it loads and runs directly off the boot
filesystem -- there is no OpenOS `/init.lua` anywhere in this picture,
the same way a worker never has one.

This matters because a surprising amount of what looks like "the Lua
sandbox" in OpenComputers is actually OpenOS, not the mod. Verified
directly against the mod's own Scala source
(`li.cil.oc.server.machine.luac.{ComponentAPI,ComputerAPI,SystemAPI}`,
plus the stock EEPROM image the mod itself ships,
`assets/opencomputers/lua/bios.lua`), not guessed:

- **`component`'s real native surface is only `list`/`type`/`slot`/
  `methods`/`invoke`/`doc`.** There is no `component.proxy()` and no
  dot-shorthand (`component.gpu`, `component.isAvailable("gpu")`) --
  that's all OpenOS's `lib/component.lua`. `node/bios.lua`/
  `node/runtime.lua` actually called `component.proxy()` already,
  something that was never caught because this project's tests mock
  their own fake `component`/`computer` tables rather than running
  against anything resembling the real native surface -- a real latent
  bug (would have crashed with "attempt to call a nil value" the first
  time a worker actually booted on real hardware), fixed alongside this
  rewrite, not something introduced by it.
- **Corrected later -- see "The real sandbox" below.** This section
  originally said there is no `computer.pullSignal` and that the real
  primitive is yielding the kernel coroutine with
  `coroutine.yield(timeout)`. That was read off the Scala side only and
  is wrong for EEPROM code: the mod's own `machine.lua` runs the EEPROM
  inside a sandbox that DOES provide `computer.pullSignal` and
  `computer.shutdown`, and wraps `coroutine.yield`, so a bare
  `coroutine.yield(timeout)` loses its timeout there. muxos now uses
  `computer.pullSignal`/`computer.shutdown`.

### What muxos.lua builds itself, in place of each OpenOS piece

| OpenOS provided | muxos.lua now builds | 
|---|---|
| `computer.pullSignal(timeout)` | provided by the sandbox -- used directly |
| `computer.shutdown(reboot)` | provided by the sandbox -- used directly |
| `component.proxy(addr)` / dot-shorthand | `componentProxy(addr)`/`primaryComponent(ctype)` -- a metatable over `component.invoke`, duplicated (not shared) in `kernal/compositor.lua` too |
| `event.pull`/`event.listen` | `tick(timeout)` -- one `pullSignal` call per invocation, dispatched inline by signal name; every wait in the program (REPL idle, `waitForReply`, `discover`) calls `tick()` instead of polling |
| `thread.create` (the old background dispatcher) | nothing -- there is exactly one coroutine; see "Resolved, then resolved differently again" below for why the old two-"thread" design doesn't apply any more |
| `io.read()`/`io.write()`, the REPL prompt | a `key_down`-driven line editor (`handleKeyDown`, `inputBuffer`) -- append/backspace only, no history or cursor movement within a line, a real gap against a proper shell, flagged rather than hidden |
| `print` (screen output) | a local `print` shadowing the native (server-console-only) one, routed through a minimal built-in text console (`termWrite`) -- fixed-width, scrolls one row at a time via `gpu.copy`/`gpu.fill`, no word-wrap or scrollback |
| `keyboard.isControlDown()`/`isAltDown()`/`keys.c` | the same key-code constants OpenOS's own `lib/keyboard.lua` uses internally (verified against its source), tracked by hand in a `heldKeys` table updated from raw `key_down`/`key_up` signals |
| `require`/`dofile` (loading sibling files) | `loadSibling(name)` -- reads a file directly off the boot filesystem component (rediscovered via the EEPROM's own stored boot address, the same way `kernal/bios.lua` found it) and `load()`s it; `compositor.lua` receives this same function as its own `...` argument so it can load `bitmap.lua` the identical way |

`kernal/compositor.lua` and `kernal/bitmap.lua` needed much smaller
changes: `compositor.lua` drops its one `require("component")` (the
native `component` global is already visible with no require needed)
and duplicates its own tiny `componentProxy`/`primaryComponent` helper
in place of `component.isAvailable("gpu")`/`component.gpu`;
`bitmap.lua` needed no changes at all -- it never touched `component`
directly, only ever receiving a `gpu`-shaped table as a parameter.

One specific consequence worth calling out: `kernal/compositor.lua` owns
the real screen. The REPL console is normally an ordinary compositor
window; in console mode it's the compositor's exclusive owner and draws
on the screen directly. See "The console" below.

## The real sandbox

All EEPROM code -- and so all of muxos, since the EEPROM loads it --
runs inside the mod's own `machine.lua` sandbox, not on raw Lua. Read
from the mod's source (`assets/opencomputers/lua/machine.lua`) and now
exercised directly: `test/emu`'s emulator boots every node through that
very file (vendored unmodified in `test/emu/oc/`, MIT), playing the
Java host underneath. What it means for muxos:

- **`computer.pullSignal(timeout)` and `computer.shutdown(reboot)` exist**
  (defined in Lua by `machine.lua`) and are what muxos uses to wait and
  to power off.
- **`coroutine.yield` is wrapped**: it yields `(nil, ...)` as a *user*
  yield, which the sandbox's `coroutine.resume` hands back to the
  resumer; only `computer.pullSignal` and friends yield to the machine.
  A bare `coroutine.yield(timeout)` at the top level -- what muxos used
  to do -- loses its timeout: the wait only ends when some signal
  arrives, and `coroutine.yield(true)` doesn't shut down.
- **`debug` has only `getinfo`, `traceback`, `getlocal`, `getupvalue`**
  -- no `debug.sethook`. Every instruction budget muxos had would have
  crashed on its first use; the machine's own deadline replaces them
  (see "JOB code and the non-yielding timeout").
- **No `eris`** -- see "Transparent migration".
- **No `print`** -- muxos never relied on the native one.

The emulator used to run boot code directly against raw Lua, which hid
all of this (the same kind of gap as the modem-address bug). Running
the old code inside the real sandbox reproduced it: the kernal booted
but never discovered a worker. `test/hardware/verify.lua` checks each of
these on real hardware, and passes in the emulated sandbox (test 30).

## Message types

| type      | fields                                                  | sent by | meaning                                          |
|-----------|-----------------------------------------------------------|---------|----------------------------------------------------|
| `HELLO`   | `from`                                                    | worker  | "I just booted, here's my address"                |
| `PING`    | `from`                                                    | kernal  | "who's out there"                                  |
| `PONG`    | `from`, `to`                                              | worker  | reply to `PING`                                    |
| `JOB`     | `from`, `to`, `id`, `code`, `args`, `program`, `restore`  | kernal  | run `code` (a Lua chunk) with `args`; `program` (path, kind, `.mxe` launch response and libraries) when it's a launched program; `restore` is a migrated process's saved state (`mux.restored()`) |
| `LIST`    | `from`, `to`, `id`                                        | either  | "list the components attached to you"             |
| `INVOKE`  | `from`, `to`, `id`, `address`, `method`, `args`           | either  | call `component.invoke(address, method, args...)` on the receiver's own component |
| `GETPROCESSES` | `from`, `to`, `id`                                   | worker  | "list every job you know about" (gmux API's `get_processes()`, muxos-shaped) -- summaries: no source, no result |
| `GETPROCESS` | `from`, `to`, `id`, `jobId`                            | worker  | one job's full record (`gmuxapi.get_process(id)`) |
| `CONTROL` | `from`, `to`, `id`, `jobId`, `verb`, `caller`                | worker  | pause/resume/kill one of the caller's own descendants (`gmuxapi.pause_process`/`resume_process`/`kill_process`) |
| `EVENT`   | `from`, `to`, `jobId`, `event`                                | kernal  | an input event for a process on that node, read with `gmuxapi.pull_event` |
| `OUTPUT`  | `from`, `to`, `jobId`, `text`                                 | worker  | a process's printed output, for the console |
| `LAUNCH`  | `from`, `to`, `id`, `path`, `args`, `caller`                  | worker  | launch a program as the caller's child (`gmuxapi.launch`) |
| `KILL`/`PAUSE`/`RESUME`/`MIGRATE <id> <node>` | raw, unchunked           | kernal  | process control broadcasts, acted on at the process's yield points; only the worker named by `<node>` records one, so a job id reused on another node (after a migration) isn't hit by a stale control |
| `MIGRATABLE` | `from`, `to`, `jobId`                                  | worker  | an `.mxe` called `mux.migratable(save)`: the kernal may now move it |
| `MIGRATED` | `from`, `to`, `jobId`, `state`                           | worker  | answer to `MIGRATE`: the process saved `state` and ended here; the kernal re-sends the same job (same id) to the target as a `JOB` with `restore = state` |
| `MIGRATEFAILED` | `from`, `to`, `jobId`, `error`                      | worker  | answer to `MIGRATE`: not moved (never opted in, save failed, or state can't be serialized); the process carries on |
| `SPAWN`   | `from`, `to`, `id`, `code`, `args`, `node`                | worker  | "dispatch a new job" (gmux API's `create_headless_process`/`create_graphics_process`); replies immediately with a handle, doesn't wait for the job to finish |
| `CREATEWINDOW` | `from`, `to`, `id`, `title`, `x`, `y`, `width`, `height`, `code`, `pixels`, `mode`, `bg`, `ownerJobId` | worker | "allocate a gpu buffer, draw into it (`code`, or a `pixels` bitmap -- see "Character cells, not pixels" below), blit it to your screen" (gmux API's `create_window`/`create_window_buffer`). `ownerJobId` is optional -- see "Window-focus tracking" below |
| `GETWINDOWS` | `from`, `to`, `id`                                      | worker  | "list every window you know about" (gmux API's `get_windows()`) |
| `DRAWWINDOW` | `from`, `to`, `id`, `windowId`, `code`, `args`, `pixels`, `mode`, `width`, `height`, `bg`, `clear`, `caller` | worker | redraw a window the calling process owns (`gmuxapi.draw_window`) |
| `REQUESTFULLSCREEN` | `from`, `to`, `id`                                | worker  | "let me bypass the compositor and INVOKE the real gpu/screen directly" |
| `RELEASEFULLSCREEN` | `from`, `to`, `id`                                | worker  | give that grant back |
| `RESULT`  | `from`, `to`, `id`, `result`                              | either  | success -- `JOB`'s return value, `LIST`'s address→type table, `INVOKE`'s list of return values, `GETPROCESSES`'s job list, `SPAWN`'s `{id, node}` handle, `CREATEWINDOW`'s window record, `GETWINDOWS`'s window list, or `REQUESTFULLSCREEN`/`RELEASEFULLSCREEN`'s `{granted/released = true}` |
| `ERROR`   | `from`, `to`, `id`, `error`                               | either  | failure -- load error, runtime error, invoke error, a bad `SPAWN`/`CREATEWINDOW` request, a blocked display-component `INVOKE`, or a refused fullscreen request |

**Addresses and sender checks.** Every `from`/`to` is a node's
**network card** address, not `computer.address()`: `modem_message`
reports the sending card's address, so that's the only identity a
receiver can check a payload against. The kernal drops any message
whose `from` doesn't match the card that actually sent it, only
records a job's `RESULT`/`ERROR` from the node that job was dispatched
to, and only stores a reply someone is waiting on (from the node it was
asked of). A worker drops mismatched `from` the same way, and accepts
`JOB`/`LIST`/`INVOKE` only from the kernal's card (`kernalAddr`, learned
once from the boot handshake). Until this was fixed, workers addressed
the kernal by its card (from the handshake) while the kernal only
answered to its computer address -- every worker->kernal request would
have been ignored on real hardware. `test/emu`'s emulator had been
reporting computer addresses in `modem_message`, which hid it.

`INVOKE` arguments and results are `table.pack`-style lists with an
explicit `n`, so a `nil` in the middle (a component's `nil, "reason"`
failure return) stays in place instead of shifting what follows it.

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

**The compositor's exclusive mode.** One owner at a time can have the
real screen to itself, with compositing stopped entirely: a node holding
the fullscreen grant, or the kernal's console (console mode, below).
Leaving the mode redraws the composited picture from the window
buffers.

**Ctrl+Alt+C.** A **press** exits fullscreen: it force-releases the
fullscreen grant (whoever holds it -- a crashed holder can't trap the
screen) and leaves console mode. **Holding** it for a second is the
kernal-level interrupt that drops into the full-screen kernal console:
the console becomes the compositor's exclusive owner, focused, drawing
straight onto the real screen. The `comp` command (or another press)
returns to normal compositing (test 10). Ctrl+Alt+C was OpenOS's own
process-interrupt shortcut (`lib/event.lua` checks it on every signal
pull); muxos has no OpenOS underneath, so there's nothing to conflict
with any more and the combo is reclaimed for this.

**GPU stays on the kernal -- a current hard requirement, not just the
usual case**: today, every real `gpu.*` call anywhere in muxos happens
on the kernal, full stop -- `kernal/compositor.lua` is the only file
that touches one, and there is no code path, configuration, or plan to
run it anywhere else right now. If the display component ever moves to
a different physical node than the kernal, the design intent is that
*that* node would run the compositor locally -- but the compositor must
still never make a GPU call *over the network bus*; it would need its
own local copy, not a remote one driving the kernal's. This is called
out explicitly as a possible-only, maybe-never future feature, not a
near-term plan -- for now, "GPU lives on the kernal" is a stated
requirement of the system, the same way T3 hardware is (see "Hardware
requirements" below), not an assumption that happens to hold today.

**Closing a window does not end the program it belongs to.** This
matches gmux's own behavior and is intentional: "close" is a compositor-
level action (remove the window from the display) separate from
"terminate" (kill the job). A closed window becomes an icon on the
toolbar instead of disappearing outright, so the underlying job stays
alive and reachable. The icon a toolbar entry uses, in priority order:
the window's own bitmap, if it was a bit window (`options.pixels`); 
otherwise the program's name, if the window was created via a `run`-
style dispatch that already has a name to use; otherwise an icon
supplied explicitly through the API when neither of those applies. None
of this toolbar/icon compositing is built yet (see "Still not done" in
the bitmap-windows section above) -- this is the intended semantics to
build it against, recorded now so it isn't lost or reinvented
differently later.

## Scheduler

**BUILT**: round-robin job dispatch across the live worker nodes, with
a simple multi-core balancer on top -- the live node with the fewest
running jobs wins, and round-robin order breaks ties (test 27). Beyond that assignment policy, job
handling otherwise follows the same shape gmux already uses (a process
table, `SPAWN`/`JOB` dispatch-and-record as already implemented --
see "The gmux application API, translated" above) for now; this may get
reworked later but isn't a blocker to build against today.

## OpenOS compatibility: how permissive "close to native" actually means

muxos runs legacy OpenOS programs by making them see something that
looks, as closely as practical, like gmux's own environment --
"permissive" here means *in the legacy program's favor*: muxos does not
make design sacrifices of its own to get closer to native OpenOS
behavior. A legacy program invokes OpenOS APIs the same way it always
has; muxos's job is to make those calls work as correctly as it
reasonably can from underneath (effectively presenting itself as gmux to
anything written against gmux's conventions), not to compromise how
muxos itself is built in order to satisfy them. Programs written
against muxos's own extended surface -- the `gmuxapi` translation layer
above, plus whatever further kernel API muxos adds beyond gmux's -- get
first-class access to the hardware and scheduling muxos actually
provides (per-node dispatch, the compositor, multithreading awareness);
legacy OpenOS programs get the best-effort compatibility shim, not equal
footing.

### Running OpenOS programs (decided, not yet built)

This isn't a separate translation layer sitting on top of muxos. muxos
itself understands OpenOS programs and runs them as a native ability of
the OS -- it just also has a much wider API, for much more direct
calls, for programs written specifically for muxos. (A loose analogy:
Windows 95 running DOS programs, except this is the reverse kind of
implementation -- the new OS natively absorbing the old one's programs.)

What that involves, as decided in the design discussion (recorded late
-- it was agreed but never written down):

- **A heavily modified OpenOS, not a from-scratch rewrite.** OpenOS's
  libraries get modified for muxos case by case: some are
  straightforward, some need real reimplementation, and whatever
  doesn't need rewriting from scratch isn't. The approach follows how
  gmux does it where that works.
- **Libraries move toward the nodes as faces.** The legacy userland
  that runs alongside a program on a worker mostly ends up as front-end
  faces: the same OpenOS-shaped API, making the real calls back to the
  OS -- the same pattern as the worker's `gpu` face today.
- **Legacy programs see virtual components, gmux-style.** A legacy
  program is pointed at a virtual GPU/screen (and keyboard, modem,
  ...) exactly as gmux does it, plus muxos's additions. gmux's own
  virtual components (`gmux/lib/gmux/backend/virtual_components/`) get
  forked and built into the OS for this.
- **The front end comes from gmux.** The window/interaction side
  (gmux's frontend) is built from gmux for now.
- **Placement is the scheduler's.** Legacy programs are scheduled like
  everything else -- the kernal decides where they run (see "Placement
  authority never moves").

## `.mxe`: a native-app marker, not a security boundary

muxos programs written to take advantage of its own API (rather than
just making legacy OpenOS calls through the compatibility shim above)
are distinguished from ordinary `.lua` OpenOS programs by their own file
extension, `.mxe`. The kernal's loader uses this purely as a dispatch
signal: a `.mxe` program is launched with lower GPU-call overhead, is
assumed to be multithreading-aware, and otherwise gets treated close to
how gmux treats a native app, unless/until muxos reimplements that part
differently -- while a `.lua` program goes through the OpenOS-
compatibility path described above. **This is a calling-convention
switch, not an access-control mechanism**: nothing stops a program from
lying about its own extension, and there's no adversarial trust model
in this project that would need one. Permissible on that basis -- it's
exactly the kind of "which code path do I run this through" decision a
file extension is good for, as long as nothing security-relevant is ever
gated on it.

## Program launcher -- BUILT

Works like OpenOS's shell: a name typed at the console that isn't a
built-in command is looked up on `/bin` then `/usr/bin` (`.mxe` before
`.lua`), or a path is used as given; the rest of the line is its
arguments, passed as `...`. It runs in the foreground -- the console
waits until it ends and feeds it typed input, echoing it like a
terminal -- unless the line ends with `&`, which runs it in the
background. A process can launch a program too, with
`gmuxapi.launch(nameOrPath, args)`, and becomes its parent. Either way,
the scheduler places it.

- **`.lua`** runs in the OpenOS environment: the standard libraries,
  `print`, `io.write`/`io.read` (console output and input), and `os`
  (`sleep`, `clock`, `time`, `exit`), and nothing muxos-specific (no
  `gmuxapi`). Not built yet: the OpenOS libraries behind `require`, and
  gmux's virtual components (see "Running OpenOS programs").
- **`.mxe`** declares what it expects in a header at the top of the file:

  ```lua
  --[[mxe
  muxos = "0.1.0"
  libraries = {"name", ...}
  ]]
  ```

  The header is evaluated as data (empty environment, small instruction
  budget). The program gets the launcher's response as the global
  `launch`: `muxos` (the actual version), `requested`, `versionMatch`
  (a mismatch never stops it from running), `libraries` (name ->
  found or not) and `errors`. Libraries live at `/lib/mxe/<name>.lua` on
  the kernal's disk, are shipped with the program, load into its own
  environment, and are reached with `require(name)`. Both headers and
  libraries are deliberately minimal for now; the full `.mxe` spec comes
  later.

Every process's `print` (and a legacy program's `io.write`) goes to the
kernal console as `OUTPUT` messages, buffered per process and sent at
its yield points, before it reads input, when it ends, or past 1 KB.
Test 29 covers all of the above.

**Package manager**: OPM (currently an OpenOS package manager) will be
expanded into muxos's native package manager and track installed
packages. The kernal only needs to provide a way for OPM to talk to it.

## Hardware requirements

muxos always assumes a **Tier 3 GPU**, with a **minimum of one Tier 3
screen**, on the kernal. This isn't a guess at commonly-installed
hardware or a tier the code happens to degrade gracefully without --
it's a stated requirement: `kernal/compositor.lua` checks for
`gpu.allocateBuffer` (a T3-only capability, confirmed from OC's own
tier-gated component API) at startup specifically so a kernal that
doesn't meet this fails immediately with a clear error instead of a
confusing one partway through compositing. The persistent frame buffer
the compositor relies on (see "The compositor" above) is itself only
possible because of this requirement -- there is no Tier 1/2 fallback
path, by design.

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

**Resolved, then resolved differently again**: the kernal used to only
service an incoming request while something was actively polling the
modem (`discover`, `awaitReply`, `pingOnce`), which meant a worker's
boot or remote call could sit unanswered while the REPL was blocked on
`io.read()` at the prompt. The first fix was a real background
dispatcher thread (`thread.create(...)`) running `pump()` continuously
alongside the REPL, built on OpenOS's own `lib/thread.lua` (real
coroutines cooperatively scheduled through `event.pull`) and `os.sleep`
always yielding at least once.

That whole fix assumed OpenOS was present to provide `thread`/`event`/
`io.read()` in the first place. Once the kernal became bare-metal (see
"The kernal is bare-metal" below), none of those exist any more, so the
fix changed shape again: there is now exactly ONE coroutine on the
kernal, and the REPL itself is driven by raw `key_down` signals instead
of a blocking `io.read()` -- so there's no separate "foreground blocked
on a prompt" state for a background thread to work around in the first
place. Every wait in the program, including ones nested arbitrarily
deep (a REPL command's `submit()` call blocking on a network reply),
funnels through the same `tick()` function, which pulls exactly one
signal (via `pullSignal`, `coroutine.yield` underneath) and dispatches
it inline -- a key_down to the REPL's line editor, a modem_message to
`handleModemMessage`, either way followed by `sweepStaleChunks()` and
`compositor.flush()`. This is simpler than the two-thread design, not a
downgrade from it: with no OpenOS thread library to fake concurrency
with, servicing everything inline from wherever a wait happens to be
nested is the only correct shape left, and it has the nice property
that `compositor.flush()`/`sweepStaleChunks()` run on every signal
rather than being paced by a fixed `os.sleep(0.05)`.

The one hazard the old design had to solve by construction -- two
independent `event.pull(0, "modem_message")` pollers racing over the
same queue, whichever drains a reply first silently starving the other
-- can't recur at all now: there is only one place `pullSignal` is ever
called (`tick`), so there is nothing left to race. `waitForReply`
doesn't poll a separate shared table and yield between checks any more
either; it just calls `tick()` in a loop and checks `replyBox` after
each one, so a reply that arrives mid-wait is picked up on the very
next signal rather than the next polling interval. Verified with a
mocked harness: a reply queued before a wait starts, a reply arriving
mid-wait, an unsolicited request serviced directly without ever landing
in `replyBox`, and the timeout path (`/tmp/test_central_pump.lua`).

`tick()` keeps the same `pcall` wrapper around its dispatch + maintenance
work the old background thread had, for a sharper reason now: an
uncaught error in a handler would otherwise propagate out of the
kernal's ONLY coroutine, not just kill a background thread the REPL
could survive without.

## Assumptions this depends on

- All 4 nodes are Servers in the same Rack, each with its own Network
  Card. The rack's internal relay carries that traffic between blades
  with no extra cabling -- if that's not how your rack is wired (e.g.
  you're using Linked Cards instead, which are point-to-point and have no
  ports/broadcast), the networking code in both files needs to change.
- Worker nodes have no filesystem and no OS; `node/bios.lua` *is* the
  entire firmware, flashed straight onto the EEPROM, and `node/runtime.lua`
  is what it fetches and runs.
- The kernal has no OpenOS either, as of the bare-metal rewrite (see
  "The kernal is bare-metal" below) -- `kernal/bios.lua` *is* its entire
  firmware, and `kernal/muxos.lua` is what it loads and runs directly
  off its own disk, with `compositor.lua`/`bitmap.lua`/`runtime.lua`
  installed alongside it at the filesystem's root (not on any worker).
  muxos REPLACES OpenOS on the kernal; it is not a program that runs
  under one.

## EEPROM size

Stock `eepromSize` (the max bytes of code an EEPROM can hold, confirmed
from `application.conf`) is **4096**. This is why `node/bios.lua` and
`node/runtime.lua` are split the way they are: `bios.lua` is the only
thing actually bound by that limit, and at **2413 bytes** it has room
to spare. Comments count toward the limit too -- it once grew past 4096
through comments alone, so `test/emu/integration_test.lua` (test 19) now
checks both EEPROM images' sizes. `runtime.lua` (**14411 bytes** as of the generic chunking
layer) carries everything that used to make the combined file blow past
4096 -- it's fetched into RAM over the modem instead, so `eepromSize`
doesn't apply to it.

The kernal has the exact same split now that it's bare-metal too (see
"The kernal is bare-metal" below): `kernal/bios.lua` is bound by the
same 4096-byte limit and sits comfortably under it at **2833 bytes**;
`kernal/muxos.lua` carries everything else and is read off the boot
filesystem directly (not fetched over a network, since the kernal
already has its own disk) rather than flashed, so `eepromSize` doesn't
apply to it either.

It exceeds `maxNetworkPacketSize` (8192) as a single message by a wide
margin now (needing 3 chunks at `CHUNK_SIZE` = 7000 bytes/chunk) -- this
was hit for real once `gmuxapi` was added, not just a theoretical
ceiling, which is exactly why "everything over the bus needs chunking"
is now a blanket rule (see above) rather than boot's own one-off
`CODE` handling plus hoping nothing else ever got this big. A large
`CREATEWINDOW` `pixels` payload is covered by this same generic
chunking now too -- no longer a separate unhandled case.

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
  half, background = bottom half). Best fit for multi-color content
  where resolution matters less than true color -- a wallpaper, a
  gradient.
- **Braille** (U+2800 + an 8-bit dot pattern): 2 columns x 4 rows of
  sub-pixels per cell -- 4x the sub-pixel density of half-block, but
  only one effective foreground color per cell (dots are one color
  against the background). Best fit for a toolbar and small icons
  specifically: those are almost always monochrome silhouettes anyway,
  so the one-color-per-cell limit costs nothing, while the extra
  density is what keeps a small icon recognizable in very few cells --
  and the background color is still free per cell, so button/highlight
  state can vary independently of the icon's own color.

**Built**: `kernal/bitmap.lua` encodes a pixel grid (`pixels[y][x]` = a
24-bit color, or `nil` for background) into character+fg+bg cells for
either mode, and `createWindow` accepts `options.pixels`/`options.mode`/
`options.bg` as an alternative to `options.code` -- same window
registry, same Z-order/occlusion/dirty/frame-buffer compositing either
way, confirming the window model didn't need rework to add this.

Both encoders are verified precisely, not just "doesn't crash": each of
the 8 individual braille dot positions was tested in isolation against
its expected bit (lighting up exactly one sub-pixel and checking the
resulting codepoint matches `0x2800 + <that dot's bit>` -- this is the
one place a wrong bit-to-position mapping would have silently produced
a scrambled-but-still-rendering image, not an error), plus the all-8-on
case (`U+28FF`). Half-block's solid-color collapse (both sub-pixels the
same color -> a plain space, cheaper than a half-block glyph: `fill`'s
own cost function in `GraphicsCard.scala` charges less for a space than
any other character -- `gpuClearCost` vs `gpuFillCost`), its mixed-color
case (▀ with fg=top/bg=bottom), and the fully-transparent case (both
sub-pixels background) are all verified too.

`gpu.set()` paints a whole string under ONE current foreground/
background pair -- confirmed from `GraphicsCard.scala`, color is GPU
state, not per-character within a call -- so `bitmap.draw()` groups
each output row into runs of consecutive cells sharing the same
`(char, fg, bg)` and emits one `setForeground`+`setBackground`+`set`
per run, not per cell. Verified: 6 cells that look identical (3 pairs of
2) collapsed into exactly 2 real `gpu.set` calls, with the right
starting column for each run -- the same call-minimization lesson as
the rest of this doc, and here it's required for correctness (you
literally can't paint two different-colored cells in one `set` call),
not just an optimization.

**One real bug this surfaced, not just a theoretical risk**: width/
height can't be inferred from the pixel grid itself via Lua's `#`
operator -- a row with no "on" pixels is a table whose every entry is
`nil`, and `#` on such a table reports 0 regardless of its real width.
This wasn't a hypothetical; the `bitdemo` REPL command's own demo
pattern (a diamond shape) has an all-background first row, and hit this
exactly. Fixed by making `options.width`/`options.height` REQUIRED
(and meaning the pixel grid's own dimensions, not the character-cell
buffer size, when `options.pixels` is given) rather than inferred,
with a clear error if omitted.

`kernal/muxos.lua`'s `bitdemo <halfblock|braille> <x> <y>` REPL command
exists because typing a pixel grid by hand at a text prompt isn't
practical -- it generates a small filled-diamond test pattern (red
center, blue ring, transparent corners) so there's a way to see the
pipeline work without needing a real deployment yet.

Still not done: no actual demonstrated use for a toolbar/icons/
wallpaper (the encoder works, but nothing composites a desktop
background or icon row yet -- wallpaper is planned to be just another,
lowest-layer bit window through this same mechanism, no separate
subsystem), and per-job isolated bit-window surfaces have the same gap
`create_graphics_process` already has for character windows (see
above) -- a job can ask the kernal to create a bit window, but its own
`gpu` face still isn't wired to draw into it.

A large `CREATEWINDOW` `pixels` grid is no longer a special case now
that every message over the modem is chunked generically (see above) --
this used to be a real unhandled gap (a ~90x90-pixel bitmap would have
exceeded `maxNetworkPacketSize` as a single message) but isn't any more.

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

## JOB code and the non-yielding timeout

Separate from the per-tick `callBudget` above: OpenComputers also kills
a computer that runs too long in real wall-clock time without yielding
at all, regardless of call budget. Not guessed -- `system.timeout` is a
real value exposed to Lua (confirmed in `SystemAPI.scala`), and OpenOS's
own boot code (`lib/core/boot.lua`) explicitly calls `pull(0)` at least
once a second during boot specifically to *"protect from timeouts"*,
pushing back with `computer.pushSignal` whatever it steals so the real
recipient still gets it. The exact Java-side enforcement mechanism
wasn't traced further in this codebase, but the behavior itself is
confirmed real by OpenOS's own defensive code against it, not asserted
from docs alone.

Before this was fixed, `node/runtime.lua`'s `JOB` handler ran dispatched
code as one uninterrupted `pcall` with no yield inside it at all -- a
job with a long loop and no yield of its own risked the MOD killing
that worker's whole computer, not just erroring the job, and the worker
would be unable to answer `PING` or anything else for the job's entire
duration either way.

**How it works now** (after "The real sandbox" findings, below):

- **The machine's own deadline is the circuit breaker.** OpenComputers
  ends any coroutine that runs longer than `system.timeout()` (5s by
  default) without the machine getting a yield -- the sandbox's
  `coroutine.resume` installs that check on every coroutine. A job runs
  in its own coroutine, so a job that never yields is ended with "too
  long without yielding", comes back as an ordinary `ERROR`, and the
  worker survives because its main loop yields to the machine promptly
  afterwards (test 6). There is no tighter muxos-side budget: the
  sandbox has no `debug.sethook`, and a Lua 5.3 hook can't yield anyway,
  so forced preemption isn't possible.
- **`yield()`** -- exposed to job code -- is how a long job cooperates:
  it suspends the job, and `runJobCode` does a real zero-timeout
  `computer.pullSignal` (which resets the machine's deadline), answers
  a PING, sets other traffic aside, acts on pause/kill, then resumes it.
- **`yield()` yields a sentinel (`"__cooperate"`)** because a job's own
  waits (`sleep`, a `gmuxapi` call, `pull_event`) also yield to
  `runJobCode`, with their timeout; the sentinel tells the two apart, so
  a voluntary `yield()` gets a brief pass while a wait gets a real
  signal handed back to it.
- **`sleep(seconds)`** is the way for job code to wait on time. A job
  that waited with a bare `coroutine.yield(timeout)` would be handed --
  and silently consume -- every signal that arrived meanwhile, including
  the `JOB` message for a child the kernal had just queued on that same
  node. `sleep` sets everything aside for the main loop instead.

## Hardening found by actually running the real files together

`test/emu/` is a 4-node test environment (1 kernal + 3 workers) built
on a purpose-written emulator of this project's own verified native
primitives -- not the community OCEmu, which needs a full LÖVE2D
graphics runtime not installable headless in this project's dev
environment (see `test/emu/README.md` for the full design and its
deliberate simplifications). It boots the REAL, unmodified repo files
and drives the kernal's REPL by injecting `key_down` signals the way a
human would, reading back what actually lands on the simulated screen.

This is a different kind of test than everything in `/tmp/test_*.lua`:
those are hand-copied mirrors of individual functions, each mocking its
own `gpu`/`component` in isolation. `test/emu` is the first and only
place the real files run against each other end to end -- and it found
two genuine bugs within the first session of building it, neither of
which any isolated unit mock could have caught:

1. **`kernal/compositor.lua`'s `flush()` used to wipe the kernal's own
   text console.** The console (`termWrite` in `kernal/muxos.lua`)
   writes directly to the real screen (buffer 0) between flushes, since
   it isn't a compositor window. `flush()` used to blit its own
   separately-tracked frame buffer onto buffer 0 wholesale -- mostly
   blank except where windows had been composited -- erasing the
   console's entire prior output the moment any window existed, not
   just the area the window actually covered. No isolated compositor
   unit test could have caught this: none of them have a console
   writing to the same screen concurrently. Fixed by syncing the frame
   buffer FROM the real screen before compositing any newly-dirty
   window -- one extra full-screen `bitblt` per dirty flush, only when
   something is actually dirty, preserving the "zero real GPU calls
   when nothing changed" property. See "The compositor" above for the
   updated cost accounting.
2. **`node/runtime.lua`'s job-preemption design could hang a job
   forever.** Covered in full in "JOB code and the non-yielding
   timeout" above -- wrapping JOB execution in its own coroutine meant a
   job calling `gmuxapi.*` (which does its own nested wait for a
   specific network reply) had that wait's yield mistaken for ordinary
   voluntary cooperation and swallowed instead of forwarded, hanging
   the job forever the moment it tried to use `request_fullscreen()` or
   any other `gmuxapi` call from inside a dispatched `JOB`. Fixed with
   the `yield()` sentinel described there.

Both were caught by scenarios that exercise real cross-subsystem
interaction (a worker's dispatched `JOB` code calling `gmuxapi`; a
window being created while the console has prior output on screen) --
exactly the category of bug a unit-mock suite structurally cannot
reach, since each mock isolates the one function under test from
everything else that would normally be running concurrently on real
hardware.

## The `.mxe` process model

This started as a design decided through discussion, written down
before implementation so it wouldn't get lost or reinvented
differently later. Parent/child jobs, orphan policies, and app-identity
reclaim are now BUILT and verified end to end (`test/emu/integration_test.lua`'s
test 12) -- marked below as each piece is covered, as are persistent
window handles and keyboard delivery. Opt-in `.mxe` migration (through `mux`) and node draining are built too.


### Why this exists

A dispatched `JOB` today is a bare string of Lua source handed to
`load()` -- no structure, no identity, no ability to ask for more
resources, no relationship to anything else. That's fine for a one-shot
calculation. It's not how an actual *app* -- something with a name,
a lifecycle, a window, maybe children of its own -- is supposed to
work. A worker is meant to act like another core on the same machine,
not a separate computer you throw isolated scripts at; the kernal needs
a real framework for that, not just a calling convention for
`load()`.

### Placement authority never moves

The kernal is the only thing that ever decides *where* code runs. This
doesn't change anywhere below -- an app asking for more compute is
asking a question ("please run this somewhere"), never making the
placement decision itself. Everything else in this section is about
what happens around that one fixed point.

### Parent/child jobs -- BUILT

When a running job (the **parent**) wants more compute, it calls
`gmuxapi.create_headless_process`/`create_graphics_process` with
`options.name` and `options.orphan_policy` -- these go out as a
`SPAWN` carrying `parent` (the parent's own job id, exposed to its
running code as the real global `jobId`, set by `node/runtime.lua`'s
main loop right before invoking a `JOB`'s code), `appName`, and
`orphanPolicy`. The kernal places the new job exactly like it places
any other (today: round-robin; later: the real load-aware balancer --
see "Not yet built" in README.md) and hands the **parent** a persistent
handle -- the same `{id, node}` shape `SPAWN`/`create_headless_process`
already returned before this, nothing new needed there.

**The kernal never loses visibility.** Every job -- parent or child,
top-level or several levels deep -- lives in the SAME single global
`jobs` table `kernal/muxos.lua` already had, with `parent`/`appName`/
`orphanPolicy` fields added to each entry. A separate per-parent table
was considered and rejected: the scheduler needs one true view of
total system load to ever do real balancing, and splitting job
visibility by parent would fragment exactly that.

**What "parent and child talk directly" actually turned out to mean**:
not a second wire format or a bypass of the kernal's placement -- a
child is dispatched exactly like any other `JOB`, and the generic `MSG`
chunking already documented above is all that's needed. What's real
about "direct" is narrower and already true of every worker: a child's
own completion is reported straight to the kernal (updating `jobs`),
and nothing about this requires the kernal to relay anything between
an already-placed parent and child beyond what the existing protocol
already does.

A child can become a parent itself -- the relationship is just a field
on a table entry, nothing stops it from recursing.

### Fan-out/depth cap on recursive spawning -- BUILT

With only 3 workers total, an unbounded spawner could starve everything
else. The answer landed on: **a job tree (the top-level job plus every
descendant it spawned, directly or through several levels) may not have
more than `#nodeOrder` jobs counted as "running" at once** -- "as many
nodes as there is," per the design decision this was built against.
Depth and fan-out collapse into one check this way, rather than needing
two separate limits: a grandchild spawning its own child counts against
the same tree total as a direct child would.

Mechanically: every job record gets a `rootId` field -- its own id for a
top-level job, inherited in O(1) from its parent's own `rootId`
otherwise (never a chain-walk, so this stays cheap no matter how deep a
tree gets). `countRunningInTree(rootId)` counts every job sharing that
`rootId` whose `status == "running"`; `handleSpawn` checks this against
`#nodeOrder` before dispatching a child (never for a top-level job --
only child spawns, where `msg.parent` is set, are capped) and replies
with a clear `ERROR` naming the cap and the current count if it's
already been reached. The parent itself counts toward its own tree's
total while it's still running (mid-spawn, waiting on its own children),
so with 3 nodes a parent can have at most 2 live children before the
3rd spawn attempt is rejected.

**The "what happens when every worker is busy" question turned out to
already have an answer, implicitly, in the existing design**: a worker
only ever runs one job at a time (`runJobCode` blocks that worker's own
main loop until the job finishes, is killed, or hits the instruction
budget), so round-robin dispatch to an already-busy worker just means
the new `JOB` message waits in that worker's own signal queue until
it's free -- not denied, not queued at the kernal, just delayed at the
target. This is true for a child exactly the same as for a top-level
job, including the edge case of a child landing (round-robin) on the
SAME node as its own still-running parent -- which surfaced a real,
separate bug while building this (see "A real bug this surfaced" below).
A real load-aware balancer (preferring the least-busy worker) is still
"not yet built" -- that's a quality-of-placement question, not the
correctness question this needed answered first.

**A real bug this surfaced**: `node/runtime.lua`'s `remoteRequest()`
(the nested wait `gmuxapi.*` calls use) used to silently discard any
fully-reassembled message that wasn't the specific reply it was
waiting for. Harmless as long as nothing but that reply could ever
arrive mid-wait -- which stopped being true the instant a child could
be placed on its own parent's node: the kernal's fresh `JOB` message
for the child would arrive at that node while it was still blocked
inside `remoteRequest`, waiting for its own unrelated `SPAWN` reply,
and got dropped on the floor -- the child's own `JOB` message simply
vanished, and it never started. Fixed by keeping anything that isn't
the awaited reply for the main loop. Verified via
`test/emu/integration_test.lua`'s test 12 (confirmed by reverting the
fix and watching a child land on its own parent's node and never
start). The first version of the fix pushed the raw frame back with
`computer.pushSignal`, which couldn't replay a multi-chunk message
(its earlier chunks were already consumed) and made the waiter re-pull
its own pushed-back signal in a tight loop until its reply arrived;
it now queues the already-reassembled message instead
(`pendingMessages`, drained by the main loop first). The match itself
was also too loose: the kernal's job ids and a worker's RPC ids are
independent counters, so a `JOB` for a child placed on this node could
carry the same id as the reply being waited for, match, and be
dropped. A reply now has to be a `RESULT`/`ERROR` from the kernal's
card.

A kill-policy child can also still be QUEUED on its node (behind
another job) when its parent finishes, so `runJobCode` never sees the
`KILL`. Workers now record every `KILL <id> <node>` addressed to them and refuse to
start a queued `JOB` with that id (test 17).

### Job environment abstraction

Partially answered by what's built: a dispatched job gets the real
global `jobId` (its own id), `yield`/`sleep`, and, through `gmuxapi`, a
way to ask for a child.

**Decided, not yet built -- process isolation for every program.** Both
legacy programs and `.mxe`s run as isolated processes in the sense that
matters for fault tolerance: a program crashing doesn't take down the
node or the system, and the kernal can pause or end it.

The difference is what each sees:

- A **legacy** program gets gmux-style virtual components (its own
  virtual gpu/screen/keyboard/modem -- see "The legacy layer").
- An **`.mxe`** gets no virtual components. It's a pseudo-emulated
  environment that makes kernel calls instead (the native OS APIs, plus
  any libraries it asked for at launch) and has open visibility of the
  system: it knows there are globals and is exposed to more of them
  than a legacy program, which only sees its OpenOS/gmux environment.
  Each process still has its own environment, so one program's globals
  never leak into another's. (Recorded wrongly at first as "the shared
  runtime globals every job gets today"; corrected.)
- **Parent/child processes are `.mxe`-only.** They're a new concept
  OpenOS programs never call, so legacy programs simply get the
  OpenOS/gmux environment -- there's nothing to implement for them
  there.

**BUILT for every job today (which all run as native processes):**

- A crashing job is contained: its error comes back as an `ERROR` and
  the worker keeps running (tests 6, 15).
- The kernal can pause, resume, or end any process (`pause`/`resume`/
  `kill <id>` at the REPL), and a process can do the same to its own
  descendants (`gmuxapi.pause_process`/`resume_process`/
  `kill_process`). Controls are raw broadcasts acted on at the
  process's yield points; a paused process keeps answering liveness
  probes, and a process still queued on its node is held or refused
  before it starts. Ended processes get status `"killed"` with the
  reason (user, parent, orphan policy, orphan timeout).
- Each process has its own environment: its globals never leak into
  another process on the same node. The native API it sees through it
  is read-only, and it has no `debug` and no raw `component` (test 27).

Not built yet: the legacy environment, which needs the launcher to tell
legacy from `.mxe`.

A kernal system bus (a dbus-like named-service/signal bus) is a
possible later addition for `.mxe` programs to talk to kernal services
and each other.

### App identity and orphan reclaim -- BUILT

An `.mxe` app's identity is its own declared **name** (`options.name`
on `create_headless_process`/`create_graphics_process`) -- not a raw
job id (those don't survive a relaunch) and not a separately-chosen
session id. The kernal keeps `appsByName`, a **global map: app name ->
the job id(s) spawned under it with `orphanPolicy == "orphan"`**. A new
message type, `GETORPHANS` (`gmuxapi.get_orphans(name)` on the worker
side), hands back the jobs registered under that name **whose parent is
no longer running** -- a child whose parent is alive stays with that
parent, so a second instance of the same app can't take it. Each comes
back as `{id, node, status, result, error}`: an orphan that already
finished is still returned, with its result, so the relaunched app can
see what happened while it was gone. Claimed jobs are **removed from the
pool** -- claimed once, not re-handed-out to a second caller. When an app with that name launches
again -- even much later, even if every internal id involved has
changed in between -- calling `get_orphans` with its own name gets its
old orphans back.

### Orphan policy: declared at spawn time, not a system-wide rule -- BUILT

What happens to a child whose parent died is **not** a single fixed
policy -- it depends on what that specific app calls for, declared via
`options.orphan_policy` at the moment it asks the kernal to create the
child (default: `"orphan"`). Applied by
`applyOrphanPolicyForChildrenOf`, called the instant the kernal records
a job as no longer running, for every child of that job:

- **`orphan`** -- the child keeps running untethered, registered in
  `appsByName` for reclaim (see above), and marks `job.orphanedAt =
  computer.uptime()` at the moment it's actually orphaned (when its
  parent finishes) -- not when it was originally spawned, which could
  have been long before. **Stale-orphan cleanup -- BUILT**:
  `sweepStaleOrphans()`, called once per tick alongside the existing
  `sweepStaleChunks()`, kills (same best-effort raw `KILL <id>`
  broadcast as the `kill` policy below, same cooperative-yield-point
  limitation) any `orphan`-policy job that's sat unreclaimed longer
  than `orphanTimeoutSeconds()` -- re-broadcasting at most once per
  `KILL_RETRY_INTERVAL` (10s) in case the first broadcast missed a job
  that wasn't at a yield point yet. **The timeout is dynamic, per the
  design decision it was built against ("dependent on scheduler
  stress")**: `orphanTimeoutSeconds() = BASE_ORPHAN_TIMEOUT / (1 +
  schedulerStress())`, where `BASE_ORPHAN_TIMEOUT = 300` and
  `schedulerStress() = (count of every job across the whole system
  with status "running") / #nodeOrder` -- a real backlog measure, not
  just "is anything happening," since it can exceed 1 when jobs are
  queued behind busy workers. An idle system gives an unreclaimed
  orphan the full 300s; as load climbs, that shrinks, freeing a slot
  sooner precisely when capacity is actually scarce. The exact curve
  (simple inverse) is a judgment call, not measured against real
  hardware or workloads.
- **`kill`** -- the kernal broadcasts a raw, unchunked `"KILL <id> <node>"`
  (same convention as boot's own `BOOT`/`CODE`, bypassing the generic
  `MSG` framing deliberately -- this needs to be checked cheaply at
  every signal a running job's cooperative loop sees, and a kill
  message is tiny enough to never need chunking anyway). **Best-effort
  only**: `node/runtime.lua`'s `runJobCode` only checks for a matching
  `KILL` at the job's own cooperative `yield()` points -- a child that
  never yields can't be killed early this way, no sooner than its own
  instruction-budget circuit breaker would catch it anyway (see "JOB
  code and the non-yielding timeout"). This is the same fundamental
  limit as that circuit breaker, not a gap specific to this feature.
- **`promote`** -- the kernal clears the child's `parent` field and
  removes it from `appsByName` (it's not seeking reclaim by name
  anymore -- it's just an ordinary top-level job from here on).
  **Only valid if the child is itself self-dependent** -- actually
  capable of talking to the kernal and operating on its own,
  protocol-wise, without assuming a parent is mediating for it.
  Promoting a child that was never meant to be a standalone process (a
  plain headless number-crunching job, say) would just be wasted
  cycles keeping something alive that has no way to usefully report
  its own results or respond to anything on its own -- `promote` is
  for children that were actually built to stand alone if needed, not
  a safe default for everything. (Nothing currently enforces
  "self-dependent" -- the kernal takes the declared policy at face
  value; this is a convention the app author has to actually honor.)

### Node death vs. planned draining -- two different things

**A worker node dying is unrecoverable, and that's fine.** Whatever was
running there is just gone -- no checkpointing, no job migration
attempt, no special recovery machinery, and critically, **not a kernal
panic**. The kernal marks whatever was running there as lost and keeps
going. This was a deliberate simplification, not an oversight: trying
to make arbitrary in-flight state survive an actual hardware failure is
a much bigger problem than this system needs to solve.

**Liveness -- BUILT, with no dedicated heartbeat.** Every verified
message from a known node refreshes it, and workers answer `PING` at
their jobs' yield points (`yield()`, `sleep()`, any `gmuxapi` wait), so
a node busy with a cooperating job still answers. The kernal only
watches nodes that have running jobs: once one has been silent for 3s
(counting from the later of its last message and its last dispatch) it
gets a `PING` probe, and after 10s with no reply it's marked down. Its
running jobs become `"lost"` (and their children's orphan policies
apply, as if the parent had finished); it's skipped by round-robin, by
`runall`, and in the fan-out cap and scheduler-stress counts, and a
fullscreen grant it held is released. An idle node that died is found
out the first time a job is sent to it and goes unacknowledged. Any
later message from it brings it back. Note the kernal does NOT receive
a node's yields as such -- the yield points are just where the node
answers probes, which gives the same signal without new traffic.
`spawn` to an unknown or down node is refused.

**Job history.** Running jobs are always kept. Only the last 100
finished jobs are kept, and a finished job keeps a 40-character
`codePreview` instead of its full source. `get_processes` returns
summaries (no source, no result); `get_process(id)` returns one job in
full.

Nodes rejoining (or new ones joining) the live pool is free:
`noteNode()` fires on any `HELLO`/`PONG` at any time, so a worker that
boots after the kernal's been running a while gets discovered live,
with no kernal restart needed.

**Planned draining -- BUILT** -- a different, deliberate action:
taking a node out of rotation on purpose (maintenance, say), as opposed
to it just dying. REPL `drain <node>` marks it draining: the balancer
and `liveNodeCount()` skip it, every migratable `.mxe` on it is moved to
another node (see below), and everything else finishes where it is.
`undrain <node>` puts it back. `nodes` shows `DRAINING`. Test 31.

### Migration -- BUILT for `.mxe`, through the `mux` library

The built-in `mux` library (granted to any `.mxe` that lists it in its
header's `libraries`, never fetched from disk):

- `mux.migratable(save)` -- opt in. `save` is called at a yield point
  when the kernal wants to move the process and returns a plain table
  (anything the serializer can send). Tells the kernal via `MIGRATABLE`.
- `mux.restored()` -- the table `save` returned, after a move; `nil` on
  a fresh start. The program is restarted from the top with it, so it
  picks up where it left off.

Flow: REPL `migrate <id> [node]` (or `drain`) broadcasts
`MIGRATE <id> <node>`. At its next yield point the worker calls `save`;
on success it ends the process and sends `MIGRATED` with the state, and
the kernal re-dispatches the same job id (code, args, program) to the
target with `restore`. On failure (never opted in, `save` errored,
state not serializable) it sends `MIGRATEFAILED` and the process keeps
running. A job still queued (never started) moves with no state. If the
chosen target went down meanwhile, the kernal picks another live node;
with none, the job is `lost`. Legacy programs are never migrated. Test 31.

The original design below is why it's opt-in rather than transparent.

### Transparent migration -- BLOCKED: no `eris` in the sandbox

The design was: **pause, serialize, ship, resume** -- pause the job,
`eris.persist` its suspended coroutine (call stack and locals) to bytes,
ship them to the target node, `eris.unpersist` and resume there, with
the job never knowing. The mechanism itself works (confirmed against
the real upstream `eris` library earlier, including a cross-process
round trip).

**Decided instead**: no migration for legacy programs. For an `.mxe`
it's an optional feature, through a `mux` library: an app that wants
to be movable hands over a state table and is restarted from it on the
new node; one that doesn't simply isn't migrated.

**Why not the original design: sandboxed code can't reach `eris`.** The mod opens the ERIS
library in the Lua state for its own use (saving machines when a world
saves), but `machine.lua`'s sandbox -- which EEPROM code, and so all of
muxos, runs in -- doesn't expose it. Confirmed by reading the mod's
`machine.lua` and by `test/hardware/verify.lua`, which reports it absent
in the emulated sandbox. So this can't be built as designed; the opt-in `mux` version
above replaces it.

### Compositor access for `.mxe`

An `.mxe` makes draw calls to the compositor directly -- no virtual GPU
-- and doesn't have to run on the kernal's node to do it. The
compositor's interface for this is built on a similar model to gmux's
virtual GPU, but with far less overhead, and without a gmux-style
virtual frame buffer per app.

An `.mxe` app gets a **window handle** from the compositor, not
compositor authority -- the same kind of restriction in kind as the
fullscreen grant today (see "The compositor" above): it can draw into
its own handle, but it doesn't get to touch anyone else's window or any
of the compositor's own bookkeeping (z-order, occlusion, dirty
tracking, flush timing all stay the compositor's).

**Persistent window handles -- BUILT.** A window belongs to the process
it was created for (`create_graphics_process`'s child) or, otherwise, to
the process that created it. That process -- or an ancestor of it --
redraws it whenever it wants with `gmuxapi.draw_window(id, options)`
(`DRAWWINDOW`): `code` (with `args`, visible to the code as `args`)
and/or a `pixels` bitmap, blanking the buffer first unless
`clear = false`. Redraw code runs in the same sandbox as creation (no
kernal globals, drawing-only `gpu`, no `pcall`, its own coroutine
under the machine's deadline).
Compiled draw code is cached per window keyed by its source, so an app
that redraws with the same code and new `args` doesn't recompile each
time. Any other process is refused (test 28).

### Window focus and keyboard delivery -- BUILT

**Focus**: `kernal/compositor.lua` keeps one focused window. A newly
created window takes focus, the same convention as it taking the top
z-order slot. There's no mouse/click gesture to move focus yet; the
`focus <window id>` REPL command does it manually, and Ctrl+Alt+C
focuses the console. `windows` shows the focused window and each
window's owning process (test 14).

**Delivery**: keyboard (`key_down`/`key_up`) and mouse-wheel input go to
the process that owns the focused window, as `EVENT` messages to its
node; the process reads them with `gmuxapi.pull_event(timeout)`, which
returns `{name, ...}` lists like `{"key_down", char, code}`. Events for
a process still queued on its node wait for it (up to 64). The console
gets the input instead in console mode, when it's focused, or when the
focused window's process has ended or its node is down; Ctrl+Alt+C
always reaches the kernal (test 28). This is the `.mxe` model -- the
kernal hands the process its input directly, no virtual keyboard
component.

**Still open**: what happens to a window (and focus) when its process
ends, and a keyboard gesture for moving focus between windows (today
only `focus` at the console and Ctrl+Alt+C).

### The console -- BUILT

The console's text lives in regular memory; it never has a video
buffer of its own. It has two sizes:

- **Normally** it's a compositor *text window* on the bottom layer. A
  text window holds rows of text instead of a gpu buffer, and the
  compositor paints the visible part of those rows straight into the
  frame buffer. Its size isn't fixed: it starts as the bottom half of the
  screen, and `console <width> <height> [x y]` resizes or moves it at
  any time (cheap -- there's no buffer to reallocate; output re-wraps to
  the new width).
- **In console mode** (hold Ctrl+Alt+C; `comp` or a press leaves it) it's the compositor's
  exclusive owner -- the same mode a fullscreen node uses -- and draws
  straight onto the real screen at full resolution.

So the frame buffer is the only full-screen buffer muxos allocates, and
the console allocates none (test 20 checks both). Output is kept as
logical lines -- the last 500 lines of output -- and wrapped only when
rendered, at whichever width the console
currently has, at most once per tick, which gives:

- **Scrollback**: PgUp/PgDn scroll a page; the mouse wheel scrolls 3
  rows. A `[scrolled N -- PgDn]` tag shows while scrolled back, a
  scrolled-back view stays put as new output arrives, and typing snaps
  back to the bottom.
- **Backspace across a wrapped input line**, since the line being typed
  is one logical line.
- **Input buffering**: keys typed while a command is still running are
  queued and replayed once it returns, instead of running a second
  command nested inside the first one's wait. (A different approach may
  replace this later.) Ctrl+Alt+C and scrolling are never queued.

The console gets keyboard input whenever no live process owns the
focused window (see "Window focus and keyboard delivery" above).

### Still open

Collected in one place:

- The exact shape of the "job environment abstraction" -- what's
  actually exposed to a dispatched `.mxe` app vs. a plain `JOB`, beyond
  the `jobId` global and `gmuxapi` every job already gets today.
- "promote"'s self-dependence requirement isn't enforced -- the kernal
  takes the declared policy at face value.
- **OPM's interface to the kernal** -- undecided (what OPM needs from
  the kernal beyond reading/writing the disk).
- The general `.mxe`-vs-legacy hardware access model: `.mxe` apps make
  direct kernel calls for every subsystem (the `gmuxapi` pattern
  already built for windows/gpu, generalized) and never see
  virtualized/emulated hardware components; legacy OpenOS/gmux-compat
  apps DO get emulated hardware for compatibility (e.g. a virtual
  modem component). Concrete examples given, not yet built: networking
  should give `.mxe` a lightweight kernal modem kernel module
  implementation plus eventual GERTi access, while legacy sees an
  emulated modem; keyboard input should be delivered directly to
  whichever `.mxe` job currently has focus, instead of via a virtual
  keyboard component. Window-focus tracking itself is now scaffolded
  (see "Window-focus tracking" above) -- what's still open is the
  networking side entirely (the modem kernel module, GERTi access) and
  the actual keyboard-delivery wiring on top of that scaffolding.

**Resolved while building the rest of this section**: "what the kernal
does when every worker is already busy" turned out to already have an
answer in the existing round-robin dispatch (see "Parent/child jobs"
above) -- not a new design decision, just a finding about what the
code already did.

**Fixed, ahead of the rest of this section being built**: the
`kernalAddr`-trust issue flagged above (`node/runtime.lua`'s main loop
used to do `kernalAddr = msg.from` on ANY valid incoming message, which
direct peer-to-peer messaging would have broken the moment two workers
exchanged a message). `node/bios.lua` now captures the address that
actually completed its `CODE` transfer and passes it into
`node/runtime.lua` as `kernalAddr = ...`; the main loop never
reassigns it afterward.

Worth recording honestly: an end-to-end integration-test scenario for
this (spoof a message as if from a peer, check a later `gpu`-face call
still reaches the real kernal) was written first and then REMOVED after
proving itself misleading -- deliberately reintroducing the old bug and
re-running that scenario, it still passed. The reason: in the CURRENT
protocol, every job dispatch is itself a legitimate kernal-origin
message that heals the corruption immediately before the vulnerable
`gpu`-face call ever runs, so there's no path through today's message
types that actually exploits it yet -- the risk is real but entirely
forward-looking, arriving the moment direct parent/child messaging
exists (a long-running cooperating job could receive a peer message
between `gmuxapi` calls with no intervening kernal message to heal it).
Replaced with a structural check instead: the real source has exactly
one assignment to `kernalAddr` (the boot-handoff capture), verified by
reading `node/runtime.lua`'s own text in `test/emu/integration_test.lua`
-- cheap, precise, and confirmed (by deliberately reintroducing the bug
a second time) to actually catch the regression that matters, unlike
the removed scenario.

## Measured vs. documented latency

The config numbers in OC's `application.conf` (`maxNetworkPacketSize`,
`maxSignalQueueSize`, a Switch's `defaultRelayDelay`/`defaultMaxQueueSize`)
are documented and confirmed. What is *not* confirmed from available docs
is whether a Rack's internal bus between its 4 Server slots applies that
same Switch-style relay delay, or is instantaneous. Rather than guess,
`muxos.lua`'s `ping <node> [count]` REPL command times real PING/PONG
round trips so this can be measured directly on actual hardware instead
of assumed from source.
