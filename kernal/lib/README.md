# Legacy (OpenOS) libraries

These files go on the kernal's disk as `/lib/...`. Legacy `.lua` programs
`require` them the same way they would on OpenOS. The kernal ships the
ones a program requires along with it, and serves any others on demand.

Vendored unchanged from OpenOS (MightyPirates/OpenComputers,
`loot/openos/lib`, branch master-MC1.12), MIT licensed, see
`OPENOS_LICENSE`:

- `serialization.lua`, `text.lua`, `sides.lua`, `colors.lua`, `keyboard.lua`, `internet.lua`,
  `transforms.lua`
- `core/full_keyboard.lua`, `core/full_text.lua`, `core/full_transforms.lua`
  (loaded lazily by the above through `package.delay`)

To add a library, drop it in `/lib` (or `/usr/lib`) on the kernal's disk.
Machine-level modules (`component`, `computer`, `event`, `term`, `unicode`,
`process`, `buffer`, `package`) are provided by the worker
runtime itself, not by files here.
