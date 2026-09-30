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

**Why the recipe is here and not in the base image.** The app layer used to run
`/container/extras/build_hpcg.sh` out of the base image, so it built whichever
recipe was current when the base was built: a fix to HPCG's extractor needed a
base rebuild before it reached an app image. Now `apps/Dockerfile` copies
`apps/<app>/` from its own build context. From the base it relies only on its
contract: `/container/config_env.sh`, `/container/extras/build_common.cfg`, the
compilers and the MPI wrappers.

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
default, the build stages its sources there, and the base images'
`docker-clean` -- which `apps/Dockerfile` runs after the build -- empties it.

and `smoke.sh` inside any image that carries the app:

```bash
apptainer exec --cleanenv --bind "$PWD:/src" sif/leap-gcc14-openmpi-hpcg-znver3.sif \
    bash -lc '/src/apps/smoke.sh hpcg'
```

`--cleanenv` matters on a cluster login node: the host's compiler and MPI
modules otherwise reach the container's wrappers.
