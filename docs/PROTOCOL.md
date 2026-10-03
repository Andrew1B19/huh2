# Wire protocol

Both sides (`node/bios.lua` and `arbiter/rackos.lua`) talk over a Network
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

| type     | fields                                  | sent by  | meaning                                  |
|----------|------------------------------------------|----------|-------------------------------------------|
| `HELLO`  | `from`                                   | worker   | "I just booted, here's my address"       |
| `PING`   | `from`                                   | arbiter  | "who's out there"                        |
| `PONG`   | `from`, `to`                             | worker   | reply to `PING`                          |
| `JOB`    | `from`, `to`, `id`, `code`, `args`       | arbiter  | run `code` (a Lua chunk) with `args`     |
| `RESULT` | `from`, `to`, `id`, `result`             | worker   | `JOB` succeeded, here's the return value |
| `ERROR`  | `from`, `to`, `id`, `error`              | worker   | `JOB` failed to load or raised           |

`code` is compiled on the worker as `local args = ...` followed by your
code, then called as `chunk(args)` inside a `pcall`, so a job can refer to
`args` directly:

```lua
return args.x + args.y
```

`id` is chosen by the arbiter per job and echoed back so the arbiter can
match a `RESULT`/`ERROR` to the `submit()` call that's waiting on it.

## Assumptions this depends on

- All 4 nodes are Servers in the same Rack, each with its own Network
  Card. The rack's internal relay carries that traffic between blades
  with no extra cabling -- if that's not how your rack is wired (e.g.
  you're using Linked Cards instead, which are point-to-point and have no
  ports/broadcast), the networking code in both files needs to change.
- Worker nodes have no filesystem and no OS; `node/bios.lua` *is* the
  entire firmware, flashed straight onto the EEPROM.
- The arbiter boots a normal OpenOS and runs `rackos.lua` as a regular
  program.
