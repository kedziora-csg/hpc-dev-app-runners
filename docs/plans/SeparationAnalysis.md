# Separation Analysis: Container Factory and App Runners

## Executive Summary

Yes, the separation of concerns makes sense, but I would not make the first move a hard repository split. The best immediate move is to make HPCG a first-class app workload built by an app-runner layer on top of the factory image, then use that app image for `Placement_derecho_opt.pbs`. That keeps HPCG out of the core development-image Dockerfile while avoiding the current weak point: trying to build HPCG at PBS job time inside a likely read-only Apptainer SIF.

The current repository already has two concerns:

1. A container factory that builds compiler/MPI/GPU/scientific-library development images.
2. A set of scripts, workflows, and NCAR deployment assets that use those images to build or run applications and benchmarks.

Those concerns can live in one repository for now if they are named and wired clearly. A split into `hpc-dev-container-factory` and `hpc-dev-app-runners` becomes attractive once application workflows become their own release surface: published app images, benchmark result artifacts, app-specific issue triage, and cluster-run automation that changes independently from the base image factory.

## Facts From The Current Repository

`containers/devenv/Makefile` copies `scripts/` into the Docker build context as `extras/`. The base image therefore carries build recipes under `/container/extras`, including `build_hpcg.sh`.

`scripts/build_hpcg.sh` already builds HPCG 3.1, patches the OpenMP `default(none)` issue, probes the compiler's OpenMP flag, installs to `${INSTALL_ROOT}/hpcg/${HPCG_VERSION}`, and symlinks `${INSTALL_ROOT}/bin/xhpcg`. Since `scripts/build_common.cfg` defaults `INSTALL_ROOT=/container`, the normal in-image install target is `/container/bin/xhpcg`.

`containers/deploy/ncar-hpc/PBS/Placement_derecho_opt.pbs` already has `APP=hpcg` support. If `/container/bin/xhpcg` does not exist, it runs:

```bash
HPCG_RUN=0 /container/extras/build_hpcg.sh
```

inside the container before the placement sweep. It then writes a local `hpcg.dat` per placement configuration and records wall time and HPCG GFLOP/s.

The generated Derecho launcher in `containers/deploy/ncar-hpc/libexec/make_apptainer_launcher.sh` uses `apptainer exec` with host binds and MPI library injection, but it does not add `--writable-tmpfs`, an overlay, or a writable bind over `/container`. That means the current fallback build in `Placement_derecho_opt.pbs` is fragile for `.sif` images: a SIF is normally read-only, while the build script defaults to installing under `/container`.

The repository is not completely ignoring app automation. `.github/workflows/matrix-smoketest-applications.yaml` and the `apps-matrix` job in `.github/workflows/devel-build-images.yaml` run application build scripts inside factory images. However, they currently cover DART, WRF, MPAS, ESMF, and Kokkos, not HPCG, and those steps are largely smoke tests with `continue-on-error: true`.

The reusable factory workflow also has two useful hooks:

- `containers/test/Dockerfile` has `ARG TEST_SCRIPTS`, defaulting to OSU micro-benchmarks.
- `containers/publish/Dockerfile` has `ARG DEPLOYMENT_SCRIPTS`, also defaulting to OSU micro-benchmarks.

Those hooks show the intended pattern: build optional payloads on top of a completed factory image, rather than baking every application into `containers/devenv/Dockerfile`.

## Best Way To Build HPCG For `Placement_derecho_opt.pbs`

Do not add HPCG to the main `containers/devenv/Dockerfile` final stage. That would turn an application benchmark into part of the base development environment and would couple the factory release cadence to an optional workload.

Instead, build HPCG in a derived app/test/publish layer whose `BASE_IMAGE` is a factory image. The resulting image should already contain `/container/bin/xhpcg`, so `Placement_derecho_opt.pbs` can run `APP=hpcg` without attempting a runtime build on Derecho.

The lowest-friction implementation in this repository is:

