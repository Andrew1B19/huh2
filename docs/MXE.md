# The `.mxe` program format -- specification

Status: **muxos 0.1.0, built**. Everything here is implemented and
tested (tests named; `test/emu/integration_test.lua`). OPM (`opm/`) is
the reference program written against it.

This is the contract for programs written for muxos itself. OpenOS
programs (`.lua`) don't need any of it: muxos runs them in an OpenOS
environment, gmux-style (see docs/PROTOCOL.md, "Running OpenOS
programs").

## 1. What an `.mxe` is

An `.mxe` is a Lua 5.3 source file with the `.mxe` extension. The
extension tells the launcher to run it as a native muxos program rather
than an OpenOS one. It isn't a security boundary: nothing is gated on it
(docs/PROTOCOL.md, "`.mxe`: a native-app marker").

Native means:

- **Its own process.** It has its own environment, it's crash-contained
  (an error ends the process, never the node or the OS), and the kernal
  can pause, resume, kill or move it.
- **Placed by the scheduler.** It runs on whichever worker the kernal
  picks. Code must not assume which node, or that it stays on one node
  (see "Migration").
- **The wider API.** It talks to the OS directly (`gmuxapi`, the
  compositor, the cluster component bus, the filesystem), with no
  virtual hardware in between.
- **Parent and child processes.** Only `.mxe` programs have them.

## 2. File layout

```lua
--[[mxe
muxos = "0.1.0"
name = "hello"
version = "1.0"
description = "says hello"
author = "me"
libraries = {"mux", "http", "mylib"}
requires = {"internet"}
]]
local mux = require("mux")
local args, options = mux.parseArgs(...)
print("hello", args[1])
```

The header must be the first thing in the file (leading whitespace
allowed). It's a long comment opening with `--[[mxe`. Its body is
evaluated as Lua assignments in an empty environment: it's data, not
code, and it can't call anything. A file without a header is an `.mxe`
with no requirements. A header that doesn't parse stops the launch with
an error.

Header fields (all optional):

| field | type | meaning |
|---|---|---|
| `muxos` | string | the muxos version the program was written for (section 3) |
| `libraries` | list of strings | libraries it wants beyond the native API (section 5) |
| `requires` | list of strings | component types it uses; reported, never enforced (section 3) |
| `name`, `version`, `description`, `author` | strings | its identity, for package managers and process listings |

Unknown fields are ignored, so new fields can be added without breaking
old launchers.

## 3. Launching

A program is started by:
- typing its name at the console (looked up on `/bin` then `/usr/bin`,
  `.mxe` before `.lua`);
- typing a path;
- another process calling `gmuxapi.launch(nameOrPath, args)`. That
  process becomes its parent.

- **Arguments** are the rest of the console line, split on whitespace,
  passed as `...`, all strings. `mux.parseArgs` parses them (section 5).
- **Foreground or background.** From the console the program runs in
  the foreground: the console waits until it ends and feeds it typed
  keys. A trailing `&` runs it in the background.
- **Placement** is always the scheduler's.

Before the program runs, the launcher puts its answer to the header in
the global `launch`:

| `launch.` | meaning |
|---|---|
| `muxos` | the running muxos version |
| `requested` | the program's `muxos` field (or nil) |
| `compatible` | the running version satisfies the requested one (below) |
| `versionMatch` | exactly the same version (or none requested) |
| `libraries` | name -> true (granted) or false (not found / failed to load), dependencies included |
| `errors` | name -> error text, for libraries that failed to load |
| `components` | for each type in `requires`: true if one is on the cluster bus right now |
| `name`, `version`, `description`, `author` | the header's own fields |

**Compatibility follows semantic versioning.** The major versions must
be equal, and within that major the running version must be at least the
requested one. Before 1.0, the minor version counts as the major, so
`0.1.x` is compatible with a request for `0.1.y` when `x >= y`, but not
with `0.2`.

**Nothing here ever stops a program from running:** not a version
mismatch, not a missing library, not a missing component. The program
decides (tests 29, 37).

The header's `name` and `version` show in process listings
(`gmuxapi.get_processes`/`get_process`, as `programName` and
`programVersion`).

## 4. The native API

Every `.mxe` sees these globals, read-only. Its own globals are its own.

- **Lua:** `assert error ipairs next pairs pcall rawequal rawget rawlen
  rawset select setmetatable getmetatable tonumber tostring type
  xpcall`, plus `string table math utf8 coroutine` (read-only).
  `load` defaults to the program's own environment.
- **Deliberately absent:** `debug` (it could remove the instruction
  limit), `io`, `os`, `require` beyond granted libraries, OpenOS's
  libraries, and the raw machine `component`.
- `jobId`: this process's id.
- `print(...)`: output to the kernal console, buffered and sent at yield
  points, before input, at exit, or past 1 KB.
- `readLine([prompt])`: one typed line, for the console's foreground
  program. It prints the prompt; the console echoes what's typed. Called
  from anything else (background, `run`, a child process), it returns
  nil and `"not in the foreground at the console"`.
- `yield()`: let the node do other work (see "Cooperation").
  `sleep(seconds)` waits without losing events.
- `muxos.version`, and `computer.uptime()`, `computer.address()`.
- `fs`: the OS filesystem, the kernal's disk (the same one legacy
  programs and gmux apps use). Paths are absolute.

  | call | returns |
  |---|---|
  | `fs.exists(p)`, `fs.isDirectory(p)` | boolean |
  | `fs.size(p)`, `fs.lastModified(p)` | number (0 if missing) |
  | `fs.list(dir)` | sorted table of names (directories end in `/`), or nil, err |
  | `fs.makeDirectory(p)`, `fs.remove(p)`, `fs.rename(from, to)` | true, or false/nil, err |
  | `fs.read(p)` | the whole file, or nil, err |
  | `fs.write(p, text)` | true, or nil, err; makes the directory if needed |
  | `fs.copy(from, to)` | true, or nil, err |
  | `fs.open(p, mode)` | a stream (`"r"`, `"w"`, `"a"`): `:read(...)` (`"l"`, `"L"`, `"n"`, `"a"`, or a byte count), `:lines()`, `:write(...)`, `:seek(whence, offset)`, `:flush()`, `:close()` |

  Streams are buffered: reads fetch 16 KB per network round trip, and
  writes go out past 4 KB or on flush/seek/close. Files a process leaves
  open are closed when it ends (test 37).
