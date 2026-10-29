# CLAUDE.md

Guidance for working in this repository.

## What this project is

The consumer side of [NCAR/hpc-dev-container-factory](https://github.com/NCAR/hpc-dev-container-factory).
The factory publishes portable base images, `ghcr.io/ncar/hpcdev-<arch>:<os>-<compiler>-<mpi>-<YY.MM>`
(compiler x MPI x OS, with HDF5, NetCDF, PnetCDF, PIO, OpenBLAS, FFTW and HeFFTe).
This repository builds apps on them for each cluster's CPU, turns images into
`.sif` files on the cluster, and runs and measures them there. See README.md.

It depends on the factory **only through the factory's `CONTRACT.md`**. Anything
in a base image the contract does not name -- `/container/bin/docker-clean`,
other files under `/container/extras/`, a particular library version -- may
change without notice; do not build on it. If an app needs something the
contract lacks, the change belongs in the factory, with its contract and its
`check_base_contract.sh`.

## Layout

- `apps/` -- `apps/Dockerfile` (one for every app, `ARG APP`), `apps/<app>/{build.sh,app.d/}`,
  `matrix.py` (a cluster's `images:` block -> the workflow's matrix), `smoke.sh`
  (one run through the app contract). See `apps/README.md`.
- `sif/` -- `Deffile` (one template; the Makefile fills in the registry reference)
  and `Makefile` (`make <cluster>`, `make <cluster>-<app>`, `make check-images`).
  `GHCR_BASE_REF` and `GHCR_APPS_REF` at its top are the only place the registries are named.
- `hpcrun/` -- the runner. `submit`/`validate`/`collect`/`sitegen`/`clusterinit` on the
  login node, `runner.sh` in the job, shell libraries in `lib/`, `schema/` for the
  three YAML formats, off-cluster tests in `tests/`.
- `sites/` -- `sites/<site>.yaml`, `sites/<site>/<cluster>.yaml`, and each cluster's
  generated `cluster.sh` and `images.mk`. A new cluster: `hpcrun/clusterinit draft`,
  then `probe-job`, then `hpcrun/sitegen <cluster> --write` (`sites/README.md`).
- `APP_CONTRACT.md` -- the app contract, which this repository defines.
- `docs/plans/` -- the design record; `docs/plans/README.md` says which plan is current.

## Rules that hold the design together

- **A fact about a machine is stated once, in its description.** The image set,
  CPU target and each compiler's spelling of it live in the cluster's `images:`
  block, and a sub-cluster's own target in `subclusters.<name>.images`; `apps/matrix.py`, `sif/Makefile` (through `images.mk`) and `hpcrun/` all
  read it. Edit the YAML, then `hpcrun/sitegen <cluster> --write`; never edit
  `cluster.sh`'s generated block or `images.mk` by hand (a test fails while they are stale).
- **One tag means one build.** Base images are portable and carry no target. App
  images carry the target in the tag, named for the microarchitecture (`znver3`,
  `cascadelake`), not the cluster; `sitegen --check` refuses two clusters (or
  node types) that spell one target differently. An image set keeps its cluster's
  name and resolves to the node type's target; `validate` refuses another's.
- **Tuning belongs to the app layer.** `APP_MARCH_FLAGS` from the cluster's
  `images.march`. nvhpc ignores `-march=`: its spelling is `-tp=` (`-tp=zen3`).
- **The runner never learns an app's name.** Everything app-specific is in
  `/container/app.d/<app>/`. If adding an app forces an edit under `hpcrun/`, the
  contract has failed.
- **An image's identity comes from its labels** (`hpcdev.app`, `.compiler`, `.mpi`,
  `.target`, ...), set by the app workflow and kept by `apptainer build`; the file
  name is only a fallback for older images.
- **OSU's contract belongs to the factory.** `hpcrun/tests/fixtures/app.d/osu/` is a
  copy that the tests hold the factory's images to; when the factory changes it,
  copy it again.

## Gotchas

- **A base image's ENTRYPOINT re-splits its arguments.** It is
  `bash --rcfile /container/config_env.sh --login -c '${*}' --`, so
  `docker run <img> bash -lc '<script>'` runs only the script's first word. Pass
  plain words: `docker run <img> /src/apps/smoke.sh hpcg 2 2`.
- **`report_cpu_features` is the factory's.** `hpcrun/lib/check_arch.sh` reads its
  `AVX-512 required:` line, whose wording the factory's contract fixes, and falls
  back to its own by-function check for images that predate it. The "x86 ISA needed"
  ELF note is meaningful only for a gcc binary built with `-mneeded`; count `%ymm`
  or `vfmadd` in `objdump -d` to see what a `-march=` build really uses.
- **Matrix from `fromJSON`.** The app workflow's matrix is `{"include": [...]}`
  from `matrix.py`, with no static axes. GitHub merges an `include:` entry only into
  a combination that already exists; one that matches none becomes a lone job
  without the other axes. Keep it generated, not hand-written.
- **apptainer binds the host's `/tmp`.** Running an app's `build.sh` by hand inside
  a `.sif` needs a private `/tmp` (`--bind $(mktemp -d):/tmp`), or its cleanup
  empties the login node's.
- **`--cleanenv` on a login node.** The host's compiler and MPI modules otherwise
  reach the container's wrappers.

## Useful commands

```bash
make -C hpcrun test                         # the off-cluster suite; run after any edit
python3 apps/matrix.py derecho --table      # what the app workflow would build
hpcrun/sitegen --check                      # descriptions agree, generated files current
gh workflow run app-image-builder-ghcr.yaml -f cluster=casper -f apps=hpcg
gh run view --job <job-id> --log            # one job's log
```

The base images' tags and digests: the
[hpcdev-x86_64 package page](https://github.com/orgs/NCAR/packages/container/package/hpcdev-x86_64),
or `sif/pin_image_digest.sh --resolve ghcr.io/ncar/hpcdev-x86_64:<tag>`.