1. Add an HPCG test step to the reusable image workflow or a dedicated app workflow:

```bash
docker run --rm --env-file test_env.cfg \
  --env HPCG_RUN=1 \
  --env NRANKS=2 \
  $CI_TAG \
  /container/extras/build_hpcg.sh
```

2. Add an app-image build path that uses the existing `containers/publish/Dockerfile` or a small new app-layer Dockerfile with:

```text
DEPLOYMENT_SCRIPTS=/container/extras/build_hpcg.sh
```

and `HPCG_RUN=0` during image construction.

3. Publish or tag that derived image distinctly from the base factory image, for example:

```text
ghcr.io/<org>/hpcdev-apps-x86_64:leap-oneapi-mpich-hpcg-latest
```

or, if keeping one image family, use a clear suffix:

```text
ghcr.io/<org>/hpcdev-x86_64:leap-oneapi-mpich-hpcg-latest
```

4. Build the `.sif` from the HPCG-bearing image, not from the plain factory image.

5. Run:

```bash
./submit_placement_matrix.sh --account <PROJECT> --app hpcg
```

The important behavioral contract is simple: by the time the PBS job starts, `test -x /container/bin/xhpcg` should pass inside the SIF. The PBS script's runtime fallback can remain as a convenience, but it should not be the normal path for benchmark runs.

If runtime building remains useful for development, make it explicitly writable rather than relying on `/container`:

```bash
INSTALL_ROOT=${RESULTS_DIR}/hpcg-install
STAGE_DIR=${RESULTS_DIR}/hpcg-stage
HPCG_RUN=0 /container/extras/build_hpcg.sh
```

Then run `${INSTALL_ROOT}/bin/xhpcg`. That is useful for debugging but weaker for reproducibility because the benchmark binary is created during a billable cluster job instead of being built, tagged, and inspected before submission.

## What `extras` Should Mean

The name `extras` is not quite the same as "unsupported." In this repository it means "recipes copied into the image so they can be run after the core toolchain exists." The workflows already use those recipes for OSU, report placement, DART, and Kokkos.

However, the name does signal second-class ownership. It is not obvious which scripts are required factory validation, which are examples, which are app benchmarks, and which are production payloads. A cleaner naming model would be:

```text
scripts/factory-tests/       report_placement, OSU, hello-world checks
scripts/app-builds/          hpcg, wrf, cesm, esmf, petsc, dart, mpas, kokkos
scripts/shared/              build_common.cfg and reusable helpers
```

Inside the image, the paths could remain compatible by copying them to `/container/extras`, but the source tree would make ownership clearer.

## Review Of `SeparateConcerns.md`

`SeparateConcerns.md` is directionally right: factory images and arbitrary application runners are different products with different users, release cadences, and CI shapes. The central recommendation, that application builds should not be hidden inside the factory image build, is sound.

The strongest parts of that document are:

- It identifies the two real responsibilities: producing base HPC development images versus using those images to build and run workloads.
- It recognizes that HPCG, WRF, CESM, MPAS, and similar workloads deserve first-class workflows if they are going to be trusted.
- It argues correctly that the factory should expose a stable image contract rather than carry every application as part of the core stack.
- It points toward matrix-driven app builds on top of published factory images, which is exactly the right pattern for HPCG.

The places I would revise are:

