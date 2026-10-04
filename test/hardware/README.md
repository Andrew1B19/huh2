# Real-hardware verification suite

`verify.lua` checks a list of low-level primitives this project's
design depends on, several of which could only be verified by reading
the mod's own Scala source in the sandbox this project was built in --
there was no running OpenComputers instance available there. Most
importantly: **whether `eris` can persist a SUSPENDED coroutine's call
stack and resume it correctly after unpersisting**, which the proposed
"semi-live" job migration design (pause a job, serialize it, ship it to
another node, resume it there) depends on entirely.

**This is now confirmed, not just implied** -- GitHub's public-read
access turned out to be reachable from this sandbox after all (despite
`git clone`'s normal auth path being blocked), so the real upstream
`fnuecke/eris` library was cloned, built from its own C source, and run
directly: a plain table round-trips correctly; a coroutine persisted
mid-loop (with real accumulated local state) revives into a brand new
coroutine object that resumes and continues correctly; and -- the
scenario that actually matters for migration -- persisting in ONE
process, writing the bytes to a file, and unpersisting in a COMPLETELY
SEPARATE process confirmed that a native function reference marked
permanent re-binds to the RECEIVING process's own binding, not a stale
reference to the sender's. The suite's own `check 8`/`9` originally
used empty `perms`/`uperms` tables and would have failed on real
hardware with `"attempt to persist a light C function"` the moment the
persisted coroutine's closure reached `coroutine.yield` via its `_ENV`
upvalue -- found and fixed by actually running it, the same way OC's
own `PersistenceAPI.scala` avoids this by walking the whole of `_G`
recursively rather than hand-picking a few globals (see
`buildPermsFromGlobals()` in `verify.lua`).

What's still unconfirmed: this was the real, upstream, Lua 5.2 build of
eris -- not OC's own jnlua-bound integration specifically, and not
inside a real Minecraft world. The core mechanism is proven; whatever's
specific to OC's own binding (if anything) is what running this suite
on your actual hardware would catch.

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

## What was and wasn't verified before you run it

- Suite structure (pcall isolation, the reporter degrading gracefully
  with no gpu/modem present): confirmed by dry-running it on desktop
  `lua5.3` with stub `component`/`computer` globals.
- `eris`'s core persist/unpersist behavior, including suspended
  coroutines and cross-process native-function re-binding: confirmed
  for real against the genuine upstream library (see above) -- this
  exact file, run end to end through a coroutine the same way the mod
  drives a real computer, with all 14 checks passing.
- Everything that needs real OC-specific behavior (the real jnlua
  binding specifically, real GPU/modem components, which Lua profile
  your actual install runs): still needs your hardware -- that's the
  gap this suite exists to close.
