# Real-hardware verification suite

`verify.lua` checks, on real OpenComputers hardware, the sandbox
behavior muxos depends on:

- the `component`/`computer` APIs muxos calls exist, including
  `computer.pullSignal` and `computer.shutdown`;
- the Lua 5.3 library profile (`utf8`, `math.type`);
- `computer.pullSignal(timeout)` really times out, and
  `computer.pushSignal` round-trips through it;
- a nested coroutine's `coroutine.yield` comes back to its resumer
  (muxos's job model);
- a coroutine that never yields is ended by the machine's "too long
  without yielding" deadline while the machine itself survives (muxos's
  only protection against a runaway job -- takes `system.timeout()`,
  5s by default);
- whether `debug.sethook` and `eris` are reachable (informational --
  muxos uses neither, but semi-live migration can't be built on `eris`
  unless it is);
- a GPU/screen and modem smoke test, if present.

Every check also runs inside `test/emu`'s emulator, which boots the
mod's own `machine.lua` (test 30 of `test/emu/integration_test.lua`), so
any difference on real hardware points at something the emulator still
gets wrong.

## Running it

`verify.lua` is bigger than an EEPROM's 4 KB, so it runs from a disk:

1. Flash `bios.lua` (this directory) to an EEPROM.
2. Put `verify.lua` on any filesystem as `/verify.lua`.
3. Boot with no OpenOS.

Results go to a GPU+screen if present (one PASS/FAIL line per check, with
details); the beep pattern is two rising tones if everything passed, two
low tones if anything failed.

## History

An earlier version of this suite checked `debug.sethook` count hooks
and `eris` persistence, which muxos then depended on. Running it inside
the real sandbox showed 7 of its 14 checks would fail on real hardware
-- neither is exposed to EEPROM code -- and it was too big to flash to
an EEPROM as its instructions said. Both dependencies are gone from
muxos now (see docs/PROTOCOL.md's "The real sandbox").
