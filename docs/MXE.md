# The `.mxe` program format -- specification

Status: **draft, muxos 0.1.0**. Sections marked **BUILT** describe what
muxos does today (tests named). Sections marked **PROPOSED** are not
built: each is a decision to make, with a recommendation. Nothing
proposed should be relied on until it's marked built.

This is the contract for programs written for muxos itself. OpenOS
programs (`.lua`) don't need any of it: muxos runs them in an OpenOS
environment, gmux-style (see docs/PROTOCOL.md, "Running OpenOS
programs").

## 1. What an `.mxe` is -- BUILT

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
  compositor, the cluster component bus), with no virtual hardware in
  between.
- **Parent and child processes.** Only `.mxe` programs have them.

## 2. File layout -- BUILT

```lua
--[[mxe
muxos = "0.1.0"
libraries = {"mux", "mylib"}
]]
local mylib = require("mylib")
print("hello", ...)
```

The header must be the first thing in the file (leading whitespace
allowed). It's a long comment opening with `--[[mxe`. Its body is
evaluated as Lua assignments in an empty environment: it's data, not
code, and it can't call anything. A file without a header is an `.mxe`
with no requirements. A header that doesn't parse stops the launch with
an error.

Header fields:

| field | type | meaning |
|---|---|---|
| `muxos` | string | the muxos version the program was written for |
| `libraries` | list of strings | libraries it wants, beyond the native API (section 5) |

Unknown fields are ignored, so new fields can be added without breaking
old launchers.

## 3. Launching -- BUILT

A program is started by:
- typing its name at the console (looked up on `/bin` then `/usr/bin`,
  `.mxe` before `.lua`);
- typing a path;
- another process calling `gmuxapi.launch(nameOrPath, args)`. That
  process becomes its parent.

- **Arguments** are the rest of the console line, split on whitespace,
  passed as `...`, all strings.
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
| `versionMatch` | true if they're the same version (or none was requested) |
| `libraries` | name -> true (granted) or false (not found / failed to load) |
| `errors` | name -> error text, for libraries that failed to load |

**A version mismatch never stops a program from running.** The program
decides what to do about it (test 29).

## 4. The native API -- BUILT

Every `.mxe` sees these globals, read-only. Its own
globals are its own.

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
- `yield()`: let the node do other work (see "Cooperation").
  `sleep(seconds)` waits without losing events.
- `muxos.version`, and `computer.uptime()`, `computer.address()`.
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
  `isAvailable`, `getPrimary`, `component.<type>`). Open visibility, minus
  the display, network cards and firmware (docs/PROTOCOL.md, "Cluster
  component bus"; test 36).
- `gpu`: drawing calls on the kernal's GPU. Refused unless the program
  holds the fullscreen grant; windows are the normal way to draw.

**Cooperation.** A process runs until it yields. One that doesn't yield
for the machine's limit (5 s by default) is ended with an error. Its
node does nothing else meanwhile: no input, no answering the kernal.
Long loops should call `yield()`. Waiting (`sleep`, `pull_event`, any
`gmuxapi` or bus call) yields automatically.

**Ending.** Returning ends the process: the return value is its
`result` (`gmuxapi.get_process`), and it must be plain data. An error
ends it with status `error`. Its windows stay up, marked, until closed.
Its children follow their `orphan_policy` (`orphan`, `kill`,
`promote`).

## 5. Libraries -- BUILT

A name in `libraries` is looked up as `/lib/mxe/<name>.lua` on the
kernal's disk, or as a library built into the runtime. Granted libraries
are shipped with the program and loaded into its own environment before
it starts, so `require(name)` returns them. `require` of anything not
granted is an error.

- **A library file** is a chunk returning its value. It runs in the
  program's environment, so it sees the same native API.
- **Built-in libraries:**
  - `mux`: `mux.migratable(save)` and `mux.restored()` (section 6).

## 6. Migration -- BUILT, optional

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

## 7. PROPOSED -- what's missing

Each item below is a gap a real program (OPM first) will hit. The
recommendation comes first; it needs your decision.

### 7.1 Files

**Gap:** an `.mxe` has no file access at all. OPM installs files.

**Recommendation:** a native global `fs`, always present, over the OS
filesystem (the kernal's disk), using the `FS` requests legacy programs
already use:

- path functions: `fs.exists`, `fs.isDirectory`, `fs.size`,
  `fs.lastModified`, `fs.list(path)` (a sorted table), `fs.makeDirectory`,
  `fs.remove`, `fs.rename`, `fs.copy`;
- whole files: `fs.read(path)` and `fs.write(path, text)`;
- streams: `fs.open(path, mode)` for big files.

Paths are absolute. Native, not a library: files are an OS service, like
windows. Same reach as gmux apps (the whole disk), no sandbox per
program.

### 7.2 Console input

**Gap:** a foreground program receives keys only as raw `pull_event`
events; there's no line input.

**Recommendation:** a native `readLine([prompt])`. In the foreground at
the console it reads a line with echo, as the console does now for
legacy programs. Called from the background or a window, it returns nil
and an error.

### 7.3 Arguments and exit status

**Gap:** arguments are raw strings; the only exit status is
result/error.

**Recommendation:**
- Keep `...` as is.
- Add `mux.parseArgs(...)` -> `args, options`, the same rules as
  OpenOS's `shell.parse`: `-abc`, `--name`, `--name=value`, positional.
- Exit status stays result/error. `error()` with a message is a failure,
  and the console shows it.

### 7.4 Version compatibility

**Gap:** `versionMatch` is exact equality, which is too strict to be
useful.

**Recommendation:**
- Semantic versioning: `launch.compatible` is true when the major
  versions are equal and the running minor is at least the requested
  minor. Before 1.0, minor counts as major.
- `versionMatch` stays as is. Neither ever blocks a launch.

### 7.5 Where programs and libraries live

**Gap:** `.mxe` libraries are only looked for in `/lib/mxe`. OPM
installs to `/usr` by default.

**Recommendation:**
- Programs go on `/bin` (system) or `/usr/bin` (installed), as now.
- Libraries are searched in `/lib/mxe` then `/usr/lib/mxe`.
- A library may itself list `libraries` in a header, resolved
  transitively at launch.

### 7.6 HTTP

**Gap:** a program can use an internet card through `component` (any
node's, over the bus), but only through the raw request API.

**Recommendation:** a built-in library `http`:
- `http.get(url[, headers])` returns `body, status, headers`;
- `http.request(url, data, headers, method)` returns a streaming handle.

It's built on whichever internet card `component` finds, preferring one
on the program's own node. A built-in library, not native: few programs
need it, and it says so in the header.

### 7.7 Header fields for packages

**Gap:** OPM needs a program's identity.

**Recommendation:**
- Optional header fields `name`, `version`, `description` and `author`,
  shown in `launch` and in process listings.
- `requires = {"internet"}`, a list of component types: the launcher
  reports in `launch.components` which are present on the bus. It never
  blocks.

### 7.8 OPM as an `.mxe`

**Depends on 7.1-7.7.** OPM keeps its catalog format, oppm's
`programs.cfg`, and `opm_core` as is (it's pure logic). Its I/O moves to
`fs`, `http` and `readLine`. Installed `.mxe` programs and their
libraries land on `/usr/bin` and `/usr/lib/mxe`. `opm hook` goes away:
it's OpenOS shell tab completion, and the muxos console has none.
