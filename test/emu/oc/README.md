# Vendored OpenComputers files

`machine.lua` is the OpenComputers mod's own sandbox/kernel bootstrap
(`src/main/resources/assets/opencomputers/lua/machine.lua`, branch
`master-MC1.12`), unmodified, under the mod's MIT license (`LICENSE`).

`test/emu/emulator.lua` boots every node through it, so muxos's EEPROM
code runs inside the same sandbox it gets on real hardware: wrapped
`coroutine.yield`/`resume`, the Lua-side `computer.pullSignal`, no
`debug.sethook`, no `eris`, and the "too long without yielding" deadline.