- It says apps are "not currently part of the GHA matrix." That is no longer fully accurate. `matrix-smoketest-applications.yaml` and `devel-build-images.yaml` already contain app matrices, although not for HPCG and not as strict release gates.
- It treats `/container/extras` as evidence that the factory does not support app automation. The actual implementation is more nuanced: `extras` are copied into the image and are invoked by test and publish workflows. The problem is naming and policy clarity, not total absence of support.
- It recommends a repository split too early. A split helps only after the image contract and app-runner contract are explicit. Without that, a split just moves ambiguity across two repositories.
- It assumes a git submodule should be central. An app-runner repo can often consume published image tags without a factory submodule. A submodule is useful if the app-runner needs source-controlled deploy scripts, local Dockerfiles, or unreleased factory changes, but it should not be required for normal benchmark runs.
- It says to keep `containers/deploy/ncar-hpc/` wholly in the factory. That is mostly right for host-MPI, Apptainer, and image deployment mechanics, but `Placement_derecho_opt.pbs` with `APP=hpcg` is half deployment validation and half application benchmark harness. If repos split, the shared launcher and ABI-shim logic can stay in the factory while app-specific PBS wrappers or benchmark workflows move to app-runners.

My revision to the recommendation would be: separate concerns immediately in naming, workflow boundaries, and artifact tags; split repositories once app workflows become a maintained product rather than validation examples.

## Should There Be Two Repositories?

Eventually, yes, if the goal is to maintain a reusable application runner framework. The two-repo model makes sense when all of the following are true:

- HPCG and other apps have their own CI status, expected results, and issue ownership.
- App workflows publish artifacts, benchmark summaries, or app-bearing images.
- App changes are frequent enough that they should not trigger factory image reviews.
- Factory changes need downstream app qualification without putting app logic into the factory Dockerfile.
- External users should be able to use the factory without inheriting NCAR-specific or app-specific harnesses.

If the current purpose is narrower, namely "prove that factory images can build representative apps," then a single repo with clearer directories and workflows is enough.

## Recommended Repository Boundary

### `hpc-dev-container-factory`

Owns the base images and their contract.

Keep:

- `containers/devenv/Dockerfile`
- `containers/test/Dockerfile`
- `containers/publish/Dockerfile`
- `.github/workflows/build-hpc-development-image.yaml`
- `.github/workflows/matrix-build-images.yaml`
- `.github/workflows/devel-build-images.yaml` for image validation
- minimal image smoke tests: hello-world, `report_cpu_features`, `report_placement`, OSU if it remains a factory-level MPI sanity check
- `containers/deploy/ncar-hpc/libexec/make_apptainer_launcher.sh` and the host-MPI/Apptainer ABI-shim machinery, if this repo is meant to certify images for NCAR systems

Document the image contract:

- `/container/config_env.sh` is sourced by login shells.
- `/container/bin` is on `PATH`.
- compiler wrappers and `CC`, `CXX`, `FC`, `MPICC`, `MPICXX`, or equivalent variables are stable.
- `MARCH_FLAGS` is compiler-appropriate.
- `INSTALL_ROOT=/container` is the in-image installation convention.
- `/container/extras` is compatibility space for optional recipes, not the primary app API.

### `hpc-dev-app-runners`

Owns application build and run automation.

Move or copy:

- `scripts/build_hpcg.sh`
- `scripts/build_wrf.sh`
- `scripts/build_cesm.sh`
- `scripts/build_esmf.sh`
- `scripts/build_petsc.sh`
- `scripts/build_dart.sh`
- `scripts/build_mpas.sh`
- `scripts/build_kokkos.sh`
- `scripts/build_fasteddy.sh`
- app-specific PBS wrappers and benchmark result collation

Organize as:

```text
apps/
  hpcg/
    build.sh
    run.sh
    hpcg.dat.template
    workflows.md
  wrf/
    build.sh
    run-smoke.sh
  kokkos/
    build.sh
shared/
  build_common.cfg
  app_image.Dockerfile
.github/workflows/
  build-hpcg-image.yaml
  smoke-apps.yaml
  derecho-hpcg-placement.yaml
```

The app-runner should consume factory images by tag or digest. A factory git submodule is optional. Use it when the runner needs source files from the factory, for example the NCAR launcher scripts or an unreleased Dockerfile. For normal CI, image tags are a cleaner interface than submodules.

## What A Split Would Entail

### Phase 0: Clarify Contracts In This Repo

Before moving files, make the boundaries explicit:

