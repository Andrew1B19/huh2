# Legacy (OpenOS) libraries

These files go on the kernal's disk as `/lib/...`. Legacy `.lua` programs
`require` them the same way they would on OpenOS. The kernal ships the
ones a program requires along with it, and serves any others on demand.

Vendored unchanged from OpenOS (MightyPirates/OpenComputers,
`loot/openos/lib`, branch master-MC1.12), MIT licensed, see
`OPENOS_LICENSE`:

- `serialization.lua`, `text.lua`, `sides.lua`, `colors.lua`, `keyboard.lua`, `internet.lua`,
  `transforms.lua`, `buffer.lua`, `uuid.lua`, `bit32.lua`, `note.lua`, `vt100.lua`
- `core/full_keyboard.lua`, `core/full_text.lua`, `core/full_transforms.lua`,
  `core/full_buffer.lua`, `core/full_vt.lua` (loaded lazily by the above)

To add a library, drop it in `/lib` (or `/usr/lib`) on the kernal's disk.
Machine-level modules (`component`, `computer`, `event`, `term`, `unicode`,
`process`, `package`, `filesystem`, `shell`, `thread`, `tty`, `pipe`) are
provided by the worker runtime itself, not by files here. A program's
terminal interprets VT100 escape sequences itself, as OpenOS's tty does
(`vt100.lua` is here for programs that `require` it directly); `pipe` is
`popen` only -- each program is a process of its own. `munix` is Munix's own:
`require("munix").set_persistent(on)` / `.is_persistent()` (keep running
after the user logs out) and `.version`; `sysbus` is the system bus, as
`.mxe` programs have it (docs/MXE.md).
