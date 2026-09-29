# Addendum: Laying Out the Repository by Concern

Status: **proposed 2026-09-25; nothing has been moved.** This is phase 4.7 of
`BenchmarkRunnerPlan.md`, summarised in §10 of that file. It answers the plan's
§11.1 ("does `bench/` belong under `containers/deploy/` at all?"), replaces the
target layout in §8, and changes the paths that §9 assumes. Six decisions were
open, numbered after the plan's four (§10 below). **Three were answered on
2026-09-29:** upstream is no longer a constraint (5), OSU's contract stays with
the factory (6), and the runner's directory is `hpcrun/` (7). The same day, the
factory itself was given a new home, `NCAR/hpc-dev-container-factory`
(`ImagePublishingPlan.md`, option D). So `containers/` and `scripts/` leave this
repository rather than being rearranged inside it.

Every path, count and line number here was read from `main` at `0391aa5`. The
off-cluster suites pass at that commit -- 184 checks, run by
`cd containers/deploy/ncar-hpc/libexec && make test` -- and every step below
must end with the same 184 passing.

---

## 1. The question, and why it is worth answering now

`containers/deploy/ncar-hpc/` sits beside `containers/deploy/sites/` because of
history, not design. Upstream created `ncar-hpc/` as a folder of NCAR job
scripts and image recipes: nine files, listed in §9. The fork then grew the
benchmark harness inside it, one phase at a time. The placement checker, the
launcher and the app contract went into `ncar-hpc/libexec/` (phases 0-2),
`bench/` was added beside it (phase 3), and `sites/` beside that (phase 4).
Each phase deliberately avoided renames -- phase 0's row in §10 says "no
renames, no new files outside `libexec/`" -- and that was right for each
phase, because a change that moves files and edits them at the same time is
hard to review. But no phase owned the layout as a whole, and the result is:

- a directory named for a site whose contents are mostly not site-specific;
- a runner that finds its own libraries through a variable named for that
  site, `NCAR_HPC_ROOT`;
- a directory of machine descriptions beside both, which also holds one file
  that is not a machine description (`job.pbspro.tmpl`);
- and, on the build side, app recipes kept in the factory's `scripts/`
  directory and shipped inside every factory image.

Two pieces of work come next, and both make this more expensive to fix later.

- **Sub-clusters** (the second half of phase 4.5) edit `sites/*.yaml`,
  `bench/benchlib/sitefile.py` and `bench/schema/cluster.json`. Doing that at
  the final paths means doing it once.
- **TACC** (phase 4.6) is the point at which the names stop being awkward and
  become false. A job at TACC would load its launcher from
  `containers/deploy/ncar-hpc/libexec/` through `NCAR_HPC_ROOT`, and a
  `sites/tacc/` directory would sit beside a directory called `ncar-hpc` that
  every TACC job depends on.

---

## 2. The concerns

The plan's §3 names three tiers: the base image factory, the site image
builder, and the HPC runner. Deciding where files go needs two more
distinctions.

| Concern | The question it answers | Runs | Produces | Changes when |
|---|---|---|---|---|
| **Base image factory** | Is there a correct, portable toolchain and library stack for this compiler, MPI and OS? | GitHub CI | `hpcdev-<arch>` images | a compiler, MPI or library version moves |
| **Machine-targeted image builder** | Is there an image of this app, built well for this kind of node? | GitHub CI | `hpcdev-derecho-<arch>`, `hpcdev-apps-<arch>` | an app changes, or a new target is added |
| **Delivery** (image to SIF) | Is there an immutable file on this cluster that names the image it came from? | a cluster login node | `.sif` files pinned to a digest | rarely: which images to build comes from the machine description |
| **HPC runner** | Which configuration is fastest, and did it run as intended? | a cluster login node and its compute nodes | results directories | a new scheduler or a new instrument -- never because one machine changed |
| **Machine descriptions** | What is this machine, and how is its scheduler asked for it? | read by the other four | the generated block in `cluster.sh`; later, image sets and build flags | the machine changes |

SIF is the Singularity Image Format that Apptainer runs; CI is continuous
integration; GHCR, below, is the GitHub Container Registry.

**The middle tier has two parts, and only one of them is a layer.** You
described it as "an architecture-dependent container with installed app and
architecture-dependent prerequisites", and that is exactly this tier.

The app is a layer: `containers/apps/hpcg/Dockerfile` starts `FROM` a finished
base image and adds to it.

The tuned prerequisites are not a layer. `derecho-images-ghcr.yaml` calls
`build-hpc-dev-image-ghcr.yaml`, the fork's copy of upstream's reusable build
workflow, which builds `containers/devenv/Dockerfile` from its first stage with
`MARCH_FLAGS=-march=znver3` (`-tp=zen3` for nvhpc). The result is a sibling of
the portable image, not a descendant of it. It shares no layers with the
portable image, and even its registry cache is separate
(`hpcdev-derecho-x86_64-cache`, because the cache is named after the
repository an image is published to).

It cannot be a layer, for the reason §3 of the plan gives about layers in
general: a layer can add files but cannot replace what is below it. The
microarchitecture has to reach the MPI and every library built after the
`compilers` stage (`Dockerfile:1005`) -- HDF5, NetCDF, PnetCDF, ParallelIO,
FFTW and HeFFTe -- and those can only be rebuilt, not changed from above. The
one thing that can be tuned as a layer is the application itself, and that is
what `APP_MARCH_FLAGS` in the app Dockerfile does.