1. Decide which scripts are factory validation and which are app builds.
2. Add `build_hpcg.sh` to a dedicated app workflow or app-layer image build.
3. Stop relying on PBS-time installation into `/container` for HPCG.
4. Document the image contract in the README.
5. Add artifact naming rules for base images versus app-bearing images.

This phase can be done without a repository split and gives immediate value.

### Phase 1: Rename Or Re-home The Factory

Create or rename the factory repo as `hpc-dev-container-factory`.

Tasks:

1. Keep factory workflows and Dockerfiles.
2. Keep only scripts required to validate the image contract.
3. Move app build scripts to a temporary `deprecated-app-scripts/` directory or leave forwarding wrappers for one release.
4. Update README and `CLAUDE.md` to say the deliverable is a family of development images.
5. Tag the last combined state so old workflows remain recoverable.
6. Publish images with stable tags and, ideally, immutable digest references for app-runner use.

### Phase 2: Create `hpc-dev-app-runners`

Tasks:

1. Import app scripts into `apps/<app>/build.sh` and `apps/<app>/run.sh`.
2. Add a generic app image Dockerfile:

```dockerfile
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
COPY apps /app-runner/apps
COPY shared /app-runner/shared
SHELL ["/bin/bash", "--login", "-c"]
ARG APP
RUN /app-runner/apps/${APP}/build.sh
```

3. Add an HPCG workflow that builds on the blessed Derecho factory image set: `leap x {oneapi,gcc14,nvhpc} x {mpich,openmpi}`.
4. Publish app-bearing images or upload app binaries as workflow artifacts.
5. Add a Derecho run workflow or documented manual sequence that builds SIFs from the app-bearing images and calls `submit_placement_matrix.sh --app hpcg`.

### Phase 3: Connect The Repositories

Use one or more of these integration points:

- Factory release triggers app-runner validation through `workflow_dispatch` or `repository_dispatch`.
- App-runner workflows accept a factory image tag or digest as an input.
- Factory PRs can optionally run a downstream app qualification workflow against temporary `gh-ci` images.
- App-runner pins tested factory versions in a manifest file.

A submodule can be added if app-runner needs exact factory source context, but it should not be the main dependency path. Published images are the product boundary.

## Proposed HPCG Automation Plan

### Short Term

1. Add a strict HPCG smoke-build step to the existing app matrix or reusable test path.
2. Build HPCG with `HPCG_RUN=1` in CI using a tiny problem size, so compile, MPI launch, OpenMP, and validation are checked.
3. Build an HPCG-bearing derived image with `HPCG_RUN=0` for the Derecho benchmark path.
4. Build `.sif` files from that derived image set.
5. Run `Placement_derecho_opt.pbs` with `APP=hpcg` and confirm the script sees `/container/bin/xhpcg` without invoking the fallback build.

### Medium Term

1. Rename `matrix-smoketest-applications.yaml` to something explicit, such as `matrix-build-apps.yaml`.
2. Remove `continue-on-error: true` for HPCG once the supported matrix is known.
3. Add result artifacts: `timings.txt`, `placement_*.out`, `HPCG-Benchmark*.txt`, and collated CSV.
4. Add a manifest that states which factory images are qualified for each app.
5. Split app workflows into a separate repo if app results become a published deliverable.

## Recommendation

For the immediate HPCG goal, keep the factory image clean and build HPCG in a derived app image. Do not rely on `Placement_derecho_opt.pbs` to build `/container/bin/xhpcg` at runtime inside a SIF.

For repository structure, separate concerns now but split repositories later. Start by making the boundary visible in the current repo: factory images, factory validation, app builds, and NCAR deployment should have distinct directories, workflow names, and artifact names. Once HPCG and the other apps have their own maintained workflows and outputs, move them into `hpc-dev-app-runners` and let that repo consume `hpc-dev-container-factory` through published image tags or digests, with a submodule only where source-level coupling is genuinely useful.