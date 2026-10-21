# Apps built on the base images

Each directory here is one application this repository builds on top of a
published base image and publishes as an app image:

```
apps/
  Dockerfile        one for every app: ARG APP, copies apps/${APP}/, runs build.sh
  matrix.py         a cluster's images: block -> the workflow's build matrix
  smoke.sh          one tiny run of an app through its contract, inside an image
  <app>/
    build.sh        builds the app and installs app.d/ at /container/app.d/<app>/
    app.d/          the app contract: app.yaml, and prepare/launch/extract hooks
```

**The base images** are
[NCAR/hpc-dev-container-factory](https://github.com/NCAR/hpc-dev-container-factory)'s,
`ghcr.io/ncar/hpcdev-x86_64:<os>-<compiler>-<mpi>-<YY.MM>`. They are portable,
and an app relies on nothing in them beyond what that repository's
[CONTRACT.md](https://github.com/NCAR/hpc-dev-container-factory/blob/main/CONTRACT.md)
promises: `/container/config_env.sh`, `/container/extras/build_common.cfg`
(`INSTALL_ROOT`, `STAGE_DIR`), `MARCH_FLAGS`, the compilers and the MPI
wrappers, and the libraries by their variables (`OPENBLAS_ROOT`, `FFTW_ROOT`,
`HEFFTE_ROOT`, ...).

**Why the recipe is here and not in the base image.** `apps/Dockerfile` copies
`apps/<app>/` from its own build context, so a fix to an app's build or its
extractor reaches the next app image without a base rebuild.

**What gets built** is not written here. Each cluster's
`sites/<site>/<cluster>.yaml` states in its `images:` block the OS, compilers,
MPI families and apps it runs, and the microarchitecture its app images are
built for, with each compiler's spelling of it:

```yaml
images:
  os: leap
  compilers: [oneapi, gcc14, nvhpc]
  mpi: [mpich, openmpi]
  apps: [hpcg]
  target: znver3
  march: {default: -march=znver3, nvhpc: -tp=zen3}
```

`apps/matrix.py derecho --table` shows what that means; the workflow
[app-image-builder-ghcr.yaml](../.github/workflows/app-image-builder-ghcr.yaml)
builds exactly that list, and `make derecho-hpcg` in `sif/` pulls exactly that
list. The target is in every app image's tag and `.sif` name --
`leap-oneapi-mpich-hpcg-znver3` -- because one tag must mean one build.

**What an app image says about itself.** The workflow labels each image
`hpcdev.app`, `hpcdev.app.version`, `hpcdev.app.yaml.sha256`, `hpcdev.os`,
`hpcdev.compiler`, `hpcdev.mpi`, `hpcdev.target` and `hpcdev.march`. `apptainer
build` carries them into the `.sif`, and hpcrun's launcher reads the compiler
and MPI family from them before it falls back to the file name.

**Trying a change without CI.** `build.sh` runs inside any base `.sif`:

```bash
apptainer exec --cleanenv --writable-tmpfs --bind "$(mktemp -d):/tmp" \
    --bind "$PWD:/src:ro" sif/leap-gcc14-openmpi.sif \
    bash -lc 'cp -r /src/apps/hpcg /tmp/hpcg && HPCG_RUN=1 /tmp/hpcg/build.sh'
```

The private `/tmp` is not optional: apptainer binds the host's `/tmp` by
default, the build stages its sources there (`STAGE_DIR`), and `apps/Dockerfile`
empties it after the build.

and `smoke.sh` inside any image that carries the app:

```bash
apptainer exec --cleanenv --bind "$PWD:/src" sif/leap-gcc14-openmpi-hpcg-znver3.sif \
    bash -lc '/src/apps/smoke.sh hpcg'
```

`--cleanenv` matters on a cluster login node: the host's compiler and MPI
modules otherwise reach the container's wrappers.
