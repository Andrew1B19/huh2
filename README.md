# muxos

A custom OS stack, built from the ground up, for an OpenComputers rack
running 4 Server blades on one shared component bus. It's a multi-core
system OS: the 3 worker nodes' custom firmware are its cores/threads, and
the kernal is the scheduler/front-end.

- **Kernal (1 node)** -- boots a normal OpenOS, is the bootstrap/scheduler
  and the only node you actually interact with. Runs `kernal/muxos.lua`.
  Eventually hosts a local GUI front end; draw calls from jobs running on
  worker nodes get forwarded to it to run against its real GPU.
- **Workers (3 nodes)** -- no OS, no disk, on purpose: `node/bios.lua` is
  flashed directly onto each one's EEPROM and *is* the entire firmware.
  Boot, open a Network Card, wait for jobs, run them, reply. Each one is a
  physically separate computer, so job isolation between them is free --
  no software sandboxing needed the way a single-process multiplexer
  requires.

See `docs/PROTOCOL.md` for the wire format between them.

`smux/` (vendored below) is **reference material, not a runtime
dependency** -- it's a real, OpenOS-standalone server-side multiplexer
(the "server version of gmux"), studied for its mechanisms (the
metatable-swap isolation trick in `patch.lua`, the job-console/session/
framing protocol for remote attach). muxos is its own implementation of
equivalent capability, built for a different substrate: physically
separate firmware nodes over a network, not coroutines multiplexed
inside one OpenOS process table. Nothing in `smux/` runs on a worker
node, and nothing here currently calls into it.

## Layout

```
kernal/muxos.lua    kernal program: discovery + round-robin job dispatch + REPL
node/bios.lua         worker firmware, meant to be flashed onto an EEPROM
docs/PROTOCOL.md      shared wire format (kept in sync by hand, see why in the file)
smux/                 reference only (see above): a real, standalone OpenOS multiplexer,
                       forked from gmux's backend. Not run on any node in this project.
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

Then boot that node with no filesystem attached -- it never looks for one.

## Running the kernal

Copy `kernal/muxos.lua` onto the kernal's filesystem and run it from
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

`LIST`/`INVOKE` are symmetric -- either side can ask the other to act on
its own components -- which is what lets a worker fall back to the
kernal's hardware when it has none locally. `node/bios.lua` exposes this
as a `gpu` face: `gpu.set(x, y, text)` etc. use a local `gpu` component
if one happens to be attached (zero network hops), and only call back to
the kernal, caching the discovered address, when the node has none. This
is the first slice of "run OpenOS-API-shaped code on a worker, as close
to native as makes sense, forwarding to the kernal only when something
genuinely isn't local" -- not full OpenOS-library compatibility yet, just
the dispatch pattern proven on one component type (`gpu`). See
docs/PROTOCOL.md for the one known gap (the kernal only services an
incoming request while something is actively polling, not while the REPL
is blocked at its prompt) and a real size problem (`node/bios.lua` is now
over the stock 4096-byte `eepromSize`, unresolved).

## Status

First working slice: discovery + synchronous round-robin job dispatch +
a symmetric remote-component bridge (kernal<->worker, used by workers to
reach kernal hardware they don't have locally, e.g. `gpu`) + latency
probing.
Not yet built: a real scheduler (load balancing beyond round-robin, async
futures/callbacks instead of blocking `submit()`), node health/failure
handling, a real multi-threading kernel API (the REPL-blocks-the-network
gap above needs this), broader OpenOS-library-shaped coverage beyond
`gpu`, multi-monitor support (explicitly deferred until the single-GPU
case works end to end), and anything workload-specific.
