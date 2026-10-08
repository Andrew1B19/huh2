# muxos

A custom OS stack, built from the ground up, for an OpenComputers rack
running 4 Server blades on one shared component bus. It's a multi-core
system OS: the 3 worker nodes' custom firmware are its cores/threads, and
the kernal is the scheduler/front-end.

- **Kernal (1 node)** -- `kernal/bios.lua` is its entire EEPROM image
  (mirroring the mod's own stock bios.lua, adapted to load `/muxos.lua`
  instead of OpenOS's `/init.lua`), and `kernal/muxos.lua` is its
  "init" -- not a program running under OpenOS, a REPLACEMENT for it.
  There is no OpenOS anywhere on the kernal: no `require`, no `io`,
  no `event`/`thread`/`keyboard` libraries. It runs in the mod's own
  `machine.lua` sandbox (see docs/PROTOCOL.md's "The real sandbox"),
  which provides `component`, `computer` (including
  `computer.pullSignal`) and the standard libraries, so `muxos.lua`
  builds the rest itself instead of assuming OpenOS is there to
  provide it -- the same bare-metal
  discipline `node/bios.lua`/`node/runtime.lua` always had to follow,
  just applied on the kernal too now, including its own minimal
  built-in text console (there is no `io`/`print`-to-screen without
  OpenOS either) and its own single-coroutine event loop (no
  `thread.create` -- there's no OpenOS thread library to fake
  concurrency with). It loads `kernal/compositor.lua` as a sibling file
  read directly off its own boot filesystem, not via `dofile`. The
  compositor is the ONLY file in this whole project that makes a real
  `gpu.*` call for window content -- "only the display node actually
  needs to make those budgeted calls for real" (every GPU method is a
  per-tick-budgeted call in OC's own source, see docs/PROTOCOL.md),
  enforced structurally rather than by convention, and it batches them:
  every window composites into a persistent frame buffer, with at most
  one real screen write per flush, called once per iteration of
  muxos.lua's own event loop. The kernal also holds `node/runtime.lua`
  on its own disk and serves it to workers at boot (see below) -- it's
  the authoritative source for what a worker runs.
- **Workers (3 nodes)** -- no OS, no disk, on purpose. `node/bios.lua` is
  the only thing flashed onto each one's EEPROM, and it's tiny: open a
  Network Card, ask the kernal for `node/runtime.lua`'s source, `load()`
  and run it. No local fallback -- if the kernal isn't up yet, it just
  keeps asking. `runtime.lua` is where job execution, the remote-component
  bridge, and the `gpu` face actually live; it arrives over the network
  fresh every boot instead of being baked into the EEPROM, so it isn't
  bound by the EEPROM's 4096-byte size limit the way the firmware is.
  Each worker is a physically separate computer, so job isolation between
  them is free -- no software sandboxing needed the way a single-process
  multiplexer requires.

See `docs/PROTOCOL.md` for the wire format, including the separate tiny
boot handshake `bios.lua` speaks before it has anything else loaded.

`smux/` and `gmux/` (both vendored below) are **reference material, not a
runtime dependency**. `smux/` is a real, OpenOS-standalone server-side
multiplexer (the "server version of gmux"), studied for its mechanisms
(the metatable-swap isolation trick in `patch.lua`, the job-console/
session/framing protocol for remote attach). `gmux/` (MIT, from
`aawwaaa/OpenPrograms`) is the real graphical multiplexer smux forked
its backend from -- vendored specifically for its **application-facing
API** (`gmux/lib/gmux/frontend/api.lua`, called by apps as
`component.gmuxapi.*`: `create_window`, `get_processes`, etc.), which
smux's backend-only fork never carried. muxos is its own implementation
of equivalent capability, built for a different substrate: physically
separate firmware nodes over a network, not coroutines multiplexed
inside one OpenOS process table. Neither runs on a worker node; nothing
here calls into their code directly -- `node/runtime.lua`'s `gmuxapi`
table is muxos's own implementation of (a growing subset of) gmux's API
shape, not gmux's code. See docs/PROTOCOL.md for what's translated so far
and what isn't yet.

## Layout

```
kernal/bios.lua       the kernal's own EEPROM image: mirrors the mod's stock bios.lua, loads
                       and runs /muxos.lua directly off the boot filesystem -- muxos REPLACES
                       OpenOS on the kernal, there's no OpenOS /init.lua in this picture.
kernal/muxos.lua      kernal "init": boot-serving + discovery + round-robin job dispatch +
                       job registry (jobs) + a minimal built-in REPL/text console, all built
                       on the sandbox's component/computer APIs, no OpenOS libraries.
kernal/compositor.lua  the only file that touches the real gpu for window content: window
                       registry, Z-order, occlusion culling, dirty tracking, a persistent
                       frame buffer, draw-code execution, blit-to-screen. Read off the boot
                       filesystem by muxos.lua's loadSibling(), not require()/dofile().
kernal/shell.lua       the console's POSIX-style shell: ls, cd, cat, cp, grep, ... with pipes,
                       redirection, variables and globs (see "The shell").
kernal/bitmap.lua      half-block/braille pixel-grid encoder for "bit windows" -- OC's gpu
                       hardware has no pixel API, so this is sub-cell encoding on top of the
                       same character grid. Loaded by compositor.lua via loadSibling().
installer/install.lua  the installer (bare from the kernal BIOS, or on OpenOS): installs the
                       kernal, flashes EEPROMs.
tools/build.lua        builds it, with everything it installs, into dist/ (see "Installing").
dist/muxos-installer.lua  the built installer program, and
dist/muxos-installer.dat  its data file (everything it installs); the two go together.
test/emu/install_test.lua runs that installer on emulated hardware and boots the result.
test/emu/openos_test.lua  runs it under real OpenOS (fetched on first run) and flashes an EEPROM.
kernal/lib/            OpenOS libraries for legacy programs (vendored unchanged, MIT),
                       installed as /lib on the kernal's disk; see kernal/lib/README.md.
node/bios.lua         worker EEPROM image: tiny network-boot stub, fetches node/runtime.lua
node/runtime.lua       worker's real runtime, served by the kernal (installed as its sibling,
                       NOT flashed anywhere) -- job execution, remote-component bridge, gpu
                       face, gmuxapi (muxos's own, gmux-API-shaped)
docs/MXE.md           the .mxe program format: the spec programs written for muxos target
opm/                  OPM, the package manager, ported to .mxe (ships with muxos)
docs/PROTOCOL.md      shared wire format: the boot handshake + the main message protocol +
                       the gmux API translation + the bare-metal kernal design
test/emu/              a 4-node (1 kernal + 3 workers) test environment, emulating this
                       project's own verified native primitives -- not the community OCEmu
                       (needs LÖVE2D, not installable headless here). Boots the REAL,
                       unmodified repo files and drives the kernal's REPL like a human would.
test/hardware/         verify.lua (+ its bios.lua loader) -- a suite for REAL OpenComputers
                       hardware confirming the sandbox behavior muxos depends on; it
                       also passes inside test/emu's emulated sandbox (test 30).
smux/                 reference only (see above): a real, standalone OpenOS multiplexer,
                       forked from gmux's backend. Not run on any node in this project.
gmux/                 reference only (see above): the real graphical multiplexer, vendored
                       for its application API shape. Not run on any node in this project.
```

All four kernal-side files (`bios.lua`, `muxos.lua`, `compositor.lua`,
`bitmap.lua`) plus `runtime.lua` need to sit together at the ROOT of the
kernal's boot filesystem (`/bios.lua` flashed to the EEPROM, the rest as
plain files) -- fixed, hardcoded root paths now, not resolved relative
to wherever the install happens to live the way a normal OpenOS install
could, since there's no real filesystem path to resolve a sibling
directory from any more (`muxos.lua` is loaded from a plain string under
a synthetic chunk name, not `@/muxos.lua`).

### smux's one external dependency

`smux/gertinet.lua` (its GERTi transport) requires `hmi/proto.lua`, a
shared wire codec from the monorepo smux was extracted from. `hmi` is
its own separate program, not a dependency of muxos -- `smux/` itself
is reference-only (see above), so this is just an inherited gap in the
reference material's own test suite, not something muxos needs to
resolve. `smux/test/test_gertinet.lua` fails on `require` as a result;
everything else (33 of smux's own tests: framing, session, job_console,
serve, the installer) passes standalone.

## Installing

### Hardware

- **Kernal:** one computer with a tier 3 GPU, a screen, a keyboard, a
  network card, a hard disk and a floppy drive (for the installer). It
  never needs OpenOS.
- **Workers:** three computers, each with a network card and an EEPROM.
  No disk is needed.
- **Network:** all four computers on the same network (cables or
  wireless) so their network cards can reach each other.

### How it fits together

The installer floppy boots by itself. It has an `/init.lua`, which is
what the stock Lua BIOS (the EEPROM every computer comes with) boots. So
an empty computer with its stock EEPROM and the floppy in starts
straight into the installer, with no OpenOS. Installing muxos flashes
the muxos kernal BIOS over the stock one.

The kernal BIOS boots, in order:

1. the disk it remembers;
2. any disk with `/muxos.lua` (an installed muxos);
3. any disk with `/muxos-installer.lua` at its root (the installer
   floppy, for reinstalling or flashing workers).

Once muxos is installed it boots first, so the floppy can stay in.

The installer also runs as an ordinary program on OpenOS, with the same
menu.

### 1. Make the installer floppy

The installer is three files, and all go at the root of the floppy:

- `init.lua`, which boots it (under 1 KB);
- `muxos-installer.lua`, the program (about 26 KB);
- `muxos-installer.dat`, everything it installs (about 290 KB).

Only ever put them on a floppy: an `/init.lua` on a computer's own disk
would replace what boots it.

Together they need about 320 KB of the floppy's 512 KB, so start from an
empty floppy: an older copy of the installer left on it (the old
single-file one was 314 KB) leaves no room, and the data file is cut
short.

The sure way, on an OpenOS computer with a floppy in one of its drives:

```
opm pull muxos-installer /home/muxos
/home/muxos/muxos-installer.lua floppy
```

`floppy` mode lists every disk with its `/mnt` path, label and size,
marks the floppies, and never offers the computer's own OpenOS disk.
Pick the floppy and it writes all three files there and reads them
back. (On OpenOS every disk has a `/mnt/xxx` name, the computer's own
hard disk included, so pulling straight to `/mnt/xxx` can land on the
wrong disk; the installer warns when it finds itself on the computer's
own disk.)

Other ways, if you'd rather put the files there yourself:

- **With opm:** `opm pull muxos-installer <floppy>`, when you're sure
  which `/mnt` name is the floppy (`df` shows each disk's size; a floppy
  is 512 KB). The catalog entries are in `dist/programs.cfg`: copy this
  repository into oc-programs as `muxos/` and merge them in.
- **With an internet card:** `wget` `dist/floppy/init.lua`,
  `dist/muxos-installer.lua` and `dist/muxos-installer.dat` from the
  repository's raw URLs onto a floppy's root.
- **By copying:** put those three files at the root of the floppy's
  folder in your world save,
  `saves/<world>/opencomputers/<disk address>/`.

The program is kept small on purpose: a floppy is OpenComputers' slowest
disk, and the installer starts in a second or two instead of loading
300 KB first. It reads the data file only as it needs it (flashing
EEPROMs reads just the first few KB).

### 2. Install the kernal

Put the installer floppy in the kernal computer (in its floppy slot or a
disk drive next to it) and turn it on. Its stock EEPROM boots the
floppy and the installer starts; choose **1) install the kernal**. It:

