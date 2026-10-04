# Wire protocol

Both sides (`node/bios.lua` and `kernal/muxos.lua`) talk over a Network
Card, broadcasting on a fixed port:

```
PORT = 4477
```

Every message is a Lua table, turned into text with a small serializer
(`[key]=value` pairs good enough for nil/boolean/number/string/table --
no functions, no userdata) and sent as the single string payload of
`modem.broadcast(PORT, text)`. The receiver reconstructs it with
`load("return " .. text)`.

This serializer is implemented twice, once per side, on purpose: EEPROM
firmware can't `require` another file, so there is no shared module to
import. If you change the wire format, change both copies.

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
(`kernal/muxos.lua`'s `handleList`/`handleInvoke` mirror `node/bios.lua`'s
handling exactly). This is what lets a worker fall back to the kernal's
hardware when it has none of its own: `node/bios.lua`'s `gpu` face
(`gpu.set(x, y, text)`, etc.) checks for a local `gpu` component first --
zero network hops if the node happens to have one -- and only sends a
`LIST`/`INVOKE` to the kernal, caching the discovered address, when it
doesn't. "Lowest overhead": local when local makes sense, one round trip
to the kernal otherwise, never more than that.

One real limitation of this symmetric design as built: the kernal only
services an incoming `LIST`/`INVOKE` request while something is actively
polling the modem (`discover`, `awaitReply`, `pingOnce`). While the REPL
is blocked on `io.read()` at the `muxos>` prompt, nothing pumps the modem
at all, so a worker's remote call can sit unanswered until the next REPL
command happens to trigger a poll. Fixing that for real needs the kernal
to service the network in the background while still reading the prompt
-- exactly what a "multi-threading kernel API" would need to provide
generally, not something patched in just for this.

## Assumptions this depends on

- All 4 nodes are Servers in the same Rack, each with its own Network
  Card. The rack's internal relay carries that traffic between blades
  with no extra cabling -- if that's not how your rack is wired (e.g.
  you're using Linked Cards instead, which are point-to-point and have no
  ports/broadcast), the networking code in both files needs to change.
- Worker nodes have no filesystem and no OS; `node/bios.lua` *is* the
  entire firmware, flashed straight onto the EEPROM.
- The kernal boots a normal OpenOS and runs `muxos.lua` as a regular
  program.

## node/bios.lua's EEPROM size

Stock `eepromSize` (the max bytes of code an EEPROM can hold, confirmed
from `application.conf`) is **4096**. As of the `gpu` face + remote-RPC
addition, `node/bios.lua` is 7230 bytes raw, and **4892 bytes even with
every comment and blank line stripped** -- over the limit either way.
This needs one of:

- Raise `eepromSize` in the server's OpenComputers config (e.g. to 8192).
- Trim `node/bios.lua` itself (the `gpu` face and remote-RPC plumbing are
  the biggest additions; cutting is possible but shrinks what a worker
  can do without the kernal).

Not resolved here -- flagging before anyone actually tries to flash this.

## Measured vs. documented latency

The config numbers in OC's `application.conf` (`maxNetworkPacketSize`,
`maxSignalQueueSize`, a Switch's `defaultRelayDelay`/`defaultMaxQueueSize`)
are documented and confirmed. What is *not* confirmed from available docs
is whether a Rack's internal bus between its 4 Server slots applies that
same Switch-style relay delay, or is instantaneous. Rather than guess,
`muxos.lua`'s `ping <node> [count]` REPL command times real PING/PONG
round trips so this can be measured directly on actual hardware instead
of assumed from source.
