# opm for Munix

The Munix port of opm, the Open Computers Pull Manager (LewisHost.Net
`oc-programs/ocpull`), as an `.mxe` program. It ships with munix: the
installer puts `opm.mxe` in `/bin` and `opm_core.lua` in `/lib/mxe`.

- `opm_core.lua` is opm's pure logic, vendored unchanged from
  `ocpull/opm_core.lua` (opm 0.4.0).
- `opm.mxe` is opm 0.4.0's command line, rewritten against the `.mxe`
  APIs (docs/MXE.md): files through `fs`, HTTP through the `http`
  library over any internet card in the cluster, arguments through
  `mux.parseArgs`.

Same commands and catalog (`programs.cfg`, oppm format) as on OpenOS,
except:

- `--from=DIR` installs from an `opm bundle` directory with no network
  (what opmf does on OpenOS).
- `opm update` with no argument reinstalls opm from the catalog's
  `opm-mxe` package, into `/bin` and `/lib/mxe`.
- `opm hook` is gone: the Munix console has no tab completion.
- `opm system` shows the Munix version running and installed; `opm
  system update [--force] [--reboot]` installs the catalog's
  `munix-installer` release through the kernal's `munix.update` service
  (root only, by default). It works with `--from=DIR` too.

Installed OpenOS packages (`.lua`) run as legacy programs. Their files go
under `/usr` by default, which the launcher (`/usr/bin`) and legacy
`require` (`/usr/lib`) both search.

## Making `opm update` work

Copy this repository into oc-programs as `munix/`, and merge the
`opm-mxe` entry from `dist/programs.cfg` into the catalog's
`programs.cfg`. That file also has the `munix-installer` entry.
