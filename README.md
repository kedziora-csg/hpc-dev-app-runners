# HPC Dev App Runners

> **Source and licence.** This is the runner half of
> [kedziora-csg/demo_github_actions](https://github.com/kedziora-csg/demo_github_actions),
> itself a fork of [benkirk/demo_github_actions](https://github.com/benkirk/demo_github_actions)
> by Benjamin S. Kirk, whose NCAR deployment scripts it grew from. It is
> distributed, as the original is, under the Creative Commons
> Attribution-ShareAlike 4.0 International licence ([LICENSE.md](LICENSE.md)).
> The history is kept. The other half, the container factory, is
> [NCAR/hpc-dev-container-factory](https://github.com/NCAR/hpc-dev-container-factory).
> This repository is to move to the NCAR organisation as well, once its
> Actions are approved there.

This repository takes the portable HPC base images that
[NCAR/hpc-dev-container-factory](https://github.com/NCAR/hpc-dev-container-factory)
publishes and makes them run, and measure, on real clusters:

1. **It builds apps for each machine.** Each cluster's description says which
   operating system, compilers, MPI families and apps it runs, and which CPU
   its app images are built for. A workflow builds those apps on the
   factory's base images and publishes them as app images, with the CPU
   target in every tag: `leap-gcc14-openmpi-hpcg-znver3`.
2. **It delivers them.** On a cluster's login node, `make` in `sif/` turns the
   cluster's images into `.sif` files pinned to the digest they came from.
3. **It runs them.** `hpcrun/` submits a declared experiment to the
   scheduler, runs each cell inside the container with the host's MPI put in
   place of the image's, checks where every rank and thread landed, and writes
   one results record per run that names the exact image it measured.
4. **It describes the machines.** Everything the three steps above need to
   know about a machine -- its node types, scheduler, modules, host MPI, and
   image set -- is stated once, in `sites/`, and read by all three.

## Two contracts

The repository sits between two interfaces, and depends on nothing else:

| Contract | Defined in | Who keeps it | Who relies on it |
|---|---|---|---|
| **The base contract**: tag format, `/container/config_env.sh`, `build_common.cfg`, `MARCH_FLAGS`, the compiler and MPI wrappers, `report_placement`, `report_cpu_features`, OSU, OpenBLAS, FFTW | [factory `CONTRACT.md`](https://github.com/NCAR/hpc-dev-container-factory/blob/main/CONTRACT.md) | every factory image, checked by its `check_base_contract.sh` | `apps/` builds on it; `hpcrun/` runs `report_placement` and `report_cpu_features` from it |
| **The app contract**: `/container/app.d/<app>/` with `app.yaml` and the `prepare`, `launch` and `extract` hooks | [APP_CONTRACT.md](APP_CONTRACT.md) | every app image built here, and OSU in every base image | `hpcrun/`, which never learns an app's name |

The app workflow runs the factory's own contract check inside every app image
it publishes, and `make -C hpcrun test` holds a copy of OSU's contract
([hpcrun/tests/fixtures/app.d/osu/](hpcrun/tests/fixtures/app.d/osu/)) to the
runner. A change on either side that breaks the other shows up there.

## Layout

```
apps/       the apps built on the base images, one directory each, and the
            workflow's view of what to build (matrix.py) and how to smoke-test it
sif/        delivery: one Deffile template and the Makefile that pins and builds .sif files
hpcrun/     the runner: submit, validate, collect, runner.sh, sitegen, clusterinit;
            lib/ (launcher, placement checker, topology probe, provenance, results),
            schema/, templates/, tests/, and the experiments
sites/      machine descriptions: sites/<site>.yaml, sites/<site>/<cluster>.yaml,
            and each cluster's generated cluster.sh and images.mk
docs/plans/ the design record (see docs/plans/README.md)
```

## Using it

On a cluster, after cloning:

```bash
. hpcrun/env.sh                          # validate, submit, collect, sitegen on PATH
cd sif && make derecho-hpcg              # the cluster's HPCG .sif files, digest-pinned
make check-images                        # is every .sif current against the registry?
apptainer exec leap-gcc14-mpich.sif /container/extras/check_base_contract.sh --published
cd $SCRATCH/runs && submit derecho-hpcg --account <PROJECT>
collect ./derecho-hpcg --best
```

[sites/ncar/README.md](sites/ncar/README.md) is the operator's guide for
Derecho and Casper, and [sites/README.md](sites/README.md), "Adding a cluster",
is how a new machine is described: `hpcrun/clusterinit draft`, a probe job,
then `hpcrun/sitegen <cluster> --write`.

## Building app images

[.github/workflows/app-image-builder-ghcr.yaml](.github/workflows/app-image-builder-ghcr.yaml),
dispatched by hand for one cluster:

```bash
gh workflow run app-image-builder-ghcr.yaml -f cluster=derecho
```

It builds every app image the cluster's `images:` block names, on
`ghcr.io/ncar/hpcdev-x86_64`, publishes them to
`ghcr.io/<owner>/hpcdev-apps-x86_64`, checks the base contract in each, and
runs each app once through its contract at smoke scale. The inputs can narrow
the list but not widen it, so what the workflow publishes is exactly what
`make <cluster>-<app>` pulls. `apps/matrix.py <cluster> --table` prints the
list without dispatching anything.

Adding an app is a directory, `apps/<app>/`, with a `build.sh` and its
contract in `app.d/` ([apps/README.md](apps/README.md)), and the app's name in
a cluster's `images.apps`. Nothing in `hpcrun/` changes.

## Testing

```bash
make -C hpcrun test
```

runs the off-cluster suite: no scheduler, no container, no image. It runs on
every pull request ([hpcrun-tests.yaml](.github/workflows/hpcrun-tests.yaml)).
