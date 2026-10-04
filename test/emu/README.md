# A 4-node OpenComputers test environment, emulated

`emulator.lua` is a purpose-built, faithful-to-source emulator for this
project's bare-metal files -- **not** the community OCEmu (that needs a
full LÖVE2D graphics runtime, which isn't installable headless in this
project's dev environment). It models exactly the native primitives the
real production files use, each verified against the mod's own Scala
source this session (see `docs/PROTOCOL.md`'s "The kernal is
bare-metal" section): `component.list`/`invoke`, `coroutine.yield`-based
signal pulling, `computer.address`/`beep`/`uptime`/`pushSignal`, a
broadcast-only Network Card, a filesystem component, an EEPROM
component, and a Tier-3 GPU/screen pair.

`integration_test.lua` boots the REAL, unmodified repo files --
`kernal/bios.lua`, `kernal/muxos.lua`, `kernal/compositor.lua`,
`kernal/bitmap.lua`, `node/bios.lua`, `node/runtime.lua` -- as 1 kernal
+ 3 workers, and drives the kernal's REPL the way a human would:
injecting `key_down` signals and reading back what actually lands on
the simulated screen. This is deliberately different from the
`/tmp/test_*.lua` unit suite (hand-copied mirrors of individual
functions, run in isolation) -- it's the first and only place the real
files run against each other end to end.

## Running it

```
lua5.3 test/emu/integration_test.lua
```

From the repo root. No dependencies beyond a stock `lua5.3` (or
`luac5.3`-compatible) interpreter -- same as the rest of this project's
test tooling.

## What it already caught, by actually running the real files together

Two genuine bugs were found this way, neither of which any unit-mock
test could have caught (each mocks one file's `gpu`/`component` in
isolation, so nothing exercises two real subsystems writing to the same
simulated screen or coroutine concurrently):

1. **`kernal/compositor.lua`'s `flush()` used to wipe the kernal's own
   text console.** The console (`kernal/muxos.lua`'s `termWrite`) writes
   directly to the real screen (buffer 0) between flushes, since it
   isn't a compositor window. `flush()` used to blit its OWN
   separately-tracked frame buffer onto buffer 0 wholesale -- which is
   mostly blank except where windows have been composited -- erasing
   the console's entire prior output the moment any window existed.
   Fixed by syncing the frame buffer FROM the real screen before
   compositing any newly-dirty window.
2. **`node/runtime.lua`'s job-preemption design could hang a job
   forever.** Wrapping JOB execution in its own coroutine (to protect
   against OC's real non-yielding timeout, see `docs/PROTOCOL.md`'s
   "JOB code and the non-yielding timeout") meant a job calling
   `gmuxapi.*` (which does its OWN nested wait for a specific network
   reply) had that wait's yield mistaken for ordinary voluntary
   cooperation and swallowed, instead of forwarded. Fixed with a
   sentinel that distinguishes "the job voluntarily paused" from "the
   job's own code is waiting for a specific signal," forwarding a real
   signal transparently for the latter.

Both are documented in detail, with the exact reasoning, in
`docs/PROTOCOL.md`.

## Known, deliberate simplifications (not hidden)

- No energy/power model, no per-tick `callBudget` enforcement (this
  emulator is about CORRECTNESS of the Lua-level protocol and control
  flow, not reproducing OC's per-tick GPU-call ceiling -- see
  `docs/PROTOCOL.md`'s "Call budget" section for that separate concern).
- No network latency/relay-delay model beyond "delivered on the next
  scheduler step" (never confirmed from source either -- see
  `docs/PROTOCOL.md`'s "Measured vs. documented latency").
- No Minecraft world/item/block simulation at all -- this is a Lua-level
  contract test, not a Minecraft-accurate simulation.
- Each node's sandboxed environment deliberately omits `os`, `io`,
  `require`, `dofile`, `loadfile` -- the same absence real bare hardware
  has. This is a feature, not a gap: if any production file ever
  accidentally reaches for one of those, this emulator fails the same
  way real hardware would, instead of silently succeeding against the
  test host's own real standard library.

## Extending it

`emulator.lua`'s `Emulator` object exposes `newNode`, `addComponent`
(plus the ready-made `addModem`/`addEeprom`/`addFilesystem`/
`addGpuScreen`), `buildEnv`, `boot`, `injectSignal`, `step`, `advance`,
and `runUntil`. A new scenario is just: build the nodes you need, boot
them with the real file sources, drive the kernal's REPL via
`injectSignal`/a `typeLine`-style helper, and assert on `renderScreen()`
or the emulator's own `log` table (every node's captured `print` output).