So the boundary between the factory and the tuned prerequisites is not in any
Dockerfile. The factory owns the Dockerfile and the reusable workflow, and
offers `MARCH_FLAGS` as a setting. Upstream's Dockerfile had that setting for
nvhpc only; the fork extended it to every compiler family. The middle tier owns
the workflow that chooses the setting's value, the set of images to build with
it, and the repository the results are published to. That is the right design:
the factory offers one setting, and the tier above decides its value.

**Delivery is separate from both of its neighbours.** Its logic is generic:
resolve a tag to a digest, write it into a definition file, build a `.sif`.
But it runs at the site, in the site's module environment, and only the
cluster knows which images it needs. The plan's §3 already notes that
converting to a SIF is not another layer but a flattening of all of them. It
needs its own directory, and it needs two things from the machine description:
which images to build, and how to set up Apptainer on that machine.

**The ownership rule needs one refinement.** §3 says "a thing belongs to the
tier that would have to change if the machine changed". Applied as written, it
puts the microarchitecture in the image builder and the bind list in the
runner, and then two tiers each state facts about the same machine. The runner
side stopped doing that in phase 4: the facts live in `sites/`, and the runner
reads a block generated from them. The refinement is to require the same of
every tier:

> **A fact about a machine is stated once, in the machine's description.
> Every other concern reads it and never restates it.**

The build side does not follow this yet (finding F2).

---

## 3. The interfaces between the concerns

A directory layout makes an interface visible; it does not create one. What
matters is what each concern may rely on from the others, where that is
written down, and what checks it. Five things cross a boundary.

| | From → to | What crosses | Stated in | Checked by | State |
|---|---|---|---|---|---|
| **I1** | factory → image builder | the base image contract: the name `hpcdev[-<target>]-<arch>:<os>-<compiler>-<mpi>-<version>`; `/container/config_env.sh`, sourced by every login shell; `/container/extras/build_common.cfg` (`INSTALL_ROOT`, `STAGE_DIR`); the `MARCH_FLAGS` build argument and the variable of that name inside the image; `CC`, `CXX`, `FC` and the MPI wrappers; `report_placement`, `report_cpu_features`, and OSU under `/container/osu-micro-benchmarks/` | nowhere in one place; `SeparationAnalysis.md` lists most of it | the smoke tests in `containers/test/Dockerfile`, indirectly | implicit |
| **I2** | machine descriptions → image builder | the target microarchitecture and how each compiler family spells it; which OS matches the host; which compilers have host modules; which MPI families the host can substitute -- and therefore which images are worth building | copied by hand into `derecho-images-ghcr.yaml` (header and matrix), `hpcg-smoketest-ghcr.yaml` (default matrix) and `libexec/Makefile` (`derecho_images`, `casper_images`) | nothing at build time; `check_arch` at job start, and only for a binary built too wide | copied four times, and the copies disagree |
| **I3** | image builder → delivery → runner | `/container/app.d/<app>/` (`bench/schema/app.json`); `built_with_march` in the installed `app.yaml`; the SIF labels `org.opencontainers.image.base.{name,digest}` and `io.ncar.hpcdev.image_tag`; and the `.sif` **file name**, from which the runner infers the compiler and MPI family | `scripts/app.d/README.md`, `bench/schema/app.json`, the `%labels` block of both Deffiles | `bench/validate` (contract present), `make check-images` (digest current), `test_app_contract.sh` | mostly good; the dependence on the file name is fragile (F5) |
| **I4** | machine descriptions → runner | the generated block in `sites/<site>/<cluster>/cluster.sh` -- plain shell variables and `bench_site_*` functions -- and one job template per scheduler | `bench/schema/cluster.json`, `bench/benchlib/sitefile.py` | `sitegen --check` inside `test_bench.sh`; `test_cluster.sh` against a synthetic profile | good |
| **I5** | runner → reader | a self-contained results directory: `results.jsonl` (results schema 2), `run.meta`, `topology.json` and the other files listed in §7 of the plan | plan §7 | `test_results.sh`, `bench/collect` | good |

I4 and I5 are the best-defined interfaces in the repository, and they are the
two that were designed on purpose. I1 and I2 were never designed; they
accumulated. Most of the findings below are places where I1 or I2 is crossed
without being named.

What each weak interface should become:

- **I1: one short document,** `CONTRACT.md`, stating what a base image
  promises to anything built on top of it. It belongs in the factory's new
  repository, `NCAR/hpc-dev-container-factory`, where it becomes the contract
  between two repositories (`ImagePublishingPlan.md` §4). It includes
  `report_placement` and OSU with its contract: MPI-level tools that every
  container run on a cluster depends on, and so part of the base, not app
  content.
- **I2: read, not copied.** The machine description gains the image set and
  the build flags per node type, and the workflows and the delivery `Makefile`
  read them (step 4.7c and phase 5, §8).
- **I3: labels, not file names.** The runner reads the compiler, MPI family and
  target from labels that the delivery step writes, and uses the file name only
  when a label is absent (phase 5).

---

## 4. Findings

In order of consequence. Each says what is wrong, where, and what it costs.

### F1. App recipes ride inside the base image

`containers/devenv/Makefile:6-9` copies all of `scripts/` into the factory's
build context as `extras/`, so every factory image carries
`/container/extras/build_hpcg.sh` and `/container/extras/app.d/`.
`containers/apps/hpcg/Dockerfile` copies nothing from its own build context:
its `RUN` (line 36) executes `/container/extras/build_hpcg.sh` out of the base
image, and `build_hpcg.sh:226-227` installs the contract from
`/container/extras/app.d/hpcg` when there is no copy beside the script.

