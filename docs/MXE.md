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
    `create_graphics_process{...}` (like the headless one, plus a
    window the child owns: in the child, `gpu` is a virtual gpu drawing
    into it, sized `width` x `height`, and keys typed into it reach the
    child's `pull_event`; returns `{process, window}`; test 48),
    `get_orphans(name)`,
    `launch(nameOrPath, args)`, `pause_process(id)`,
    `resume_process(id)`, `kill_process(id)` (own descendants only);
  - **windows:** `create_window{title, x, y, width, height, code |
    pixels, mode, bg | cells, args, resizable, title_bar}`,
    `draw_window(id, {code, args, pixels, cells, clear, bg})`,
    `get_windows()` (every window of the program's user, wherever it's
    shown: `{id, title, x, y, width, height, ownerJobId, user,
    attached, session, status}`). `pixels` are encoded into cells on
    the program's own node; `cells` are already-encoded cell runs
    (`{y, x, fg, bg, text, x, fg, bg, text, ...}` per row -- what the
    `bitmap` library makes). A window opens on the screen of the
    session the program was started from -- the kernal's own or a
    network terminal's -- and the program draws to that screen
    directly.
  - **persistence:** `set_persistent(true)` -- this application (the
    top of this process's tree, with every child) keeps running when
    its user logs out (or their terminal hangs up); `set_persistent(false)`
    undoes it, `is_persistent()` asks. The user can also toggle it on
    the window's title bar, or with `nohup`/`persist`. Its windows are
    *detached* (shown nowhere) meanwhile -- and new ones it opens
    meanwhile open detached -- and every session of that user lists
    them on its taskbar; touching one there brings the window to that
    screen. The program hears `{"window_detached", id}` and
    `{"window_attached", id, w, h}`; on attaching, its last
    `draw_window`s are replayed, so it comes back drawn (redraw
    whatever has changed since). Its `print` output while detached is
    kept (the last 4 KB) for `attach`. A non-persistent application is
    ended at logout (flag `logout_ends_jobs`); its children then go by
    their orphan policies. Tests 56, 58.
  - **render targets** -- several processes, on several nodes, drawing
    one window frame by frame (the pipework for a rendering library):
    - `share_window(window, child, {x, y, w, h})` -- the window's owner
      lets a descendant draw that rectangle (window cells); the child
      gets `{"window_shared", window, x, y, w, h}`.
      `unshare_window(window, child)` takes it back.
    - `render_config(window, options)` -- returns the window's settings,
      after setting any given (owner only): `mode` = `"split"` (each
      share draws its part of every frame; a frame shows when all have,
      or at the deadline, the missing parts as they were -- or blank,
      `stale = "clear"`), `"alternate"` (shares take turns drawing
      whole frames, shown in order; a frame that misses its deadline is
      dropped, never shown late) or `"tearing"` (no waiting: a frame
      shows as soon as the next one starts); `deadline` (seconds,
      0.25); `stale` (`"keep"`/`"clear"`); `queue` (frames in flight,
      2); `chunk` (bytes per message for a big region, 4096). Unknown
      settings and out-of-range values are refused.
    - `draw_region(window, frame, content)` -- this process's part of
      frame `frame` (1, 2, 3, ...): `{pixels, width, height, mode, bg}`
      (bit graphics) or `{text = rows}` (strings or `{text, fg, bg}`
      spans), at `content.x`/`y` (window cells; default the share's
      corner), clipped to the share. `content.done = false`: more of
      this frame is coming from this process.
    - Events: `{"frame_presented", window, frame, complete}` to the owner
      and every process drawing it; `{"region_lost", window, process}` to
      the owner when a sharing process ends.
  - **input:** `pull_event(timeout)` returns `{name, ...}`:
    `{"key_down", char, code}`, `{"key_up", ...}`,
    `{"touch"|"drag"|"drop", x, y, button}`, `{"scroll", x, y, dir}`,
    `{"window_resized", id, w, h}`, `{"clipboard", text}`;
  - **display:** `request_fullscreen()`, `release_fullscreen()` --
    the whole screen of the program's session: the kernal's own, or a
    network terminal's (its `gpu` calls then go to the terminal).
- `component`: every component in the cluster over the bus, with
  OpenOS's API (`list`, `proxy`, `invoke`, `type`, `methods`,
  `isAvailable`, `getPrimary`, `component.<type>`). Primary prefers the
  program's own node. Open visibility, minus the display, network cards
  and firmware (docs/PROTOCOL.md, "Cluster component bus"; test 36).
- `gpu`: drawing calls on its session's screen's GPU (the kernal's, or
  a terminal's). Refused unless the program holds the fullscreen grant;
  windows are the normal way to draw.

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
- `bitmap`: pixels into cells, on the program's own node (OC's GPUs
  have no pixels: a "pixel" is half a cell, `"halfblock"`, or a braille
  dot, `"braille"`). `pixels[row][col]` are colors (`0xRRGGBB`, or
  `nil` for `bg`):
  - `bitmap.cells(mode, pixels, width, height, bg)` returns `cells,
    cols, rows`: cell runs ready for `create_window{cells}`,
    `draw_window(id, {cells})` and `draw_region(id, frame, {cells})`.
  - `bitmap.encode(mode, pixels, width, height, bg)` returns `grid,
    cols, rows`, the cells themselves (`grid[row][col] = {char, fg,
    bg}`), to change before drawing; `bitmap.runs(grid, cols, rows)`
    makes them runs. Test 57.
- `http`, over whichever internet card the bus offers (this node's
  first):
  - `http.get(url[, headers[, timeout]])` returns `body, status,
    headers`, or nil, err;
  - `http.request(url[, data[, headers[, method]]])` returns a stream
    with `finishConnect()`, `response()`, `read([n])` (nil at the end)
    and `close()`. `data` may be a string or a table, which is
    form-encoded.

  The internet card can be on any node in the cluster (test 37).
- `modem`: a raw modem API, through the kernal's network card, so a
  program's address on the network is the kernal's card, wherever the
  program runs or moves to (test 45).
  - `modem.address`, `modem.maxPacketSize()`, `modem.isWireless()`;
  - `modem.open(port)`, `modem.close(port)`, `modem.isOpen(port)`;
  - `modem.send(address, port, ...)`, `modem.broadcast(port, ...)`;
    messages carry nil, booleans, numbers and strings.

  Messages on the program's open ports arrive through
  `gmuxapi.pull_event()` shaped like OpenComputers' signal:
  `{"modem_message", receiver, from, port, distance, ...}`. Port 4477 is
  the cluster's own and can't be opened. A program's ports close when it
  ends. Legacy programs get the same as an ordinary `modem` component
  (`component.modem`, `modem_message` through `event.pull`).
- `thread`: threads within one process. Each thread is scheduled by its
  node like a process of its own, so one that waits (`sleep`,
  `pull_event`, `readLine`, any `gmuxapi`/`fs` call) holds up only
  itself; the others and the main code keep running. Threads share the
  process's environment, windows, output and job id. Pausing or killing
  the process, or its main code ending, applies to all of them (test 42).
  - `t = thread.create(fn, ...)` starts `fn(...)`;
  - `ok, result = t:join([timeout])` waits for it (`nil, "timeout"` if
    it's still running then);
  - `t:status()` returns `"running"` or `"dead"`; `t:kill()` ends it;
  - `thread.yield()` lets the others run.

  An error in a thread nobody joins is printed to the console.

**Desktop icon (header fields).** `icon = {"row 1", "row 2", "row 3",
"row 4"}` (9 columns each, centered if shorter) and `icon_color =
0xRRGGBB` (or a list, one color per row) give the program its own icon
on the desktop. Any program, `.lua` included, can instead have a
`<name>.icon` file next to it: up to 4 rows of art, optionally after a
first line `#RRGGBB` (test 43).

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