- lists the writable disks and asks which one to use (the installer's
  own disk isn't offered);
- checks the space and warns about missing hardware (tier 3 GPU, screen,
  network card);
- writes muxos and the OpenOS libraries for legacy programs. Each file
  goes in as `<name>.new` and they're all swapped in at the end, so a
  disk that fills up mid-install changes nothing;
- flashes the muxos kernal BIOS onto this computer's EEPROM, pointed at
  that disk.

Reboot and muxos starts.

### Updating

Put the new installer files on the floppy (all three, as in step 1),
put it in a drive the kernal can see, and at the muxos console type:

```
muxos> update
muxos> reboot
```

`update` reads `muxos-installer.dat` from the floppy (a floppy is slow:
about 10 seconds), checks it against its own manifest, and installs its
files onto the kernal's disk -- each written as `<name>.new` and only
swapped in once all are written, so a damaged file or a full disk
changes nothing. It re-flashes the kernal's EEPROM too if the kernal
BIOS changed, keeping its boot address, and keeps your own files.
After `reboot`, restart the workers so they fetch the new runtime. A
worker BIOS change (rare) still needs the installer's **2) flash worker
EEPROMs**.

(From OpenOS, `muxos-installer.lua kernal` with the kernal's disk in
that computer also upgrades in place.)

### 3. Flash the worker EEPROMs

From the installer's menu, **2) flash worker EEPROMs**, on any computer
that boots the floppy with its stock EEPROM, or on OpenOS:

```
/mnt/<floppy>/muxos-installer.lua worker   the three worker EEPROMs
/mnt/<floppy>/muxos-installer.lua bios     kernal BIOS EEPROMs (optional)
```

Each mode flashes the EEPROM in that computer, then asks you to swap in
the next one: take the EEPROM out, put the next one in, and press Enter.
Type `q` when done. `--count=<n>` stops after n. Put this computer's own
EEPROM back afterwards. Workers boot from the network as soon as they're
powered on, in any order.

OpenOS options: `--disk=<address prefix or label>`, `--yes` (no
questions), `--count=<n>`, `--reboot`.

The build (`lua5.3 tools/build.lua`) checks everything compiles, that
both BIOS images fit an EEPROM (4096 bytes), and that the kernal and
worker versions and wire code match. `lua5.3 test/emu/install_test.lua`
runs the built installer against emulated hardware, including booting
an empty computer from the installer floppy, and boots the result.
`lua5.3 test/emu/openos_test.lua` does it with OpenComputers' own stock
BIOS and real OpenOS (fetched on first run).

### Troubleshooting

Workers have no screen, so a worker can only tell you things by beeping.
A worker that's working is **silent**: it waits for the kernal, asking
every 5 seconds.

| Sound / light | Meaning |
|---|---|
| Worker: one low, long beep, then nothing | Its BIOS ran, but it has no network card. |
| Worker: one short high beep | It got the runtime from the kernal, but couldn't load it. |
| **Two beeps and a flashing red light** (any computer) | OpenComputers itself: the machine crashed. Shift-right-click the case with an **Analyzer** to read the error. |
| Kernal: one short high beep | Normal: muxos is starting. |
| Kernal: one short medium beep | Normal: no muxos installed, so it's starting the installer floppy. |
| Kernal: **two beeps, flashing red**, and the screen says "Nothing to boot" | The muxos kernal BIOS found nothing to boot. Under that line it lists every disk the computer can see, its label, and its files. It waits 5 seconds first, for a drive that attaches just after power-on. To find the floppy in the list, match addresses: on OpenOS the floppy is mounted at `/mnt/` plus the first three characters of its address (`/mnt/800` is a disk whose address starts with `800`). If the floppy isn't listed, the computer can't see it: a case needs a floppy slot (tier 3) or a Disk Drive block next to it; a rack server needs the rack's disk drive connected to it. If it's listed without `muxos-installer.lua`, the files aren't on it. |
| Installer: "error: ..." and "Press Enter to restart." | The installer crashed; it shows the error with its traceback, and where it wrote its dump. |

Both write a dump to `/muxos-boot-dump.txt`: the kernal BIOS when it
finds nothing to boot, and the installer when it crashes. It goes on the
installer floppy (or, failing that, any writable disk) and holds the
error (with its traceback, for a crash), memory, energy, every component
the computer sees, and each disk's label, size and root listing. Read it
on an OpenOS computer (`cat /mnt/<floppy>/muxos-boot-dump.txt`) or from
the floppy's folder in the world save, and include it when reporting a
problem.

Errors the Analyzer can show:

- **"no bios found; install a configured EEPROM"**: that computer's
  EEPROM is empty (or missing). It was never flashed. Run the installer's
  **check** mode (`muxos-installer.lua check`, or menu option 4) with
  the EEPROM in an OpenOS computer. It says whether the EEPROM is blank,
  holds this version's muxos worker or kernal BIOS, or holds something
  else. Re-flash it with `worker` or `bios`. When flashing, just pressing
  Enter means yes. The installer re-reads every EEPROM it writes and only
  says "Flashed" if every byte matches.
- **"can't find muxos-installer.dat ... Looked at: ..."** (on screen,
  from the installer): the installer looks next to itself, then at the
  root of every disk, and lists each place with why it didn't do: "not
  there", a file that isn't a muxos data file, or one from another
  version, or one that's cut short (with its size, the size it should
  be, and the disk's free space). Put both files from the same build at
  the root of a floppy with room for them. A copy that runs out of space
  can still look like it worked, so check with `ls -l /mnt/<floppy>` and
  `df /mnt/<floppy>`.
- **"failed loading bios: ..."**: the EEPROM holds code that doesn't
  compile; re-flash it.
- **"not enough memory"**: add RAM (two tier 3 sticks is comfortable for
  a worker, which compiles a roughly 90 KB runtime when it boots).

### Installing by hand

- Flash `node/bios.lua` onto each worker's EEPROM and `kernal/bios.lua`
  onto the kernal's (`flash -q <file>` in OpenOS).
- Copy `kernal/muxos.lua`, `kernal/compositor.lua`, `kernal/bitmap.lua`
  and `node/runtime.lua` to the root of the kernal's disk, and
  `kernal/lib` to `/lib`.

The kernal BIOS boots the first disk with `/muxos.lua` on it. Workers
never need a disk: they fetch `runtime.lua` from the kernal at boot.

It discovers workers automatically, then drops into a prompt:

```
muxos> discover
muxos> nodes
muxos> ping 1
muxos> ping 1 10
muxos> run return 1 + 1
muxos> runall return computer.address()
muxos> processes
muxos> spawn 1 return 42
muxos> window hello 5 5 20 5 gpu.set(1,1,"hi from the kernal")
muxos> windows
muxos> comp                   (back to the desktop from console mode)
muxos> console 80 20
muxos> hello world            (runs /bin/hello.mxe or /bin/hello.lua)
muxos> hello world &          (in the background)
muxos> pause 12 / resume 12 / kill 12
muxos> bitdemo halfblock 5 5
muxos> bitdemo braille 30 5
muxos> components 1
muxos> call 1 <component addr> getResolution
muxos> quit
```

`processes` shows the kernal's own job registry (`jobs`) -- every job
ever dispatched via `run`/`runall`/`spawn`, with its status, node, and
result or error. This is also what answers a worker's
`gmuxapi.get_processes()` call (see below): the kernal is the only
place that actually knows about every job across every node, so it's
the real implementation, not a per-worker guess.

`spawn <node> <lua code>` dispatches a job and returns immediately with
its id, without waiting for it to finish (unlike `run`) -- the REPL
exposes this mainly to exercise the same fire-and-forget path a
worker's `gmuxapi.create_headless_process()` uses. `window <title> <x>
<y> <width> <height> <lua code>` allocates a GPU buffer, runs the code
against it (with `gpu` bound to the buffer), and marks it dirty; the
actual real screen write happens in the background dispatcher's next
`compositor.flush()` (at most once per tick), not immediately when you
run the command. `windows` lists what's been created. Overlapping
windows are handled correctly -- occlusion culling means a window
covered by another doesn't get needlessly re-composited, and a
partially-covered one blits only its actually-visible fragments. See
docs/PROTOCOL.md's "The compositor" section for the mechanism, adapted
from gmux's real `graphics.lua`.

`bitdemo <halfblock|braille> <x> <y>` draws a small test pattern as a
**bit window** -- OC's GPU hardware has no pixel API at all (confirmed
from source: every draw method operates on a character+color cell,
never a raw pixel), so `kernal/bitmap.lua` encodes a pixel grid into
half-block (`▀`, two real colors per cell, 1x2 sub-pixels -- good for
multi-color content like a wallpaper or gradient) or braille (`⠿`, one
effective color per cell but 4x the sub-pixel density, 2x4 per cell --
good for a toolbar and small icons, which are almost always monochrome
silhouettes anyway, so the density matters more than the color limit)
character runs instead. `createWindow`'s `options.pixels`/
`mode`/`bg` go through the exact same registry, Z-order, occlusion, and
frame-buffer pipeline as a character-mode window -- `bitdemo` is just
the REPL's way to see it work without typing a pixel grid by hand.

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
kernal's hardware when it has none locally. `node/runtime.lua` exposes
this as a `gpu` face: `gpu.set(x, y, text)` etc. use a local `gpu`
component if one happens to be attached (zero network hops), and only
call back to the kernal, caching the discovered address, when the node
has none. This is the first slice of "run OpenOS-API-shaped code on a
worker, as close to native as makes sense, forwarding to the kernal only
when something genuinely isn't local" -- not full OpenOS-library
compatibility yet, just the dispatch pattern proven on one component
type (`gpu`). The old gap here (the kernal only serviced an incoming
request while something was actively polling, not while the REPL was
blocked at its prompt) is resolved now by routing every wait -- the
REPL idling at its prompt included -- through the same `tick()`
primitive, since muxos is bare-metal and there's no OpenOS thread
library to run a separate background poller on any more; see
docs/PROTOCOL.md for the full design.

**One exception to that symmetry**: `INVOKE` targeting the kernal's real
gpu or its bound screen is blocked -- those are the compositor's, and
going around it defeats the point of having one. Calling `gpu.set(...)`
etc. from a worker without a grant now fails with "direct gpu/screen
access is blocked" instead of quietly drawing on the kernal's live
screen; use `gmuxapi.create_window()` for ordinary output.
`gmuxapi.request_fullscreen()`/`release_fullscreen()` are the one way
through, for a fullscreen app that genuinely wants to own the display
directly -- first-come-first-served, one holder at a time, NOT released
automatically if its holder disappears. See docs/PROTOCOL.md's
"The compositor" section.

`node/runtime.lua`'s `gmuxapi` table is muxos's translation of gmux's
actual *application* API (`component.gmuxapi.*` in gmux itself -- see
`gmux/lib/gmux/frontend/api.lua`) for a networked substrate rather than
gmux's one-process-table assumption. All five pieces built so far are
remote calls, never local-first like `gpu`, since no worker could ever
answer any of them from its own state alone:

- `get_processes()` -- the kernal's job registry, as before.
- `create_headless_process(options)` / `create_graphics_process(options)`
  -- dispatch a new job (`options.code`, a Lua source string, replacing
  gmux's `options.main`/`main_path` -- a function or file path can't
  cross the network). Fire-and-forget, like gmux's own versions: you get
  `{process = {id, node}}` back immediately, not the result.
  `create_graphics_process` also creates a window sized to
  `options.width`/`height`, but does **not** wire the job's own `gpu`
  face to that window's buffer yet -- flagged in docs/PROTOCOL.md, not
  silently assumed to work.
- `create_window(options)` -- also stands in for gmux's separate
  `create_window_buffer`: `options.code` (run ON the kernal, drawing
  into the allocated buffer) replaces gmux's `func(gpu)` callback, since
  a function value can't cross the network either.
- `get_windows()` -- the kernal's window registry (`kernal/compositor.lua`).
- `request_fullscreen()` / `release_fullscreen()` -- not part of gmux's
  real API (it never needs this; its apps already share the host
  process's real gpu/screen directly). Added because direct gpu/screen
  `INVOKE` is blocked by default now -- this is how a node gets let
  through, for a fullscreen app that wants to bypass the compositor's
  buffer/blit indirection on purpose.

Windows carry gmux's decorations (copied from
`gmux/lib/gmux/frontend/windows.lua`): a title bar with the process
status prefix, minimize, maximize (resizable windows) and close (which
kills the process, as in gmux), title-drag to move, and corner-drag to
resize. Touch focuses and raises a window, and pointer input reaches its
owner process. See docs/PROTOCOL.md for what's NOT translated: `get_backend`/`get_graphics`/`get_process`/`show_error` don't exist
here at all.

## Status

First working slice: network-boot handshake (tiny EEPROM stub + a
kernal-served runtime, chunked since the runtime now exceeds one modem
message's size budget) + discovery + synchronous round-robin job
dispatch with a kernal-side job registry (shared by `submit()` and the
fire-and-forget `SPAWN` path, completion recorded generically either
way) + a symmetric remote-component bridge (kernal<->worker, used by
workers to reach kernal hardware they don't have locally, e.g. `gpu`),
gated so direct gpu/screen access requires an exclusive fullscreen grant
(Ctrl+Alt+C: a press exits fullscreen, force-releasing a grant whose
holder disappeared; holding it drops into the full-screen kernal
console until `comp`) + a compositor module (`kernal/compositor.lua`)
that's the sole real gpu-touching code in the project for window
content, with Z-order, occlusion culling, dirty tracking, and a
persistent frame buffer flipped to the real screen with one `bitblt`
per flush (of just the changed area), adapted from gmux's real `graphics.lua` + a single-coroutine
event loop (`tick()`) that every wait in the program funnels through,
replacing OpenOS's thread library entirely now that the kernal is
bare-metal + every message over the modem generically chunked (not
just boot's `CODE`), with stale-partial sweeping on both sides + five
translated pieces of gmux's application API (`get_processes`,
`create_headless_process`, `create_graphics_process`, `create_window`,
`get_windows`) plus the fullscreen-grant pair + latency probing +
"bit window" support (`kernal/bitmap.lua`: half-block and braille
pixel-grid encoders, both verified dot-by-dot and run-length-batched
into the fewest `gpu.set` calls possible, slotted into the same
window/compositor pipeline as character-mode windows) + the kernal
itself now fully bare-metal (`kernal/bios.lua` + a `muxos.lua` built
entirely on native primitives, with its own minimal text console and
keyboard-modifier tracking replacing OpenOS's io/keyboard libraries) +
protection against OC's real non-yielding timeout for dispatched `JOB`
code (a voluntary `yield()` a job can call to cooperate, `sleep(seconds)`
to wait without swallowing other traffic, and each job in its own
coroutine so the machine's own "too long without yielding" deadline ends
a runaway job without taking the worker down) + a 4-node test
environment (`test/emu/`) that boots every node through the mod's own
`machine.lua` sandbox (vendored in `test/emu/oc/`) and runs the real,
unmodified files end to end, and
drives the kernal's REPL like a human would, which caught two genuine
bugs no isolated unit mock could have (a compositor `flush()` that
wiped the console's own output, and a job-preemption design that could
hang a job calling `gmuxapi.*` forever -- see docs/PROTOCOL.md's
"Hardening found by actually running the real files together").
Not yet built: a real scheduler (load balancing beyond round-robin, async
futures/callbacks for `submit()` itself, not just `SPAWN`), more of the OpenOS userland for legacy
programs, e.g. `buffer` and `shell` (see docs/PROTOCOL.md's OpenOS-compatibility
section for the intended shape), per-job isolated drawing surfaces (so
`create_graphics_process`'s job and its window are actually wired
together -- true for bit windows too now), an actual toolbar/icons/
wallpaper built with the bit-window encoder (the encoder works, nothing
composites a desktop with it yet), the REPL's own line editor (append/backspace only -- no
history, no cursor movement within a line), multi-monitor support
(explicitly deferred until the single-GPU case works end to end), and
anything workload-specific.

**The `.mxe` process model, partially built**: parent/child jobs are
real now -- `gmuxapi.create_headless_process`/`create_graphics_process`
take `options.name`/`options.orphan_policy`, a job knows its own id via
the real global `jobId`, the kernal's single global job table carries
`parent`/`appName`/`orphanPolicy` on every entry (placement authority
stays exactly where it was -- round-robin, unchanged), and
`orphan`/`kill`/`promote` are all applied for real the moment a
parent's job finishes (`kill` is best-effort, only reachable at a
child's own cooperative yield points). App identity and orphan reclaim are real
too: `gmuxapi.get_orphans(name)` hands back a relaunched app's old
orphans, claimed once. Building this surfaced and fixed a real bug in
`remoteRequest()` that silently dropped a child's own `JOB` dispatch
when it landed on its own parent's node -- see docs/PROTOCOL.md.
Verified end to end in `test/emu/integration_test.lua` (test 12).

A fan-out/depth cap is real too: a job tree (a top-level job plus every
descendant it spawned, at any depth) can't have more than `#nodeOrder`
jobs "running" at once -- as many as there are worker nodes. And an
`orphan`-policy job that's never reclaimed doesn't just run forever
unbounded any more: its cleanup timeout shrinks dynamically as
scheduler load rises (`BASE_ORPHAN_TIMEOUT / (1 + schedulerStress())`),
freeing its slot sooner precisely when capacity is actually scarce.
Both verified end to end in `test/emu/integration_test.lua` (test 13
for the fan-out cap; the dynamic-timeout formula itself is also
cross-checked in isolation, since its 300s base timeout makes a true
end-to-end test of the sweep impractical).

Window-focus tracking is scaffolded now too: `CREATEWINDOW` carries an
optional `ownerJobId` (`create_graphics_process` sets it to the
spawned child's own id), and `kernal/compositor.lua` tracks which
window is focused (a new window takes focus automatically, same as it
taking the top z-order slot) with `M.getFocus()`/`M.setFocus(id)` and a
manual `focus <window id>` REPL command; touching a window focuses it
too. Keys, wheel and touch input go to the focused window's process
(see docs/PROTOCOL.md's "Window focus and keyboard delivery" and
"Window decorations"). Verified in `test/emu/integration_test.lua`
(tests 14, 28, 32).

### The shell

The console is a POSIX-style shell (`kernal/shell.lua`), to a
reasonable degree of `sh`. The prompt shows the working directory
(`muxos:/home> `; home is `/home`).

- **Syntax:** `'...'` and `"..."` quoting and `\` escapes; `$VAR`,
  `${VAR}`, `$?`, `VAR=value`, `export`, `unset`; `~`; globs (`*`, `?`,
  `[...]`) in any path component; `#` comments; pipes `|`; redirection
  `>`, `>>`, `<`, `2>`, `2>>`, `2>&1` (and `/dev/null`); lists `;`, `&&`,
  `||`; and `&` to run a program in the background.
- **Built in, busybox-style:** `ls [-a -l -1]`, `cd`, `pwd`, `cat`, `echo
  [-n]`, `printf`, `mkdir [-p]`, `rmdir`, `rm [-r -f]`, `cp [-r]`, `mv`,
  `touch`, `head`/`tail [-n N]`, `wc [-l -w -c]`, `grep [-i -v -n -c -F]`,
  `sort [-r -n -u]`, `uniq [-c]`, `tee [-a]`, `tr [-d]`, `cut`, `seq`,
  `basename`, `dirname`, `which`, `type`, `test`/`[`, `true`, `false`,
  `sleep`, `env`, `set`, `export`, `unset`, `date`, `uptime`, `uname`,
  `hostname`, `whoami`, `df`, `du [-s]`, `free`, `clear`, `help`. They run
  on the kernal itself against its disks, so they're instant and need no
  workers.
- **Disks:** `/` is the kernal's disk and `/tmp` its tmpfs. Every other
  disk, the installer floppy included, is `/mnt/<first characters of its
  address>`, as in OpenOS.
- **Everything else** is a program on `$PATH` (`/bin`, `/usr/bin`: `.mxe`
  or legacy `.lua`) or one of muxos's own commands (`nodes`, `run`,
  `update`, ...), which mix into shell lines (`nodes; ls`). A program's
  output goes to the console, so it can't be piped or redirected.
- **Not done:** command substitution, here-documents, functions and
  control flow (`if`, `for`, `while`). `grep` takes Lua patterns rather
  than POSIX regular expressions (`grep -F` matches plain text).

Tested in `test/emu/integration_test.lua`, test 41.

### The desktop, the taskbar and the demo

- **Icons:** a program can have its own icon: an `.mxe` sets `icon` (4
  rows of 9 columns) and `icon_color` in its header, and any program can
  have a `<name>.icon` file next to it (art, optionally after a
  `#RRGGBB` line). See docs/MXE.md.
- **Taskbar:** the bottom row, above every window. It has a start button
  (**≡ muxos**), whose menu lists every app, which is handy when windows
  cover the icons. It has a button per window: touching one restores and
  raises it, or minimizes it if it's already the focused window on top.
  The clock is on the right.
- **`demo`** (`/bin/demo.mxe`, with its own icon): muxos's test program.
  - Four threads run at once: an image thread, a braille-graphics thread,
    a status thread, and the main thread waiting for `q`.
  - It computes a Mandelbrot image in strips, each in a child process
    that the scheduler places on the workers. It queues strips beyond
    what the fan-out cap allows.
  - It draws the image as colour half-block graphics, then cycles its
    colours; it animates braille graphics; and a text window shows which
    worker computed each strip.
  - `demo [strips]`; press `q` in one of its windows to end (test 44).

muxos starts on a desktop, as gmux does: a background with a column of
app icons at the top left -- the console, and every program in `/bin`
and `/usr/bin`. Touching an icon starts that program (a legacy `.lua`
program opens in its own terminal window); the console icon brings the
console back. `comp` returns to the desktop from console mode and
rescans for newly installed programs (test 40).

The console keeps its text in regular memory (500 lines of scrollback)
and has no video buffer: it's a text window with a title bar, like any
other (minimize, move, resize; its close button minimizes it), docked in
the bottom half of the screen by default (`console <w> <h>` resizes it),
painted into the frame buffer, or, in console mode, drawn straight onto
the screen. It has scrollback
(PgUp/PgDn, mouse wheel) and queues input while a command runs. Nodes are tracked
for liveness without a heartbeat (probes answered at job yield points;
a silent node's jobs become `lost`), finished-job history is capped at
100 without source, and `get_orphans` only hands out real orphans (with
their result if they finished). Verified in `test/emu/integration_test.lua`
(tests 20-26).

**Legacy (OpenOS) programs -- BUILT so far.** A `.lua` program gets
OpenOS's `require`: the common OpenOS libraries (vendored in
`kernal/lib`, installed as `/lib`; add more by installing files there)
plus runtime faces for `component`, `computer`, `event`, `term`,
`filesystem` and `unicode`. It behaves like a gmux app: it has its own
decorated, resizable window that is its terminal (`print`/`io.read`)
and its virtual gpu/screen/keyboard, and it uses the OS filesystem
(the kernal's disk) through `io`/`filesystem`. Tests 29, 33-35.

**Cluster component bus -- BUILT.** Every node's components are visible
to programs anywhere in the cluster. Each node reports its components to
the kernal, and programs use them through the normal `component` API:
calls to their own node's components are direct, others go through the
kernal. Values a call returns, like an internet request handle, work
remotely too. OpenComputers gives each computer its own component bus,
so this is emulated over the network. The display, network cards and
firmware stay off it. `bus` at the console lists it. Test 36.

**`.mxe` spec and OPM -- BUILT.** docs/MXE.md is the contract for
programs written for muxos: header fields, version compatibility,
libraries (`/lib/mxe`, `/usr/lib/mxe`, with dependencies), and the native
API (`fs`, `readLine`, `gmuxapi`, `component`, the `mux` and `http`
libraries). OPM is ported to it (`opm/`) and ships with muxos:
`opm pull <package>`. Tests 37-38.

**Migration and draining -- BUILT.** An `.mxe` that lists the built-in
`mux` library can opt in with `mux.migratable(save)`; `migrate <id>
[node]` moves it at its next yield point and it restarts on the target
with `mux.restored()` returning its saved state. `drain <node>` takes a
node out of rotation and moves its migratable processes off; `undrain`
reverses it. Legacy programs aren't migrated. (Transparent migration
isn't possible: the sandbox has no `eris`.) Test 31.

**Still forward design, not yet built**: the
rest of the general `.mxe`-vs-legacy hardware access model: the
networking side entirely (a lightweight kernal modem kernel module for
`.mxe`, eventual GERTi access, vs. an emulated modem for legacy). See
docs/PROTOCOL.md's "The `.mxe` process model" section for the full
design and what's still genuinely undecided.

Processes are isolated (own environment, crash-contained) and the
kernal can pause, resume, or end any of them; windows are persistent
handles their process can redraw (`gmuxapi.draw_window`), and keyboard
input goes to the process owning the focused window
(`gmuxapi.pull_event`). Programs launch OpenOS-shell style by name
from the console (foreground, or background with `&`) or via
`gmuxapi.launch`: `.mxe` headers declare the muxos version and
libraries they want and get a response; `.lua` programs get an
OpenOS environment with console I/O. Verified in tests 27-29.