So the app layer is built from **the recipe that was current when the base
image was built**, not from the commit that started the app build. A fix to
`scripts/app.d/hpcg/extract`, or to `build_hpcg.sh` itself, reaches an app
image only after the six Derecho base images have been rebuilt by
`derecho-images-ghcr.yaml`, and then the six app images by
`hpcg-smoketest-ghcr.yaml`. Until then the app build uses the old recipe, and
nothing reports that the recipe inside the image differs from the one in the
repository. `BENCH_APP_DIR` works around this at run time for the contract,
but not for the build script.

This is the one finding that is a working defect rather than a naming problem.
It does not depend on which base the app is built on. The app layer's default
base is `hpcdev-derecho`, the tuned prerequisites, not the portable factory
image. But both are built by the same Dockerfile after the same `make extras`
step (`build-hpc-dev-image-ghcr.yaml:133-137`), so every base image carries
`scripts/` as it was when that base was built. The mixing of concerns is that
the app layer's recipe is carried inside its base image, whichever base that
is, instead of in the app layer's own build context.

### F2. The machine-targeting facts are copied, and the copies disagree

Four places state which images Derecho and Casper need, or what they are built
for.

| Where | What it says |
|---|---|
| `derecho-images-ghcr.yaml:3-20` (header) and its matrix | leap × {oneapi, gcc14, nvhpc} × {mpich, openmpi}, built `-march=znver3` / `-tp=zen3`; and, at line 17, "Casper uses the almalinux9 set" |
| `hpcg-smoketest-ghcr.yaml:73-76` | the same six combinations, as its default matrix |
| `libexec/Makefile:30-36` and `:52-54` | `derecho_images` (the six) and `casper_images` (the three leap openmpi images) |
| `sites/ncar/derecho.yaml:56`, `sites/ncar/casper.yaml:86` | `target_arch: x86-64-v3` and `x86-64-v4`, as a run-time check |

Line 17 of the workflow is true of one consumer and false of the other. It
describes the legacy `OSU_casper.pbs`, whose default image is
`almalinux9-gcc14-openmpi-cuda.sif`. The benchmark harness on Casper uses
`casper_images`, which are Derecho's Zen 3 builds, and every Casper benchmark
run so far used them. Nothing compares the files, so nothing noticed.

