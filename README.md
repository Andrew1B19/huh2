# huh2

Experimental custom OS stack for an OpenComputers rack running 4 Server
blades on one shared component bus:

- **Arbiter (1 node)** -- boots a normal OpenOS, is the bootstrap/arbiter
  and the only node you actually interact with. Runs `arbiter/rackos.lua`.
- **Workers (3 nodes)** -- no OS, no disk. `node/bios.lua` is flashed
  directly onto each one's EEPROM and *is* the entire firmware: boot,
  open a Network Card, wait for jobs, run them, reply.

See `docs/PROTOCOL.md` for the wire format between them.

## Layout

```
arbiter/rackos.lua   arbiter program: discovery + round-robin job dispatch + REPL
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

Copy `arbiter/rackos.lua` onto the arbiter's filesystem and run it from
the OpenOS shell:

```
rackos.lua
```

It discovers workers automatically, then drops into a prompt:

```
rackos> discover
rackos> nodes
rackos> run return 1 + 1
rackos> runall return computer.address()
rackos> quit
```

## Status

First working slice: discovery + synchronous round-robin job dispatch.
Not yet built: a real scheduler (load balancing beyond round-robin, async
futures/callbacks instead of blocking `submit()`), node health/failure
handling, and anything workload-specific.
