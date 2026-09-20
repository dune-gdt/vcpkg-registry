# dune-gdt vcpkg registry

A [vcpkg git registry](https://learn.microsoft.com/vcpkg/produce/publish-to-a-git-registry)
holding the ports [dune-gdt](https://github.com/dune-gdt/dune-gdt) needs but
upstream vcpkg does not provide (the DUNE modules, `uv`) or does not provide in
a usable shape (`gmsh`, `mpfr`, `gmp`, `pybind11`, `lapack-reference`, the GNU
autotools).

These ports used to live in dune-gdt as overlay ports under
`.vcpkg-overlays/ports/`. They are a registry now so that they are versioned,
consumable by more than one project, and pinned by a single commit hash rather
than by whatever happens to be checked out next to the manifest.

## Consuming the registry

Put a `vcpkg-configuration.json` next to your `vcpkg.json`:

```json
{
  "default-registry": {
    "kind": "builtin",
    "baseline": "<upstream vcpkg commit>"
  },
  "registries": [
    {
      "kind": "git",
      "repository": "https://github.com/dune-gdt/vcpkg-registry",
      "baseline": "<commit in this repo>",
      "packages": [
        "alberta",
        "autoconf",
        "autoconf-archive",
        "automake",
        "dune-alugrid",
        "dune-common",
        "dune-geometry",
        "dune-grid",
        "dune-grid-glue",
        "dune-istl",
        "dune-localfunctions",
        "dune-testtools",
        "dune-uggrid",
        "gmp",
        "gmsh",
        "lapack-reference",
        "libtirpc",
        "libtool",
        "mpfr",
        "pybind11",
        "uv"
      ]
    }
  ]
}
```

Every name listed under `packages` is served by this registry instead of
upstream vcpkg, for direct *and* transitive dependencies alike — which is what
makes the modified copies of `gmp`/`mpfr`/`gmsh` take effect even though
nothing depends on them directly. A name that is **not** listed still comes
from the default registry, so listing a port here is how the override is turned
on; `vcpkg-configuration.json` and the registry's `versions/baseline.json` must
stay in agreement about which ports exist.

`builtin-baseline` in `vcpkg.json` and `default-registry` in
`vcpkg-configuration.json` are two spellings of the same setting, and vcpkg
rejects a project that uses both. Keep the one in `vcpkg-configuration.json`.

Note that a registry can only serve **ports**. Overlay triplets stay with the
consuming project.

## Layout

| Path | Contents |
|------|----------|
| `ports/<port>/` | the port itself (`vcpkg.json`, `portfile.cmake`, patches) |
| `versions/baseline.json` | the version each port resolves to by default |
| `versions/<x>-/<port>.json` | every published version of a port and the git tree it points at |
| `scripts/module_list.bash` | the DUNE module pins (git URL + commit) |
| `scripts/update-dune-ports.bash` | regenerates the DUNE ports from those pins |
| `scripts/update-versions.py` | regenerates `versions/` from `ports/` |

## Changing a port

vcpkg resolves a package by looking its version up in `versions/` and
extracting the recorded `git-tree`, so **a port change is only visible once the
versions database is regenerated**. After editing anything under `ports/`:

```bash
pre-commit run --all-files          # formatting first -- see below
scripts/update-versions.py          # rewrite versions/
scripts/update-versions.py --check  # what CI runs
```

and commit `ports/` and `versions/` together.

Run the formatting hooks **before** regenerating: `clang-format` and
`cmake-format` rewrite files under `ports/`, which changes their git tree, so
formatting after the regeneration leaves `versions/` stale and fails CI.

A published `version`/`port-version` pair has to keep resolving to the same
sources, so `update-versions.py` refuses to re-point one at a new tree. Bump
`port-version` in the port's `vcpkg.json` instead (or pass
`--overwrite-version` if the entry was genuinely never consumed).

Consumers pick up the change by moving their registry `baseline` to the new
commit in this repo.

## The DUNE ports are generated

`ports/dune-*` are **generated, not hand-edited**. The source of truth is
`scripts/module_list.bash`, which maps each DUNE module to a git URL and a
commit hash:

```bash
SUBMODULE_INFO_HASH['dune-istl']='...'
SUBMODULE_INFO_URL['dune-istl']='https://github.com/dune-mirrors/dune-istl.git'
```

`update-dune-ports.bash` reads that file and (re)writes
`ports/<module>/vcpkg.json` + `ports/<module>/portfile.cmake` for every module.
The port `version` is taken from each module's `dune.module` `Version:` field at
the pinned commit. To refresh a pin, edit `scripts/module_list.bash` and rerun:

```bash
scripts/update-dune-ports.bash
pre-commit run --all-files
scripts/update-versions.py
```

Because every DUNE module reports the same `Version: 2.10` regardless of which
commit on `releases/2.10` is pinned, moving a pin does not move the port's
version. `update-dune-ports.bash` therefore bumps the port's `port-version`
whenever the pinned commit changes but the reported version does not, which is
what keeps each published version resolving to one fixed tree.

> Note: `update-dune-ports.bash` clones every module listed in
> `scripts/module_list.bash`. All of them are hosted on GitHub
> (`dune-mirrors/*`, `dune-community/*`), so the regeneration does not need
> `gitlab.dune-project.org` to be reachable. Where the script cannot be run at
> all, edit `scripts/module_list.bash` and the affected `portfile.cmake` and
> `vcpkg.json` together by hand, keeping them in sync, then run
> `update-versions.py`.

## Hand-maintained ports

Everything that is not a DUNE module is edited by hand; `update-dune-ports.bash`
only touches the modules listed in `scripts/module_list.bash`, so it leaves
these alone. Where a port is a copy of the upstream vcpkg port, "upstream"
below means `ports/<port>/` in a [vcpkg](https://github.com/microsoft/vcpkg)
checkout at the consumer's `default-registry` baseline.

### GNU autotools host tools

`libtirpc` and `alberta` build with `vcpkg_configure_make`, which needs the GNU
autotools. To avoid depending on whatever happens to be installed on the build
machine, the following ports pin current upstream releases (downloaded from
`ftp.gnu.org` and verified by SHA-512):

| Port | Version | Notes |
|------|---------|-------|
| autoconf | 2.73 | `autoconf`, `autoreconf`, `autom4te`, ... under `tools/autoconf/bin` |
| automake | 1.18.1 | `automake`/`aclocal`; depends on `autoconf` (host) |
| libtool | 2.5.4 | `libtool`/`libtoolize` plus the `libltdl` loader library + `ltdl.h` |
| autoconf-archive | 2024.10.16 | data-only: ~580 reusable m4 macros under `share/autoconf-archive/aclocal` |

`vcpkg_configure_make` bakes the persistent `CURRENT_INSTALLED_DIR` into the
installed scripts as their prefix and installs the executables under
`tools/<port>/bin`, so the tools remain usable after the temporary build trees
are gone. The aclocal macros for each port live in `share/<port>/aclocal`; a
consumer that wires these tools onto `PATH` should also add those directories to
`ACLOCAL_PATH` (for example `share/libtool/aclocal` and
`share/autoconf-archive/aclocal`).

Providing these ports is not enough on its own. Declaring them as `host`
dependencies of a make-based port makes vcpkg *build and install* them into the
host tree, but it does **not** put them to use: `vcpkg_run_autoreconf` locates
`autoreconf`/`aclocal`/`libtoolize` with a plain `find_program`, and vcpkg does
not add a host dependency's `tools/<port>/bin` to the consuming port's build
`PATH`. The aclocal macros are also installed under per-port
`share/<port>/aclocal` dirs that `aclocal` does not search by default. A consumer
therefore has to do two things: declare the tools as `host` dependencies *and*,
in its portfile, prepend `tools/autoconf|automake|libtool/bin` to `PATH` and set
`ACLOCAL_PATH` to the `share/*/aclocal` dirs (so the `AX_*` macros from
autoconf-archive are found).

`libtirpc` and `alberta` happen to build against the autoconf/automake/libtool
that the CI runners already ship, so they don't wire anything up. `mpfr` is the
port that actually needs these tools: it autoreconfs and its `configure.ac` uses
an autoconf-archive (`AX_*`) macro that is **not** present on the runners. It is
kept here as a copy of the upstream port (`dll.patch`, `src-only.patch`, `usage`
verbatim) with two changes to `portfile.cmake` and `vcpkg.json`: the four
autotools added as `host` dependencies, and a block before `vcpkg_make_configure`
that prepends the tool `bin` dirs to `PATH` and points `ACLOCAL_PATH` at the
installed `share/*/aclocal` dirs. Without this, `mpfr` falls back to the build
machine's system autotools and fails on runners that lack `autoconf-archive`.
When a consumer bumps its vcpkg baseline, re-sync the patches/usage from
upstream if they changed, and re-check that the upstream `portfile.cmake` still
matches apart from the autotools wiring block.

To bump a version: update `version` in the port's `vcpkg.json`, the URL/SHA-512
in its `portfile.cmake` (`sha512sum` of the new `.tar.xz`), and rebuild.

### gmp

`mpfr` depends on `gmp`, which would otherwise come from the upstream vcpkg
registry port. That port's `URLS` list tries `ftpmirror.gnu.org` first, and that
redirector has intermittently returned 502/504 or timed out entirely on
ephemeral CI runners, which stalls or fails an otherwise cold, from-source
configure (see dune-gdt#470). `gmp` is kept here as a byte-for-byte copy of the
upstream port (`vcpkg.json`, all `*.patch` files, `usage` verbatim) with a
single change to `portfile.cmake`: the `URLS` list is reordered to try
`ftp.gnu.org` first, then `gmplib.org`, with `ftpmirror.gnu.org` moved to last
as a final fallback rather than removed outright. When a consumer bumps its
vcpkg baseline, re-sync everything from upstream and re-apply just that
reordering.

### gmsh

Only requested via dune-gdt's `gmsh` manifest feature, and only by the docs
build's CMake configure: pymor's `discretize_gmsh`, used by the
`example__gmsh_grid` tutorial notebook, shells out to a bare `gmsh` on `PATH` to
turn a plain polygonal 2D domain into a mesh.

Upstream's own vcpkg port builds `gmsh` with `ENABLE_PARSER=OFF` and
`ENABLE_MESH=OFF` -- it exists there only to produce `libgmsh` for C++ consumers
to link against, and the CLI it also builds under those flags cannot read a
`.geo` file at all ("Gmsh parser is not compiled in this version"), let alone
mesh one. It is kept here as a copy of the upstream port (`*.diff` patches,
`usage` verbatim) with `portfile.cmake` flipping `ENABLE_PARSER`/`ENABLE_MESH`
to `ON`, plus `ENABLE_EIGEN=ON` (and `eigen3` added to `vcpkg.json`'s
dependencies) -- meshing a plain rectangle with both off still failed with
"Matrix inversion requires Eigen or LAPACK" during the mesher's element-quality
step. `eigen3` is header-only and already a project-wide dependency of dune-gdt
(pinned by the `overrides` block in its manifest), so this reuses the exact copy
every other target there links against rather than building a second one.
Verified end-to-end locally: `pymor.discretizers.builtin.domaindiscretizers
.gmsh.discretize_gmsh` against the `x64-linux-shared`-built binary correctly
meshes `example__gmsh_grid`'s L-shaped domain.

GRAPHICS/POST/PLUGINS/OCC and everything else upstream disables stay off:
nothing here needs a GUI, post-processing views, or CAD import, only reading a
`.geo` script and writing a `.msh` mesh. When a consumer bumps its vcpkg
baseline, re-sync the patches/`usage`/`vcpkg.json` base from upstream if they
changed, and re-check that the upstream `portfile.cmake` still matches apart
from the `ENABLE_PARSER`/`ENABLE_MESH`/`ENABLE_EIGEN` flags.

### pybind11, lapack-reference, libtirpc, alberta, uv

`pybind11` is the upstream port with the unnecessary `python3` dependency
dropped. `lapack-reference` carries a `FindLAPACK.cmake` and CMake-config
patches. `uv` has no upstream vcpkg port at all and is hand-written; see
`ports/uv/README.md`. `libtirpc` and `alberta` are needed by the `alberta` grid
feature. Each of these documents its own deviation in its portfile or README.

## Current pins (DUNE 2.10)

All core/staging modules currently track the **`releases/2.10` maintenance
branch** (i.e. 2.10.x plus accumulated bugfixes), not the exact `v2.10.0` tags.

| Port | Source repo | Notes |
|------|-------------|-------|
| dune-common | `dune-community/dune-common` | custom fork branch `releases/2.10_superbuild_hack` (carries downstream patches) |
| dune-geometry | `dune-mirrors/dune-geometry` | `releases/2.10` HEAD |
| dune-grid | `dune-mirrors/dune-grid` | `releases/2.10` HEAD |
| dune-istl | `dune-mirrors/dune-istl` | `releases/2.10` HEAD |
| dune-localfunctions | `dune-mirrors/dune-localfunctions` | `releases/2.10` HEAD |
| dune-grid-glue | `dune-mirrors/dune-grid-glue` | `releases/2.10` HEAD |
| dune-alugrid | `dune-mirrors/dune-alugrid` | `releases/2.10` HEAD, **rewritten hash** (see below) |
| dune-uggrid | `dune-mirrors/dune-uggrid` | `releases/2.10` HEAD |
| dune-testtools | `dune-community/dune-testtools` | community fork |

Every module is sourced from GitHub mirrors (`dune-mirrors/*`,
`dune-community/*`) rather than upstream `gitlab.dune-project.org` so that builds
work on networks where GitLab is not reachable.

The `dune-mirrors/*` mirrors are refreshed from upstream GitLab by the
[`dune-mirrors/mirrorer`](https://github.com/dune-mirrors/mirrorer) workflow,
which mirrors every repository listed in that repo's `repos.json` once a day. A
module that is pointed at a `dune-mirrors/*` URL here must also be listed there,
or its mirror goes stale and the pinned commit eventually becomes unreachable.

### dune-alugrid's hash does not match upstream

`dune-alugrid` is the one module whose mirror is **not** a byte-identical copy
of upstream, and its pin is therefore not an upstream GitLab commit hash.

Upstream carries two benchmark outputs (`results/mb_kway_314/mb.2048.out` at
506 MB and `mb.4096.out` at 435 MB) that were committed in February 2014 and
deleted a fortnight later. GitHub refuses any pushed blob over 100 MB (`GH001`)
and declines the *entire* push when it finds one, so — although the files are
absent from every current tree — their presence in the ancestry of 82 of the
repo's 83 refs made the whole repository unmirrorable. (This is why
`dune-mirrors/dune-alugrid` sat frozen at `releases/2.6` for years.)

The mirrorer therefore runs `git-filter-repo` on this one repository to strip
blobs over 100 MB before pushing, which rewrites every commit from February
2014 onward. Consequences for this port:

- The pin `bf551bd6740ba01d30feea9daaec4d77cdaed47c` is the **rewritten**
  `releases/2.10` HEAD. Its upstream GitLab counterpart is
  `60aa6fa7e9e146911b653f5dab0aafa6e7fe9fe8`; the two are not interchangeable
  and only the rewritten one exists on the mirror.
- **The built source is unaffected.** Both commits have the identical tree
  (`d5a0f7549d19cf507b5d6bf273f958708ca362b7`) — only the stripped benchmark
  outputs, which no tree at or after 2014 references, are gone.
- The rewrite is reproducible (the mirrorer pins its `git-filter-repo`
  version), so refreshes fast-forward and this pin stays valid. If that version
  is ever bumped, re-check that the hashes are unchanged before assuming this
  pin still resolves.
- To map an upstream commit to its mirrored equivalent, re-run the same filter
  locally and consult `.git/filter-repo/commit-map`.

### Pin policy caveat

A pin itself is reproducible: `scripts/module_list.bash` holds a full commit
hash, and `vcpkg_from_git` resolves that same commit however far the branch has
since advanced. What is not pinned is the *choice* of commit -- each hash was
whatever `releases/2.10` pointed at when it was last refreshed, not a release
tag. Rerunning `update-dune-ports.bash` against an advanced branch therefore
silently selects a different commit, and nothing in the version number records
which one (hence the `port-version` bump above). For builds you can reason
about, prefer pinning to the exact release tag commit (`v2.10.x`) and bumping
deliberately.

## Upgrade path to DUNE 2.11

DUNE 2.11.0 was released 2026-02-07 (2.10.0 was 2024-10-23). Moving the ports to
2.11 is gated on more than editing hashes:

1. **The GitHub mirrors are stale.** `dune-mirrors/*` and `dune-community/*` have
   no `releases/2.11` branch and no `v2.11.0` tag — only `releases/2.10` and
   `master`. There is nothing 2.11-shaped to pin to on GitHub yet. Either push
   `releases/2.11` to the mirrors, or allowlist `gitlab.dune-project.org` and
   point the URLs upstream.
2. **dune-common carries downstream patches.** It is pinned to the custom fork
   branch `releases/2.10_superbuild_hack`. A `releases/2.11_superbuild_hack`
   equivalent must be rebased on the fork first — this is the gating work item.
3. **API churn.** The biggest porting risk in 2.10→2.11 is the
   typetree → dune-common migration (`dune-functions`'s dependency on
   `dune-typetree` is being downgraded/removed, completing in 2.12) and the
   expanded C++20 concepts in dune-common/dune-grid. dune-gdt's grid-view and
   local-function code is the likely friction point.

Once mirrored and patched, the mechanical steps are: update the hashes/URLs in
`scripts/module_list.bash`, rerun `update-dune-ports.bash` and
`update-versions.py`, move the consumer's registry `baseline` to the new commit,
build-test, bump dune-gdt's CI build cache key, and (optionally) raise the
`Depends`/`Suggests` floor in its `dune.module` from `>= 2.8`.