The same finding has a second half, in the image names.
`hpcg-smoketest-ghcr.yaml` publishes every app image, by default, to
`hpcdev-apps-<arch>` with the tag `<os>-<compiler>-<mpi>-hpcg-latest`
(lines 93-95), whatever base repository it was built from and whatever
`app_march_flags` was set to. So one tag can mean "built on the portable base",
"built on the Zen 3 base", or "built on the Zen 3 base with the app tuned
further" -- whichever ran last. That is the collision §3 of the plan fixed for
base images by creating `hpcdev-derecho-<arch>` ("a different promise needs a
different repository"), and it is still open for app images.

### F3. The runner's libraries live under a site's name

Of the fifteen scripts in `ncar-hpc/libexec/`, nine mention none of NCAR,
Derecho, Casper, GLADE, Cray or PBS outside their comments: `app_contract`,
`check_arch`, `check_placement`, `placement_rules`, `probe_topology`,
`results`, `pin_image_digest`, `self_test` and `test_rules`. Of the other six,
`make_apptainer_launcher.sh` holds the host-MPI recipes, which are specific to
Cray MPICH and Open MPI by design (phase 4, decision 5); `provenance.sh` queries
PBS, which phase 4.6 already lists; `wrap_apptainer.sh` binds `/glade` and
belongs to delivery; and three test scripts use site names in their test data.
The runner reaches all of them through `NCAR_HPC_ROOT` (`bench/runner.sh:73`
and `:166`), which appears 52 times across twelve files, not counting
documents.

The places where a site's name is written into code that should not know it:

| Where | What | Fix |
|---|---|---|
| `make_apptainer_launcher.sh:345-350` | the `host-openmpi` recipe reads `NCAR_ROOT_OPENMPI`, which NCAR's modules set | the cluster description states the root. It already names the same variable for the library path (`casper.yaml:101`: `${NCAR_ROOT_OPENMPI}/lib`), so today the fact is stated in the YAML and again in code |
| `runner.sh:181`, `provenance.sh:164` | fall back to `NCAR_HOST`, which NCAR's login environment sets | drop the fallback; `BENCH_CLUSTER` is always set since phase 4.5 |
| `runner.sh:195` | prints "falling back to built-in Derecho constants" | the message has been wrong since phase 4: the fallback is the profile's `node:` block (`probe_topology.sh:62`) |
| both Deffiles, line 27 | the label key `io.ncar.hpcdev.image_tag` | a key without a site name; nothing reads the label today (F5) |
| `bench/collect:72` | the default results root is `../ncar-hpc/results` | the profile's `BENCH_RESULTS_ROOT` |

None of these breaks anything at NCAR. Every one of them would be wrong at
TACC.

### F4. The runner reaches into the delivery directory

- `bench/benchlib/cluster.py:94-110` answers `images.from_make: derecho-hpcg`
  by running `make echo-derecho-hpcg` inside `libexec/`.
  `Placement_derecho.pbs:124` and `test_bench.sh:65` do the same.
- `libexec/Makefile:99-108` is the test driver for the whole harness,
  including `../../bench/test_bench.sh`.
- `sites/ncar/*/cluster.sh:245` defaults `BENCH_IMAGE_DIR` to
  `${NCAR_HPC_ROOT}/libexec`, so the multi-gigabyte `.sif` files are built in
  the same directory as the source code that consumes them.
- The hints printed on failure send the operator there too: `bench/submit:129`
  and `runner.sh:275` both say `cd libexec && make ...`.

The direction is the problem, not the coupling itself. The runner looks inside
the delivery step's source to learn what a cluster needs, when both should read
it from the cluster's description.

### F5. The runner learns an image's identity from its file name

`_launcher_sniff_family` and `_launcher_sniff_compiler`
(`make_apptainer_launcher.sh:164-190`) decide the MPI family -- and therefore
which host-MPI recipe is applied -- by matching `*mpich3*`, `*mpich*` and
`*openmpi*` in the `.sif` file name. When no pattern matches, they use whatever
MPI module the host happens to have loaded. Renaming a file, or naming an image
in a way the patterns did not anticipate, changes which libraries are injected
into the container. The delivery step already writes `io.ncar.hpcdev.image_tag`
into every SIF, and nothing reads it.

### F6. The scheduler template is filed with the machine descriptions

`sites/job.pbspro.tmpl` belongs to the runner -- the docstring of
`template_for` in `bench/submit` says "the template belongs to the harness" --
but it sits in `sites/`, which otherwise holds only descriptions of machines.
The Slurm template of phase 4.6 would land beside it.

### F7. The repository root is crowded

Seven planning documents and a PDF sit at the root beside `README.md`:
`BenchmarkRunnerPlan.md` and its `.pdf`, `DockerfileDoc.md`, `README_old.md`,
`SeparateConcerns.md`, `SeparationAnalysis.md`, `UpstreamPRPlan.md`, and now
this addendum. Separately, `src/` is a byte-for-byte copy of six files in
`scripts/`; it is upstream's. This finding has little consequence, and it is
deliberately left out of the steps below (DECISION 10).

---

## 5. Corrections to the first proposal

The layout was first sketched in conversation on 2026-09-25. Reading the code
more closely changed six things. They are recorded because each would have
been a defect in the move.

1. **`BENCH_ROOT` is already taken.** The sketch renamed `NCAR_HPC_ROOT` to
   `BENCH_ROOT`. But `BENCH_ROOT` already exists and means the `bench/`
   directory (`cluster.sh:251-252`, `job.pbspro.tmpl:57`). Once the libraries
   are under the runner's `lib/` (`hpcrun/lib/`), `BENCH_ROOT` locates them
   too, so `NCAR_HPC_ROOT` is not renamed but **removed** (DECISION 9).
2. **OSU is built by the factory.** The sketch moved `scripts/app.d/osu/` to
   `apps/osu/`. But the factory's publish stage builds OSU into every published
   image (`containers/publish/Dockerfile:8`,
   `DEPLOYMENT_SCRIPTS=/container/extras/build_osu-micro-benchmarks.sh`), and
   the contract is filled in with the OSU version at that moment
   (`@OMB_VERSION@`). With the contract moved out of `scripts/`,
   `build_osu-micro-benchmarks.sh` would silently skip it (it tests
   `[ -d "${app_src}" ]` at line 64), every image built afterwards would lack
   the OSU contract, and `derecho-osu.yaml` would stop working at its next
   image rebuild. This became DECISION 6.
3. **Delivery is not site-neutral.** The sketch put the whole SIF step in one
   generic directory. But the `%.sif` rule depends on `../config_env.sh`
   (`Makefile:165`), which runs `module load apptainer` and puts Apptainer's
   cache under `$WORK` -- NCAR's environment -- and the rule creates wrapper
   links in `../bin/` (line 180). The generic logic and the site's environment
   have to be separated (step 4.7a, and 4.7c for the choice of site).
4. **Counts.** There are nine upstream files in `ncar-hpc/`, not eight: the
   ninth is `.gitignore`. Nine of the fifteen `libexec/` scripts have no site
   reference, not eight. `NCAR_HPC_ROOT` has 52 references in code, not 61;
   the other nine are in documents.
5. **The two statements of Derecho's target are not entirely unchecked.**
   `check_arch` compares the binary with `target_arch` at job start. It catches
   a binary built too wide, which is the direction that crashes. It cannot
   catch one built too narrow, which is the direction that quietly loses
   performance.
6. **The profile search improves, not only changes.** The hand-submitted
   scripts search upward from `$PBS_O_WORKDIR` for
   `sites/*/<cluster>/cluster.sh`. Today that succeeds only from
   `containers/deploy/` or below it; from the repository root it fails. With
   `sites/` at the root, it succeeds from anywhere inside the checkout. Moving
   the scripts themselves changes nothing, because the search starts from where
   the job was submitted, not from where the script is stored.

---

## 6. Proposed layout

This repository, once the factory has left it:

```
apps/                  IMAGE BUILDER: one directory per app built on top of the factory
  Dockerfile           the generic app layer; copies apps/<app>/ from its OWN context
  hpcg/                build.sh app.yaml prepare extract
sif/                   DELIVERY: image to .sif, pinned to a digest
  Makefile Deffile Deffile.apps pin_image_digest.sh wrap_apptainer.sh
  *.sif *.def bin/     (ignored) built here unless BENCH_IMAGE_DIR says otherwise

hpcrun/                RUNNER: names no site and no app
  submit runner.sh collect validate sitegen schemadoc env.sh
  Makefile             `make test`: every off-cluster suite
  APP_CONTRACT.md      the app contract (was scripts/app.d/README.md): interface I3,
                       written down by the side that consumes it
  benchlib/ schema/ experiments/
  lib/                 was ncar-hpc/libexec/*.sh: launcher, contract, placement,
                       topology probe, provenance, results, arch check
  tests/               test_*.sh, test_bench.sh, self_test.sh, fixtures/
  templates/           job.pbspro.tmpl; later job.slurm.tmpl

sites/                 MACHINE DESCRIPTIONS, read by the other four concerns
  ncar.yaml
  ncar/
    README.md          was ncar-hpc/NCAR_HowTo.md
    sif_env.sh         was ncar-hpc/config_env.sh: Apptainer's build environment at NCAR
    derecho.yaml  casper.yaml
    derecho/           cluster.sh  App_benchmarker_derecho.pbs  Placement_derecho.pbs
                       images.mk   (generated, step 4.7c)
    casper/            cluster.sh  images.mk
    legacy/            OSU_derecho.pbs OSU_casper.pbs FE_derecho.pbs set_gpu_rank
```

And the factory, in `NCAR/hpc-dev-container-factory`
(`ImagePublishingPlan.md` §4 and §5):

```
containers/            devenv/ test/ publish/
CONTRACT.md            interface I1 (§3)
scripts/               factory recipes, copied into every image as /container/extras:
                       build_common.cfg, report_placement, the OSU build
  app.d/osu/           OSU's contract, beside the build that installs OSU (DECISION 6)
.github/               the factory's own build workflows and composite actions
```

Adding TACC is then `sites/tacc.yaml`, `sites/tacc/<cluster>.yaml`, one
generated `cluster.sh` and `images.mk` per cluster, `sites/tacc/sif_env.sh`,
and `hpcrun/templates/job.slurm.tmpl` -- plus the three Slurm code paths that
§4.6 names. No other directory changes.

### Why each directory is where it is

- **The factory leaves this repository instead of being rearranged in it.**
  It becomes its own product, maintained in `NCAR/hpc-dev-container-factory`
  (option D of `ImagePublishingPlan.md`). What stays here consumes its images
  by tag and digest, and relies only on the base contract, I1. Phase 4.7 does
  not touch `containers/` or `scripts/`, so the two pieces of work do not
  collide.
- **`apps/` is at the root, not under `containers/`.** `containers/apps/`
  would group the app layer with the factory because both are Dockerfiles. The
  point of this phase is to group by concern, and the question an app author
  asks is "where does my app go?", which `apps/<name>/` answers.
- **The OSU contract goes with the factory.** The rule that decides it:
  **a contract lives beside the build script that installs its binary.** HPCG
  is built by the image builder, so its contract is in `apps/hpcg/`. OSU is
  built by the factory, so its contract goes with the factory, into
  `NCAR/hpc-dev-container-factory`. Otherwise a contract and the binary it
  describes would be built from different commits, which is F1 again in the
  opposite direction. OSU and `report_placement` are in the factory in the
  first place because they are MPI-level tools that every container run on a
  cluster depends on.
- **The contract's specification moves to `hpcrun/`.** It states what the
  runner requires, so the runner owns it, beside `hpcrun/schema/app.json`,
  which already enforces it. The producers, in both repositories, point to it.
- **`sif/` is its own directory.** It is not the image builder, because it
  runs at the site, and it is not the runner, which per §3 of the plan
  "measures, never builds". Its site-specific parts come from `sites/`.
- **Entry-point job scripts live with their cluster.**
  `App_benchmarker_derecho.pbs` carries Derecho's scheduler directives and
  hands over to the runner, so it is a Derecho file. `Placement_derecho.pbs`
  is, as §8 of the plan says, an image-certification test -- but it certifies
  images **on Derecho**, so it belongs with Derecho, not with the portable
  factory.
- **`legacy/` makes the status of the old scripts visible.** §8 of the plan
  already intends to fold `OSU_*.pbs` into the runner as an app and then
  delete them. Until then, the directory name says they are not the way in.
- **The runner is `hpcrun/`, not `bench/`.** Benchmarking is one kind of run.
  The same machinery -- the app contract, experiments, cluster profiles, the
  launcher, provenance and results -- is meant to serve code validation and
  production runs too (the plan's §11, question 10), so the directory is named
  for running applications on HPC clusters rather than for one purpose. It is
  not `runner/`, because "runner" also means GitHub's CI machines throughout
  the workflows and `CLAUDE.md`. The rename rides on the move in step 4.7a,
  which moves the directory anyway, so it costs nothing extra.
- **The `BENCH_` prefix stays.** It appears 552 times in 29 files, and 23 of
  those are in app hooks installed inside published images (`BENCH_RUNDIR`,
  `BENCH_RANKS`, ...). Renaming it would break every existing image's contract
  until the image is rebuilt. It is a name, not a promise about what a run is
  for; renaming it, if ever, belongs with the work on kinds of run.
  `BENCH_ROOT` keeps its name and now points at `hpcrun/`.

### The full move list

| From | To | Step |
|---|---|---|
| `containers/deploy/bench/*` | `hpcrun/` | 4.7a |
| `containers/deploy/bench/test_bench.sh` | `hpcrun/tests/` | 4.7a |
| `ncar-hpc/libexec/{app_contract,check_arch,check_placement,placement_rules,probe_topology,provenance,results,make_apptainer_launcher}.sh` | `hpcrun/lib/` | 4.7a |
| `ncar-hpc/libexec/{self_test,test_app_contract,test_cluster,test_results,test_rules}.sh`, `fixtures/` | `hpcrun/tests/` | 4.7a |
| the `test` target of `ncar-hpc/libexec/Makefile` (lines 99-108) | `hpcrun/Makefile` | 4.7a |
| `containers/deploy/sites/*` | `sites/` | 4.7a |
| `sites/job.pbspro.tmpl` | `hpcrun/templates/` | 4.7a |
| `ncar-hpc/PBS/{App_benchmarker_derecho,Placement_derecho}.pbs` | `sites/ncar/derecho/` | 4.7a |
| `ncar-hpc/PBS/{OSU_derecho,OSU_casper,FE_derecho}.pbs`, `ncar-hpc/set_gpu_rank` | `sites/ncar/legacy/` | 4.7a |
| `ncar-hpc/NCAR_HowTo.md` | `sites/ncar/README.md` | 4.7a |
| `ncar-hpc/libexec/{Makefile,Deffile,Deffile.apps,pin_image_digest.sh,wrap_apptainer.sh}` | `sif/` | 4.7a |
| `ncar-hpc/config_env.sh` | `sites/ncar/sif_env.sh` | 4.7a |
| `ncar-hpc/.gitignore`, `containers/deploy/.gitignore`, `bench/.gitignore` | divided among `sif/`, `hpcrun/` and the root | 4.7a |
| `scripts/build_hpcg.sh`, `scripts/app.d/hpcg/` | `apps/hpcg/` | phase 5 |
| `containers/apps/hpcg/Dockerfile` | `apps/Dockerfile`, rewritten | phase 5 |
| `scripts/app.d/README.md` | `hpcrun/APP_CONTRACT.md` | phase 5 |
| `containers/{devenv,test,publish}/`, the rest of `scripts/`, the factory's workflows and `.github/actions/` | `NCAR/hpc-dev-container-factory` | `ImagePublishingPlan.md` §5 |
| upstream's Docker Hub workflows, and what only they use: `containers/demo/` (`derived-containers.yaml`), `src/` (`conda-build.yaml`) | to the factory if it wants them, otherwise deleted | `ImagePublishingPlan.md` §5 |

---

## 7. How this fits the plan's phases

The proposed order, and what each step waits for:

```
4.5  rename (done 2026-09-05)
 ->  4.7a  every move, the path edits it forces,     one operator migration
           NCAR_HPC_ROOT removed
 ->  4.7b  site names out of site-neutral code       names and messages only
 ->  4.7c  image sets and the host-MPI root from     behaviour; shares its
           the machine description                   schema change with sub-clusters
 ->  4.5   sub-clusters (second half)                written at the final paths
 ->  5     app images: apps/, F1, F2's names, F5     rewrites what §9 describes;
                                                     builds on the NCAR factory's images
 ->  4.6   Slurm, for TACC                           still waits for an account

alongside, in ImagePublishingPlan.md §5: the factory moves to
NCAR/hpc-dev-container-factory and publishes there, before phase 5 needs it
```

**Why the factory's move does not wait for 4.7, or 4.7 for it.** Phase 4.7
touches only the deployment side (`containers/deploy/`) and moves nothing out
of `containers/` or `scripts/`; the factory's move takes exactly those. The
two meet at phase 5, whose app images are built on the factory's published
images.

**Why 4.7 comes before sub-clusters.** Sub-clusters change the cluster schema,
the generator and both cluster files. After 4.7a those files are at their final
paths, so the sub-cluster work is written once. And 4.7c changes how an
experiment names its images, which sub-clusters also touch (a new `subcluster:`
key); making both changes together means one schema version, not two. That is
the argument phase 4.5 made for absorbing §11.6.

**Why F1 waits for phase 5.** Phase 5 already replaces
`containers/apps/hpcg/Dockerfile` with a generic app Dockerfile (§9 of the
plan). If that file is `apps/Dockerfile` and copies `apps/<app>/` from its own
build context, F1 is fixed by work phase 5 does anyway. Moving the app files in
4.7 and rewriting them in phase 5 would handle them twice.

**Why TACC stays last.** Nothing here changes the reasoning of §4.6: a Slurm
path written without a Slurm machine to test on would be wrong in ways nobody
notices. What 4.7 changes is how much of the repository that work has to touch
when it happens.

---

## 8. The steps

Each step ends with the 184 checks passing.

Git does not record that a file was moved. It stores the new tree and, when
asked (`git diff -M`, `git log --follow`), infers moves by comparing file
contents. A moved file whose content is mostly unchanged is shown as a rename
with a small diff, and its history can be followed across the move. A file
that is moved and substantially rewritten in the same commit may appear as a
deletion plus an unrelated new file. So the rule for review is: **a commit that
moves files contains only the edits the move forces** -- changed paths, a
variable that no longer has anything to point at -- and every other edit goes
in a separate commit.

### 4.7a -- every move, and the edits the moves force

All the moves happen in one step, so that operators migrate once.

**Moves.** Every row of the move list marked 4.7a.

**Edits the moves force.**

- `runner.sh:166` and `Placement_derecho.pbs:116` source
  `${BENCH_ROOT}/lib/<name>` instead of `${NCAR_HPC_ROOT}/libexec/<name>`.
- `runner.sh:73`, and the matching checks in both entry points, stop using the
  existence of `${NCAR_HPC_ROOT}/libexec` to test that a profile was sourced.
  They test `BENCH_CLUSTER` and `BENCH_ROOT`, which every profile exports.
- `runner.sh:104` finds `sites/` at `${BENCH_ROOT}/../sites`.
- The hand-written tail of each `cluster.sh` (lines 241-252): three levels up
  from `sites/ncar/<cluster>/` is now the repository root, so `BENCH_ROOT`
  becomes `<root>/hpcrun` and `BENCH_IMAGE_DIR` defaults to `<root>/sif`.
  `NCAR_HPC_ROOT` then has nothing left to locate and is removed: from both
  profiles, from `benchlib/cluster.py:37,57,240`, and from the comments in
  `jobfile.py`, `env.sh` and the tests.
- `cluster.py:94-110`, `Placement_derecho.pbs:124` and `test_bench.sh:65` run
  `make echo-<set>` in `sif/`.
- The `%.sif` rule (`Makefile:165`) depends on and sources the site's
  `sif_env.sh`, named in one variable that defaults to
  `../sites/ncar/sif_env.sh`, and the wrapper links (line 180) go to
  `sif/bin/`. That default is a site name inside delivery code; step 4.7c
  removes it.
- `template_for` in `hpcrun/submit` looks in `${BENCH_ROOT}/templates/`.
- The test driver becomes `hpcrun/Makefile`, and the relative paths inside
  `test_bench.sh` (lines 65, 419, 458) are corrected.
- Every path in an error message or usage text: the header and error messages
  of `App_benchmarker_derecho.pbs`, line 51 of each legacy script (which tells
  the operator to set `NCAR_HPC_ROOT`), `runner.sh:77` and `:275`,
  `bench/submit:129`, and `sites/ncar/README.md`.

**Checks.** The 184 checks pass, run from `hpcrun/`. `git diff -M --stat` for
the step shows every moved file as a rename. A `hpcrun/submit --dry-run`
produces the same job script as before, apart from the paths inside it. Then,
on Derecho: `hpcrun/validate derecho-hpcg` run from the repository root (which
fails today, §5 item 6), `make check-images` in `sif/`, one short
hand-submitted `App_benchmarker_derecho.pbs` job, and one `hpcrun/submit` job;
on Casper, `hpcrun/validate casper-hpcg` and one job. Phase 4's first
submission showed that the off-cluster tests do not cross every boundary a real
job crosses -- the `exec` boundary, that time -- so one real job per entry point
is part of the check, not an extra.

**What an operator must do,** once, after pulling.

- **Move the images.** `git pull` moves the files git tracks. It does not touch
  ignored files, so the `.sif` images, the `.def` pins, `bin/` and any results
  stay in `containers/deploy/ncar-hpc/libexec/`. Either
  `mv containers/deploy/ncar-hpc/libexec/*.sif sif/`, or set
  `BENCH_IMAGE_DIR` to wherever they are kept. The `.def` files need not be
  moved; the next `make` regenerates them. A `.sif` carries its own digest
  label, so `make check-images` reports a moved file as current. After that,
  the old directory holds nothing git knows about and can be deleted by hand.
- **Update a copied profile.** A profile copied to
  `~/.config/hpcdev/cluster.sh` derives `BENCH_ROOT` from
  `${NCAR_HPC_ROOT}/../bench`, which no longer exists. The entry points then
  stop with their existing "does not point BENCH_ROOT at" message, updated to
  name the new path, and the fix is to set `BENCH_ROOT=<clone>/hpcrun` in the
  copy. No fallback that works out the new location from the old variable is
  proposed. Phase 4 set that rule (decision 2 in "Phase 4, as built": a
  defensive default lets a mistake resolve silently to Derecho's paths), and
  this step keeps it. A copied profile's generated block is stale after any
  description change anyway, so re-copying it is the better fix.
- **Type `hpcrun/` where you typed `bench/`.** `hpcrun/submit`,
  `hpcrun/validate` and `hpcrun/collect` replace the old paths, and sourcing
  `hpcrun/env.sh` puts them on `PATH` the way `bench/env.sh` did.

### 4.7b -- site names out of site-neutral code

Names and messages only, from the table in F3: remove the `NCAR_HOST`
fallbacks in `runner.sh:181` and `provenance.sh:164`, correct the message at
`runner.sh:195`, point `hpcrun/collect`'s default root at the profile's results
root, and change the label key `io.ncar.hpcdev.image_tag` in both Deffiles.
The label change reaches a `.sif` only when it is next rebuilt, which is
harmless because nothing reads the label until phase 5.

**Checks.** The 184 checks, and `git grep -n -i 'ncar'` over `hpcrun/` and
`sif/` returns only comments and test data.

### 4.7c -- the machine description states the image set and the host-MPI root

This step changes behaviour, which is why it is separate from the moves.

- **Image sets.** Each cluster file gains the images it runs, stated as axes
  rather than as a list:
  ```yaml
  images:
    os: leap
    compilers: [oneapi, gcc14, nvhpc]   # each must be a key of modules.compiler_map
    mpi: [mpich, openmpi]               # each must be a family listed under mpi:
    apps: [hpcg]
  ```
  which yields the same two sets the Makefile defines by hand today,
  `derecho` and `derecho-hpcg`. `hpcrun/validate` can then refuse a set that
  names a compiler with no host module, or an MPI family the cluster cannot
  host. That is why `casper_images` has no mpich images today, and this turns
  the reason from a comment into a check. `sitegen` writes
  `sites/<site>/<cluster>/images.mk` beside `cluster.sh`, under the same rule
  (`--check` fails while it is stale); `sif/Makefile` includes it; and the
  generated file also names the site whose `sif_env.sh` applies, which removes
  the default left behind in 4.7a. `benchlib/cluster.py` reads the YAML
  directly instead of running `make`. An experiment's `images.from_make:` is
  replaced by a key naming one of the cluster's sets, spelled in the same
  schema change as sub-clusters.
- **The host-MPI root.** `mpi.openmpi` gains `root:` -- on Casper
  `'${NCAR_ROOT_OPENMPI}'`, single-quoted like the existing `lib_dirs` entry --
  and `make_apptainer_launcher.sh:345-350` reads it from the profile instead
  of naming NCAR's variable.
- **The workflow comment.** `derecho-images-ghcr.yaml:17` is corrected to say
  which consumer uses which images. Phase 5 removes the need for the comment.

**Checks.** The 184 checks plus new ones for image-set validation, and
`make -n derecho-hpcg` in `sif/` names the same six files as before.

### What phase 5 then absorbs

Listed so that the rewrite of the plan's §9 carries them.

- **F1.** `apps/Dockerfile` takes `ARG APP`, copies `apps/${APP}/` from its own
  build context, and runs `apps/${APP}/build.sh`. That script relies only on
  interface I1 of the base image: `build_common.cfg`, `config_env.sh` and the
  compilers. `scripts/build_hpcg.sh` and `scripts/app.d/hpcg/` leave `scripts/`,
  so new base images stop carrying them. A fix to HPCG's extractor then needs
  only an app-layer rebuild.
- **F2, the build flags.** Each sub-cluster states its target once, spelled
  per compiler family, beside the `target_arch` it is checked against:
  ```yaml
  build:
    march: {default: -march=znver3, nvhpc: -tp=zen3}
  ```
  The app workflow reads it through a first job that turns the YAML into the
  build matrix. This is the `fromJSON` route that §9 of the plan already
  requires for dispatch inputs. Tuned *base* images are not planned under
  option D (`ImagePublishingPlan.md` §7), so `derecho-images-ghcr.yaml` leaves
  with the factory's workflows rather than learning to read this; the flags
  apply to the app layer, through `APP_MARCH_FLAGS`.
- **F2, the names.** This question, and who builds the base images at all, now
  live in `ImagePublishingPlan.md`; what follows is the reasoning that led
  there. An app image's repository states the target it was built for, as base
  images already do. Whether the name carries the cluster
  (`hpcdev-apps-derecho`) or the microarchitecture (`hpcdev-apps-zen3`) is the
  question phase 4.5 left for phase 5. F2's evidence -- Casper's Genoa nodes
  running Derecho's Zen 3 images -- favours the microarchitecture, because more
  than one cluster can share one. Publishing under new names and leaving the old
  ones in place keeps every existing digest pin working.
- **F5.** The delivery step writes the compiler, MPI family and target as SIF
  labels; the runner reads them first and uses the file-name patterns only when
  a label is absent.

---

## 9. Upstream's files

**No longer a constraint, as of 2026-09-29.** The fork stops tracking upstream
(`benkirk/demo_github_actions`), so which files came from upstream no longer
decides where they may go. Nine files in `containers/deploy/ncar-hpc/` came
from there; they move with everything else, to the destinations in the move
list in §6. The history of that relationship, and why it ended, is in
`ImagePublishingPlan.md` §8 and `UpstreamPRPlan.md`.

---

## 10. Decisions

Numbered after the plan's four. Decisions 5-7 were answered on 2026-09-29;
8-10 are open.

| # | Question | Answer, or recommendation | The alternative, and what it costs |
|---|---|---|---|
| 5 | Move upstream's nine files? | **Answered: yes.** The fork no longer tracks upstream. | -- |
| 6 | Where does OSU's contract live? | **Answered: with the factory**, beside the build that installs OSU, by the rule in §6. It moves with the factory to `NCAR/hpc-dev-container-factory`. OSU and `report_placement` are part of the base contract because every container run on a cluster depends on MPI-level tools like them. | A contract-only app layer (`apps/osu/`). No longer needed, since the factory is the fork's own. |
| 7 | Names | **Answered: `hpcrun/` for the runner**, with `apps/`, `sif/` and `sites/`; the `BENCH_` prefix stays (§6). | `runner/`, which clashes with GitHub's CI runners; `bench/`, which names one kind of run. |
| 8 | Order | **Recommended: 4.7a-c before sub-clusters.** | After: the sub-cluster work is written at the old paths and then moved, and the experiment schema changes twice. |
| 9 | `NCAR_HPC_ROOT` | **Recommended: remove it**, with no fallback; the error message names the one line to set. | Keep it as an accepted spelling for a while. Old `~/.config` copies keep working, and the runner's vocabulary keeps a site name for as long as it is accepted. |
| 10 | Move the planning documents to `docs/`? | **Recommended: not now.** It is independent of the concerns above, it touches every cross-reference between the documents, and it can be done at any time. | -- |

---

## 11. What this does not change

- **What a compute node reads.** The generated block in `cluster.sh` keeps its
  shape; only the values of the path variables differ, and `NCAR_HPC_ROOT`
  disappears. The logic of `make_apptainer_launcher.sh` is untouched until
  4.7c changes where one value comes from.
- **The results format.** There is no schema change in 4.7a or 4.7b.
  `run.meta` records paths such as the launcher's; their values change and
  their keys do not.
- **Published image names.** Every existing `Deffile` pin and GHCR tag keeps
  working through phase 4.7. Renaming is phase 5's decision, taken as
  `ImagePublishingPlan.md` settles it.
- **The factory.** Phase 4.7 does not touch `containers/` or `scripts/`. They
  leave this repository as a whole, for `NCAR/hpc-dev-container-factory`
  (`ImagePublishingPlan.md` §5), and HPCG's recipe stays behind as
  `apps/hpcg/` in phase 5.
- **The repository boundary.** This is now two repositories, which
  `SeparationAnalysis.md` said to do once the image contract and the runner's
  contract were explicit: the factory in `NCAR/hpc-dev-container-factory`, and
  the image builder, delivery, runner and machine descriptions here. Within this
  repository, a later split is a matter of selecting directories: the runner is
  `hpcrun/` and `sites/`, the image builder is `apps/` and `sif/`, and each can
  be extracted with its history (`git filter-repo --path hpcrun --path sites`)
  instead of being picked apart file by file.
