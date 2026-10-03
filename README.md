# muxos

Experimental custom OS stack for an OpenComputers rack running 4 Server
blades on one shared component bus:

- **Arbiter (1 node)** -- boots a normal OpenOS, is the bootstrap/arbiter
  and the only node you actually interact with. Runs `arbiter/muxos.lua`.
- **Workers (3 nodes)** -- no OS, no disk. `node/bios.lua` is flashed
  directly onto each one's EEPROM and *is* the entire firmware: boot,
  open a Network Card, wait for jobs, run them, reply.

See `docs/PROTOCOL.md` for the wire format between them.

Planned: muxos will stack with a fork of gmux/smux to become OpenOS
compatible and run multiple OpenOS programs concurrently as a
multitasking back-end, the same way gmux does. Not integrated yet --
that fork isn't in this repo.

## Layout

```
arbiter/muxos.lua    arbiter program: discovery + round-robin job dispatch + REPL
node/bios.lua         worker firmware, meant to be flashed onto an EEPROM
docs/PROTOCOL.md      shared wire format (kept in sync by hand, see why in the file)
```

## Flashing a worker

From an OpenOS shell that has an EEPROM component available (either the
worker's own, before you've wiped its default BIOS, or via an EEPROM
programmer):

```
eeprom node/bios.lua
```

Then boot that node with no filesystem attached -- it never looks for one.

## Running the arbiter

Copy `arbiter/muxos.lua` onto the arbiter's filesystem and run it from
the OpenOS shell:

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
muxos> components 1
muxos> call 1 <component addr> getResolution
muxos> quit
```

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

## Status

First working slice: discovery + synchronous round-robin job dispatch +
a remote-component bridge + latency probing.
Not yet built: a real scheduler (load balancing beyond round-robin, async
futures/callbacks instead of blocking `submit()`), node health/failure
handling, the gmux/smux multitasking back-end, and anything
workload-specific.