- `gmuxapi`, the gmux application API, muxos-shaped:
  - **processes:** `get_processes()`, `get_process(id)`,
    `create_headless_process{code, name, orphan_policy, args, node}`,
    `create_graphics_process{...}`, `get_orphans(name)`,
    `launch(nameOrPath, args)`, `pause_process(id)`,
    `resume_process(id)`, `kill_process(id)` (own descendants only);
  - **windows:** `create_window{title, x, y, width, height, code |
    pixels, mode, bg, args, resizable, title_bar}`,
    `draw_window(id, {code, args, pixels, clear, bg})`,
    `get_windows()`;
  - **input:** `pull_event(timeout)` returns `{name, ...}`:
    `{"key_down", char, code}`, `{"key_up", ...}`,
    `{"touch"|"drag"|"drop", x, y, button}`, `{"scroll", x, y, dir}`,
    `{"window_resized", id, w, h}`;
  - **display:** `request_fullscreen()`, `release_fullscreen()`.
- `component`: every component in the cluster over the bus, with
  OpenOS's API (`list`, `proxy`, `invoke`, `type`, `methods`,
  `isAvailable`, `getPrimary`, `component.<type>`). Primary prefers the
  program's own node. Open visibility, minus the display, network cards
  and firmware (docs/PROTOCOL.md, "Cluster component bus"; test 36).
- `gpu`: drawing calls on the kernal's GPU. Refused unless the program
  holds the fullscreen grant; windows are the normal way to draw.

**Cooperation.** A process runs until it yields. One that doesn't yield
for the machine's limit (5 s by default) is ended with an error. Its
node does nothing else meanwhile: no input, no answering the kernal.
Long loops should call `yield()`. Waiting (`sleep`, `pull_event`,
`readLine`, any `gmuxapi`, `fs` or bus call) yields automatically.

**Ending.** Returning ends the process: the return value is its
`result` (`gmuxapi.get_process`), and it must be plain data. An error
ends it with status `error`, and the console shows the message. There's
no other exit code: `error("...")` is failure. Its windows stay up,
marked, until closed. Its children follow their `orphan_policy`
(`orphan`, `kill`, `promote`).

## 5. Libraries

**Search.** A name in `libraries` is a library built into the runtime,
or a file `<name>.lua` in `/lib/mxe` (system) then `/usr/lib/mxe`
(installed, OPM's default), on the kernal's disk.

**Loading.** Granted libraries are shipped with the program and loaded
into its own environment before it starts, dependencies first, so
`require(name)` returns them. `require` of anything not granted is an
error.

**A library file** is a chunk returning its value. It runs in the
program's environment, so it sees the same native API. It may start with
its own `--[[mxe libraries = {...} ]]` header: those libraries are
granted too, transitively, and loaded before it (test 37).

**Built-in libraries:**

- `mux`:
  - `mux.parseArgs(...)` returns `args, options`, with OpenOS's
    `shell.parse` rules: `-abc` sets `a`, `b`, `c` to true;
    `--name` sets `name` to true; `--name=value` sets `name` to
    `"value"`; `--` ends options; `-` and everything else is
    positional.
  - `mux.migratable(save)`, `mux.restored()`: migration (section 6).
- `http`, over whichever internet card the bus offers (this node's
  first):
  - `http.get(url[, headers[, timeout]])` returns `body, status,
    headers`, or nil, err;
  - `http.request(url[, data[, headers[, method]]])` returns a stream
    with `finishConnect()`, `response()`, `read([n])` (nil at the end)
    and `close()`. `data` may be a string or a table, which is
    form-encoded.

  The internet card can be on any node in the cluster (test 37).

## 6. Migration (optional)

A program that wants to be movable between nodes:

```lua
local mux = require("mux")
local state = mux.restored() or {n = 0}
mux.migratable(function() return state end)
```

When the kernal moves it (`migrate <id>`, or `drain` on its node), the
save function is called at a yield point. The process ends there and
starts again from the top on the new node, where `mux.restored()`
returns the saved table. The state must be plain data. Without
`migratable`, a program is never moved (test 31).

## 7. Packages and OPM

Where things live:
- programs on `/bin` (shipped with muxos) or `/usr/bin` (installed);
- `.mxe` libraries in `/lib/mxe` or `/usr/lib/mxe`;
- OpenOS libraries for legacy programs in `/lib` or `/usr/lib`.

OPM (`/bin/opm.mxe`, see `opm/README.md`) installs oppm-format packages
from the LewisHost.Net catalog into `/usr` by default:

- `opm list`, `opm pull <package> [target]`;
- `opm update -a` or `opm update <package>`;
- `opm bundle <package> <dir>`, and `opm --from=<dir> ...` to install
  from a bundle offline;
- `opm update`, which reinstalls OPM from the catalog's `opm-mxe`
  package.

A package for muxos is an oppm entry whose files land in those places.
Its `.mxe` programs should fill in `name` and `version` (test 38).
