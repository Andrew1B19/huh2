# Real-hardware verification suite

`verify.lua` checks a list of low-level primitives this project's
design depends on, several of which could only be verified by reading
the mod's own Scala source in the sandbox this project was built in --
there was no real OpenComputers Lua environment available there to run
against. Most importantly: **whether `eris` can persist a SUSPENDED
coroutine's call stack and resume it correctly after unpersisting**,
which the proposed "semi-live" job migration design (pause a job,
serialize it, ship it to another node, resume it there) depends on
entirely. Strongly implied by the mod's own use of `eris` to persist a
computer's live kernel thread across every Minecraft world save
(`PersistenceAPI.scala`) -- but never run directly from Lua code in
this project before, and not possible to test in a sandbox with no
running OC instance and no network access to fetch a standalone `eris`
build either.

## Running it

Flash directly to an EEPROM:

```
eeprom test/hardware/verify.lua
```

Boot with **no OpenOS** -- the `computer.pushSignal` round-trip check
needs to run as the computer's own true top-level/kernel coroutine to
mean anything; nesting it under OpenOS's own thread/process scheduling
instead could give a misleading result for that one check specifically
(every other check would read the same either way). Results are
written to a gpu+screen if one's present, and reported via a beep
pattern either way (two quick high beeps = everything passed, two slow
low beeps = something failed -- check the screen/log for which).

## What this does NOT replace

`test/emu/`'s integration test already covers the full multi-node wire
protocol end to end, in a dev sandbox, with no real hardware needed.
This suite is specifically for the primitives that sandbox can't
verify at all (real `eris` behavior, the real Lua library profile
active on this build, real GPU buffer operations) -- it's a
complement, not a replacement.

## Only partially verified by me before you run it

I confirmed this suite's own structure (pcall isolation between checks,
the reporter degrading gracefully with no gpu/modem present) by dry-
running it on a desktop `lua5.3` with stub `component`/`computer`
globals -- that proves the suite won't crash itself, not that any of
the OC-specific assertions are correct. The `eris` checks in particular
are untested beyond reading the Scala binding's own usage pattern.
