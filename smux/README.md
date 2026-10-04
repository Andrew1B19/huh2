# smux

smux ('server mux', vs. Gmux's graphical mux) is a headless multiplexer for OpenComputers/OpenOS:
one powerful server-tier node runs several programs side by side instead of needing one small node
per job. Its process/crash/filesystem isolation core is forked from Gmux's real, working backend
(`reference/gmux/`, MIT), not built from scratch - see `docs/design.md` for what was ported and why.

## Status

- **Process isolation** (`backend/process.lua`, `backend/patch.lua`, `backend/core.lua`): forked
  from Gmux, verified under the real OpenComputers emulator - one job crashing does not take down
  another job or the host (`test/ocemu_crash_isolation.lua`).
- **Filesystem isolation** (`backend/virtual_components/filesystem.lua`): forked from Gmux,
  verified under the emulator - separate per-job roots on the same real disk, path-traversal
  blocked (`test/ocemu_fs_isolation.lua`). One known rough edge: a blocked path raises a raw error
  instead of a clean denial - isolation holds, error handling needs polishing.
- **Remote console / GERTi transport** (`gertinet.lua`, `serve.lua`, `session.lua`, `framing.lua`,
  `job_console.lua`): built and verified end to end under the real OCEmu emulator with real
  GERTi - a full AUTH -> ATTACH -> INPUT -> OUTPUT round trip over the actual transport (see
  `docs/design.md` section 4). `io_patch.lua`'s per-process-fd wiring under real OpenOS is the one
  still-open piece (section 4's "Still open" list).
- **Production entrypoint and installer** (`main.lua`, `installer/`): built (section 7) - a real
  deployable program and floppy installer now exist. `main.lua` itself is not yet verified end to
  end under the real emulator (section 7.4).
- **Component-visibility scoping** specifically (not just filesystem): same mechanism as
  filesystem isolation, not yet separately exercised by a test.

## Running the verified scenarios

```
tools/ocemu/run.sh <this-repo-copied-to-a-dir> smux/test/ocemu_crash_isolation.lua
tools/ocemu/run.sh <this-repo-copied-to-a-dir> smux/test/ocemu_fs_isolation.lua
```

See `tools/ocemu/README.md` for the emulator itself (runs on the LXC).
