# Wire protocol

There are two layers here, both over the same Network Card and port:

```
PORT = 4477
```

1. **Boot protocol** -- `node/bios.lua` (the actual EEPROM image) speaks
   this, and only this, before it has anything else loaded. Plain
   `WORD <payload>` text, no serializer: `BOOT <node address>` from a
   worker, `CODE <runtime source>` back from the kernal. See "Boot
   protocol" below.
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
   file of `muxos.lua`, cached after the first read) and broadcasts
   `CODE <that source>` once. Every worker still waiting on its own BOOT
   picks up this same reply, not just the one that asked -- they all
   need the identical payload, so one broadcast serves all of them.
3. Worker `load()`s the payload and calls it; `node/runtime.lua` becomes
   that node's actual runtime, with no further involvement from
   `bios.lua`.

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
| `RESULT`  | `from`, `to`, `id`, `result`                              | either  | success -- `JOB`'s return value, `LIST`'s address→type table, or `INVOKE`'s list of return values |
| `ERROR`   | `from`, `to`, `id`, `error`                               | either  | failure -- load error, runtime error, or invoke error |

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
thing actually bound by that limit, and at **2142 bytes** it has plenty
of room. `runtime.lua` (**7571 bytes**) carries everything that used to
make the combined file blow past 4096 -- it's fetched into RAM over the
modem instead, so `eepromSize` doesn't apply to it. It does still need to
fit in one `modem.broadcast` call under `maxNetworkPacketSize` (8192) --
currently ~92% of that budget. Growing much further means either raising
`maxNetworkPacketSize` or chunking `CODE` across multiple messages
(`maxNetworkPacketParts` allows up to 8) -- not needed yet, but close
enough to flag.

## Measured vs. documented latency

The config numbers in OC's `application.conf` (`maxNetworkPacketSize`,
`maxSignalQueueSize`, a Switch's `defaultRelayDelay`/`defaultMaxQueueSize`)
are documented and confirmed. What is *not* confirmed from available docs
is whether a Rack's internal bus between its 4 Server slots applies that
same Switch-style relay delay, or is instantaneous. Rather than guess,
`muxos.lua`'s `ping <node> [count]` REPL command times real PING/PONG
round trips so this can be measured directly on actual hardware instead
of assumed from source.
