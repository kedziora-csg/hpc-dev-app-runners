# Plan: Who Builds the Images, and Where They Are Published

Status: **option D decided 2026-09-29.** The factory becomes its own product in
[`NCAR/hpc-dev-container-factory`](https://github.com/NCAR/hpc-dev-container-factory),
trimmed and maintained by this fork's author, and this repository stops
building base images once that factory publishes. The fork no longer tracks
upstream (`benkirk/demo_github_actions`). App images are named with the target
in the tag (§2, decided in phase 5).

**Who decides, as of 2026-09-30.** The factory's design and its base images
are this fork's author's to decide, in the NCAR repository: which images, which
registry, which tags, what to trim, and when to tune. No further design
questions go to benkirk; §6 lists what is left and who settles each. The one
thing still needed from him is not a question but a legal step: his approval
of the licence change, because he holds the copyright in the code he wrote (§4,
"License").

The NCAR repository exists, created on 2026-07-28 and still empty. As of
2026-09-29 it is **public**, it is **owned jointly** -- benkirk, who wrote the
original factory, is an admin beside this fork's author -- and its code will
be licensed under **Apache License 2.0** (§4, "License").

Phase 4.7 (`BenchRunnerPlanAddendum.md`) does not depend on any of this: it
moves nothing out of `containers/` or `scripts/`, and changes no image name.

**Where things stand, 2026-10-13.** Phase 5 ran ahead of the factory's move.
Its app images build on today's `hpcdev-derecho` base images, with the base
repository as a workflow input so the switch is one default. So the move in
§5 is now the main step outstanding. It is also what removes two faults
phase 5 inherited:
- **Casper runs base images named for Derecho.** They are
  `hpcdev-derecho-x86_64:leap-...`.
- **Those base images are tuned for Zen 3.** Their libraries were compiled
  `-march=znver3`, which permits AMD-only instructions, so they are not
  guaranteed to run on Casper's Intel Cascade Lake nodes. The start-of-job
  architecture check inspects the app's binary, not the base's libraries.

The steps in §5 are rewritten with what the seam study measured
(`BenchmarkRunnerPlan.md` §11 item 11).

---

## 1. What exists today

The fork's GitHub Container Registry (GHCR) account holds seven image
repositories, all public:

| Repository | Built by | What it promises | Used by |
|---|---|---|---|
| `hpcdev-x86_64`, `hpcdev-aarch64` | `matrix-build-images-ghcr.yaml` and `dial-an-image-ghcr.yaml` | runs on any machine of that architecture | nothing in the benchmark path |
| `hpcdev-derecho-x86_64` | `derecho-images-ghcr.yaml` | the same stack, rebuilt with `-march=znver3` (`-tp=zen3` for nvhpc) | the base `.sif` files on Derecho **and Casper** |
| `hpcdev-apps-x86_64` | `hpcg-smoketest-ghcr.yaml` | HPCG added on top of one of the above; the name does not say which | the `-hpcg.sif` files on both clusters |
| three `*-cache` repositories | the base-image builds, automatically | build cache only; nobody runs these | the next build |

All three base repositories are built by `build-hpc-dev-image-ghcr.yaml`, the
fork's copy of upstream's reusable build workflow. Tags have the form
`<os>-<compiler>-<mpi>[-<gpu>]-latest`, plus a dated copy ending `-YY.MM`.
Upstream publishes the same portable factory to Docker Hub as
`ncarcisl/hpcdev-<arch>`.

The fork's changes to the factory, and where each one stands:

| Change | Status |
|---|---|
| oneAPI 2026.1.0, and the guard that fails the build if an installer is missing | **merged upstream** as #35, 2026-08-18 |
| `report_placement` built into every image | fork only; planned as PR 2 in `UpstreamPRPlan.md`, never sent |
| `MARCH_FLAGS` honoured by every compiler family | fork only; upstream applies it to nvhpc only |
| OSU's app contract, installed by `build_osu-micro-benchmarks.sh` | fork only |

Upstream's own workflows came with the fork, and most of them do nothing here:

| Workflows | What they have done in this repository |
|---|---|
| `devel-build-images`, `matrix-build-images`, `container-build`, `derived-containers`, `matrix-smoketest-applications`, `mega-linter` | never run |
| `dial-an-image` | one run, failed (2026-07-31) |
| `trigger-workflows` | runs on a schedule and fails (last 2026-09-15) |
| `conda-build` | runs weekly and succeeds (last 2026-09-26); nothing here uses its result |

---

## 2. The one rule, and two ways to follow it

**One tag must mean one thing.** Before `hpcdev-derecho` existed, the portable
and the Zen 3 workflows both published `leap-oneapi-mpich-latest` into the same
repository, and the tag meant whichever had run last. App images still have
this problem: portable-based and Zen 3-based HPCG images share one tag.

Under option D the question narrows. The new factory publishes portable images
only (§7), so its tags need no target at all, and today's tag format can stay.
The rule then applies to **app images**, which are built for a particular
target. There are two ways to follow it:

| | A separate repository per target | One repository, target in the tag |
|---|---|---|
| Example | `hpcdev-apps-znver3-x86_64:leap-oneapi-mpich-hpcg-latest` | `hpcdev-apps-x86_64:leap-oneapi-mpich-hpcg-znver3-latest` |
| Where to look | one repository per target | one repository |
| The target appears in | the repository name only | the tag, and so in every `.sif` file name made from it |

The second puts the target where the runner already looks, since the runner
reads an image's identity from its `.sif` file name (finding F5 of the
addendum). Either way, name the target after the **microarchitecture**
(`znver3`, `icelake`), not after the cluster: Casper's Genoa nodes already run
Derecho's Zen 3 builds, and Stampede3's Ice Lake and Sapphire Rapids nodes may
share one. Phase 5 decides.

**Decided 2026-09-29: the target goes in the tag**, named for the
microarchitecture. App images are
`hpcdev-apps-x86_64:<os>-<compiler>-<mpi>-<app>-<target>-latest`, for example
`leap-oneapi-mpich-hpcg-znver3-latest`, so the `.sif` files are
`leap-oneapi-mpich-hpcg-znver3.sif`. The target and each compiler's spelling of
it are stated in each cluster's `images:` block, which is what the app workflow
builds from. The old `...-hpcg-latest` tags stay in place for the existing
pins. See `BenchmarkRunnerPlan.md`, "Phase 5, as built".

---

## 3. Who builds the base images: option D

There are two separate questions inside "who builds the base images":
whose **source** the factory is built from, and whose **images** this
repository runs on.

| Option | Factory source | Base images used here |
|---|---|---|
| **A** (today) | a copy in this repository, kept close to upstream's | built by this repository |
| **B** | upstream's, in NCAR's repository | NCAR's, built by upstream |
| **C** | as B | as B, except Derecho's tuned set, built here |
| **D** (decided) | this fork's factory, trimmed, in `NCAR/hpc-dev-container-factory` | that factory's |

**Why D.** It keeps the factory under the same design control as the rest of
the work, instead of depending on another project's choices about what a base
image contains. B would have needed upstream to accept `report_placement` and
the OSU contract, and would have left the trims in §4 to someone else. D also
ends the in-between state of option A, in which this repository both keeps its
own copy of the factory and tracks upstream's -- which is where most of the
confusion came from.

**What D costs.** The fork maintains the factory itself. That means the
compiler and MPI bumps, and the kind of distribution fixes recorded in
`CLAUDE.md`: the C23 guards for gcc 15 and later, the leap 15 pin, the nvhpc
CUDA excludes, and fresh oneAPI URLs copied from Spack at every bump. And the
factory's CI runs under the NCAR repository's limits rather than this
account's (§6).

---

## 4. The factory in `NCAR/hpc-dev-container-factory`

### What it contains

- `containers/devenv/`, `containers/test/`, `containers/publish/`.
- From `scripts/`, what the images need or the factory's tests use:
  `build_common.cfg`, `report_placement.cxx` and `build_report-placement.sh`,
  `build_osu-micro-benchmarks.sh` with `app.d/osu/`, the `hello_world` sources,
  `remove_static_bloat.sh`, and the install helpers.
- Not `derecho-images-ghcr.yaml`. It builds the tuned `hpcdev-derecho` base,
  and the factory publishes portable images only (§7). Its images stay
  published for existing pins, and nothing rebuilds them.
- Upstream's app recipes (`build_wrf.sh`, `build_mpas.sh`, `build_cesm.sh`,
  ...). They test that the stack can build real science codes, which is a
  factory concern, and they cost no image space (§4, "What the images are made
  of"). HPCG's recipe does **not** go: it is an app built for benchmarking, and
  becomes `apps/hpcg/` in this repository.
- One set of build workflows, publishing to one registry, with each compiler
  and MPI version stated once, in its own matrix. The composite actions in
  `.github/actions/` go with them.
- `CONTRACT.md`, described next, and the factory half of `CLAUDE.md`.
- `LICENSE` and `NOTICE`, described under "License" below.

### The base contract

`CONTRACT.md` states what every image promises to anything built on it. This is
interface I1 of the addendum, now a contract between two repositories:

- the image name and tag format;
- `/container/config_env.sh`, sourced by every login shell;
- `/container/extras/build_common.cfg`, which sets `INSTALL_ROOT` and
  `STAGE_DIR`;
- the `MARCH_FLAGS` build argument, and the variable of that name in the image;
- `CC`, `CXX`, `FC` and the MPI compiler wrappers;
- **`report_placement`, `report_cpu_features`, and OSU with its contract at
  `/container/app.d/osu/`.** These are in the base because they are MPI-level
  tools that every container run on a cluster depends on: they are how an
  image shows that it works on a host, before any app is involved.

### What the images are made of

Layer sizes of three published Derecho images, read from GHCR. Sizes are
compressed. Times are approximate: the gaps between the finish times of
consecutive layers in the 2026-08-24 build.

| Image | Total | OS packages | Conda | Compiler | MPI | HDF5, NetCDF, PnetCDF, PIO, FFTW | Final stage |
|---|---|---|---|---|---|---|---|
| `leap-oneapi-mpich` | 2.59 GB | 423 MB | 154 MB | 876 MB | 10 MB | 16 MB, about 10 min | 1,056 MB |
| `leap-gcc14-openmpi` | 1.04 GB | 423 MB | 154 MB | 108 MB | 6 MB | 12 MB, about 11 min | 285 MB |
| `leap-nvhpc-mpich` | 8.16 GB | 423 MB | 154 MB | 3,670 MB | 10 MB | 12 MB, about 14 min | 3,846 MB |

### What to trim, and what not to

1. **The final stage's `chown`: fix it.** `chown -R plainuser: /container/`
   (`containers/devenv/Dockerfile:1585`) changes the owner of every file under
   `/container`, and in a layered image that stores a second copy of every
   file: 27-47% of each image. A `.sif` is unaffected, because flattening keeps
   one copy, and inside a `.sif` `/container` is read-only whoever owns it. So
   the ownership serves only Docker users running as `plainuser`. The registry,
   the CI runners' disks and every download made when building a `.sif` carry
   the duplicate: 3.8 GB of it for each nvhpc image. Establish what needs
   `plainuser` to own `/container`, then either give it only the directories it
   must write to, or create `plainuser` before anything is installed.
2. **Conda: make it optional, off for cluster images.** 154 MB in every image,
   and nothing in the benchmark path uses it. The images are built with
   `conda: true` today. Keep it where an interactive user wants it.
3. **The scientific libraries: keep them.** They are the factory's purpose, the
   apps that will follow HPCG (WRF, MPAS, CESM) need them, and they are under 1%
   of every image.
4. **An image that stops after MPI: only if someone needs it.** It is one build
   argument (`FINAL_TARGET=mpi`), and it saves about 10-14 minutes of build time
   per image, not space. Worth having only if the factory's CI budget is tight.

### What to add, from the seam study

The seam study found that a portable base loses nothing where its libraries
pick their kernels at run time (`BenchmarkRunnerPlan.md` §11 item 11). Today's
base images have no such libraries. Three changes, each measured, make the
portable base deliver AVX-512 where it pays:

5. **A `DYNAMIC_ARCH` OpenBLAS in every image.** The base carries no BLAS
   today. One portable OpenBLAS picked AVX-512 kernels on its own on Cascade
   Lake (65.9 GFLOP/s a core at DGEMM, 1.74x its AVX2 kernels) and on Genoa,
   and Zen kernels on Derecho. On Intel it matched MKL. On AMD it beat MKL,
   which never uses AVX-512 there. Built with the system gcc, no `-march`,
   `TARGET=GENERIC`, single-threaded, BLAS only, as `apps/blas/build.sh` does
   it today.
6. **FFTW with its SIMD codelets.** `fftlibs` configures FFTW with no
   `--enable-sse2/avx/avx2/avx512`, so its codelets are scalar. FFTW picks
   them from CPUID at run time, so enabling them is safe in a portable image:
   on Derecho the AVX-512 build fell back to AVX2 and ran exactly as fast.
   For HeFFTe's distributed FFT they bought nothing measurable, which is an
   argument about that app, not about FFTW.
7. **`report_cpu_features`: say where AVX-512 is.** It answers only "is any
   `%zmm` named", which a oneAPI binary answers yes for whenever it links
   Intel's run-time-dispatched SVML. hpcrun's `check_arch.sh` works around
   it today. The tool should report the functions instead, and its "ISA
   needed" line should say it is meaningful only for a binary built with
   `-mneeded`.

`CONTRACT.md` (above) then promises the dispatching BLAS and FFTW, beside
`report_placement` and OSU.

### License

**Apache License 2.0**, the most common license among NCAR's public
repositories: of the 100 most recently updated, 35 use Apache 2.0, 19 MIT, and
25 state none. It follows NCAR's convention for filling in the license's
copyright line, as `NCAR/wrf-python` and `NCAR/gdex-web-portal` do:

    Copyright 2026 University Corporation for Atmospheric Research

Two things go with it.

- **A `NOTICE` file crediting benkirk as the factory's original author.**
  Apache 2.0 requires anyone who redistributes the code to keep the `NOTICE`
  file, so the credit travels with every copy. `NCAR/MPAS-Workflow` uses its
  `NOTICE` file the same way, to list its contributors.
- **benkirk's agreement to the change of license, in writing.** The code
  arrives under upstream's Creative Commons Attribution-ShareAlike 4.0
  license. The holder of the copyright can release it under Apache 2.0, but
  nobody else can. The simplest record is his approval of the pull request
  that adds `LICENSE` and `NOTICE`. If UCAR, rather than the individual author,
  holds the copyright in staff work, ask whether it has a process for this.
  Copies already published under the Creative Commons license, such as the
  history in `benkirk/demo_github_actions`, keep that license; the change
  applies from the commit that makes it.

### What it publishes

The combinations the clusters need, at the least:

- Derecho and Casper: leap × {oneapi, gcc14, nvhpc} × {mpich, openmpi};
- Stampede3, probably: almalinux9 × {oneapi, gcc} × mpich, to be confirmed on
  the machine.

---

## 5. Moving it, and what this repository becomes

Rewritten 2026-10-13. Phase 5 is done, on the old base images, so the move
is what comes next.

0. **Decisions -- yours.**
   - The registry (§6, Q3). GHCR under the NCAR organisation is the simpler
     choice.
   - The Actions setting that requires approval before an outside
     contributor's workflow runs (Q2).
   - The licence change, for which benkirk's approval of the pull request
     that adds `LICENSE` and `NOTICE` is the one thing still needed from him
     (§4, "License").
1. **Copy the factory, with its history, into the NCAR repository.** On a
   fresh clone -- never the working one -- `git filter-repo` keeps only the
   paths in §4, "What it contains", and the result is pushed to the empty
   repository. Keeping the history keeps the commit messages that explain each
   factory fix, which `CLAUDE.md` refers to. The pushes are yours to make.
2. **Trim, add and publish there.**
   - The trims in §4: the `chown` fix, and conda optional.
   - The three additions in §4, "What to add": a `DYNAMIC_ARCH` OpenBLAS,
     FFTW's SIMD codelets, and `report_cpu_features`' function-level AVX-512
     report.
   - `CONTRACT.md` stating them.
   - The workflows reduced to one set, pointed at the chosen registry.
   - A first publish of the portable set the clusters need: leap x {oneapi,
     gcc14, nvhpc} x {mpich, openmpi}. A TACC set follows once a TACC
     cluster has been drafted and probed (`sites/README.md`).
3. **Per-sub-cluster app targets, in this repository** (`BenchmarkRunnerPlan.md`,
   "Per-sub-cluster app targets"). They go in now, so the rebuild in step 4
   builds each node type's app images once, on the portable base.
4. **Switch this repository to the factory's images, and rebuild.**
   - `GHCR_BASE_REF` in `sif/Makefile`, the `From:` lines of `sif/Deffile`
     and `sif/Deffile.apps`, and the app workflow's `base_repo` default all
     point at the factory.
   - One app-image dispatch per cluster. Then `make <cluster>-hpcg` on each
     cluster.
   - **Acceptance:** `derecho-hpcg`, and `casper-hpcg` on both Casper node
     types, against the existing numbers. HPCG links only MPI and the
     compiler runtime, so a portable base should change nothing. A
     difference is a finding.
   - `hpcrun/tests/test_app_contract.sh` tests OSU's contract from
     `scripts/app.d/osu/`, which moves to the factory with the OSU recipe.
     Keep a copy under `hpcrun/tests/fixtures/` -- the contract is the
     interface, and the copy is what a test holds the image to -- rather
     than fetch it from the factory at test time.
5. **Delete the factory from here:**
   - `containers/` and the rest of `scripts/`;
   - `src/`, `.github/actions/`;
   - the factory's `*-ghcr` workflows, `derecho-images-ghcr.yaml` with
     them, and upstream's workflows listed in §1.

   `CLAUDE.md` keeps its runner half, and `README.md` is rewritten for what is
   left. The old registry repositories, `hpcdev-derecho-x86_64` among them,
   stay until nothing pins them, then can be deleted.
6. **This repository's own licence:** a separate decision, best taken once the
   factory's Creative Commons files have left it.

### Progress, as of 2026-10-19

**Decisions taken.**
- **Registry:** GHCR under NCAR. The workflows already default to
  `ghcr.io/<owner>/hpcdev`, so in the NCAR repository that is
  `ghcr.io/ncar/hpcdev-<arch>`.
- **Outside contributors:** their workflows need approval before they run.
- **Licence:** **CC BY-SA 4.0 for now**, as the original is. Apache 2.0
  later, on benkirk's written agreement. If it is given by email rather than
  as a pull request approval, the change is committed directly with the
  email quoted in the commit message.
- **A copy, not a move.** `benkirk/demo_github_actions` is left exactly as
  it is. The factory in this fork stays until step 5.

**Done.**
- **Step 1.** `NCAR/hpc-dev-container-factory`'s `main` is this fork's
  `main` run through `git filter-repo`: 243 commits, back to March 2025,
  authorship intact. It keeps:
  - `containers/{devenv,test,publish}/`, and `containers/refactor/` for its
    history;
  - `scripts/` and `.github/actions/`;
  - the three GHCR workflows (`build-hpc-dev-image-ghcr`,
    `matrix-build-images-ghcr`, `dial-an-image-ghcr`);
  - `LICENSE.md`, `README.md`, `CLAUDE.md`, `DockerfileDoc.md`,
    `.gitignore` and `.cspell.json`.

  One commit on top says in the README where the copy comes from and that
  it stays CC BY-SA. A second, by the operator, pins the Actions versions
  and adds Dependabot, whose first pull request (#1, `actions/checkout`
  5.1 -> 7.0.1) is open.
- **Actions.** NCAR's organisation had disabled them for the repository. On
  request, its administrators enabled them (2026-10-19).

**In progress -- branches in the NCAR repository, pull requests to open.**
1. **`ghcr-lowercase`** (`60040d1`). The first `dial-an-image-ghcr`
   dispatch failed:
   `invalid tag "ghcr.io/NCAR/hpcdev-x86_64-cache:...": repository name must be lowercase`.
   `github.repository_owner` keeps the owner's case, and the build workflow
   derives every tag from it. Fix: lower-case the repository once, where
   every tag is derived. **Merge first.** Nothing builds in the NCAR
   repository without it.
2. **`final-stage-no-chown`** (`54c9edd`, on top of the above). `plainuser`
   owns `/container` itself, `config_env.sh` and `logs/`, not the whole
   tree. Nothing runs as `plainuser` (the image stays root), and it has
   passwordless sudo, so the recursive `chown` bought nothing and doubled
   every image. **Check:** dispatch
   `dial-an-image-ghcr -f os=leap -f compiler=os-gcc -f mpi=openmpi -f conda=false`
   from `main` (after 1) and from this branch, then compare the published
   image's final layer. It should drop from roughly a quarter of the image
   to a few MB.

**Next, in order.**
- The other §4 changes, one pull request each, each checked with one
  `dial-an-image-ghcr` dispatch:
  - conda optional, off for cluster images;
  - a `DYNAMIC_ARCH` OpenBLAS;
  - FFTW's SIMD codelets;
  - `report_cpu_features` reporting functions.
- Make the `hpcdev-x86_64` package public after its first publish (step 2).
- Publish leap x {oneapi, gcc14, nvhpc} x {mpich, openmpi}, then steps 3-5
  as above.

The working clone used for those branches is on GLADE, at
`/glade/derecho/scratch/kedziora/tmp/claude-50600/.../scratchpad/factory-dryrun`.
Any clone of `NCAR/hpc-dev-container-factory` will do; the branches are
pushed there.

This repository is then `apps/`, `sif/`, `hpcrun/` and `sites/`, one app-image
workflow, and a `CLAUDE.md` about the runner. It depends on the factory only
through the base contract in §4, and it publishes only app images.

**What the names become.**

| Today | After the move |
|---|---|
| base: `hpcdev-derecho-x86_64:leap-gcc14-openmpi-latest` | base: `<factory registry>/hpcdev-x86_64:leap-gcc14-openmpi-latest`, portable, named for OS, compiler and MPI only |
| app: `hpcdev-apps-x86_64:leap-gcc14-openmpi-hpcg-znver3-latest`, on Casper's Genoa and Cascade Lake alike | app: `...-hpcg-znver3` on Derecho, `...-hpcg-znver4` on Genoa, `...-hpcg-cascadelake` on Cascade Lake, each built for its node type |
| `derecho-images-ghcr.yaml`, `sif/Makefile`'s comment on why the base repository is named for Derecho | gone |

Image **sets** keep their cluster names (`casper-hpcg`), because a set does
belong to a cluster. What changes is that a set resolves to the images of
the sub-cluster an experiment runs on.

---

## 6. What is left to settle, and who settles it

Q1 and Q2 below went to benkirk and are answered. Everything still open is
either this fork's author's decision -- Q3, Q4, and the direction for tuned
base images in §7 -- or a question for NCAR's GitHub administrators, about
larger runners and concurrency under Q2. Only the licence approval in §4 still
needs benkirk.

**Q1. Whose repository is it? Answered 2026-09-29: shared.** benkirk agreed
that this fork's author takes over the factory, with joint ownership to credit
his original work and keep him involved. Both are admins of the repository.
This does not bring back an upstream in the sense of §8: there is one factory,
in one repository, and no second copy to keep in step with.

**Q2. Internal or public? Answered 2026-09-29: public.** NCAR's rules for its
GitHub organization cover single sign-on, account email addresses, membership,
collaborator access and token authorization, and none of them restricts
public repositories; NCAR's organization settings allow them, and many of its
repositories are public. What public visibility settles, and what it does not,
as I understand GitHub's policy:

- **Minutes: settled.** Standard runners are free for public repositories.
- **Pulling images: settled for the repository, not yet for the images.**
  Container images published from it have a visibility of their own, set when
  the first one is published, and NCAR may restrict public images. Check it at
  the first publish. Public images need no credentials, on the clusters or in
  this repository's CI.
- **Outside contributions: one setting to make.** Anyone can now fork the
  repository and open a pull request. In the repository's Actions settings,
  require approval before workflows run for outside contributors, so that a
  stranger's pull request cannot spend the factory's runners.
- **Still open: larger runners** (more disk and cores), which are billed even
  for public repositories. The factory already struggles with the standard
  runner's disk; that is why `slim-action-runner` exists. Are they available
  to NCAR repositories?
- **Still open: concurrency.** Jobs running at once are capped per
  organization and shared across all its repositories. How long will the
  factory's matrices wait behind other NCAR projects?

**Q3. Which registry?** *(This fork's author decides.)* GHCR under the NCAR organization, or Docker Hub
`ncarcisl`. If Docker Hub, check its limits on anonymous pulls: every user of a
shared login node pulls from the same network address. With the repository
public, GHCR is the simpler choice: the factory's workflows already publish to
GHCR, and a workflow's own token can push to its organization's registry
without a separate account or stored password.

**Q4. Can the tag format stay** *(This fork's author decides; nothing outside
this repository and the factory depends on it.)* `<os>-<compiler>-<mpi>-latest` and `-YY.MM`?
The Deffiles and the digest pinning depend on it.

---

## 7. Tuned base images, and the measurement that can wait

**Direction, 2026-09-30.** Portable base images and a tuned app layer for now,
as below. Eventually, base images made for clusters -- the distro of the
cluster's Linux, its sub-clusters' microarchitectures, and the compilers and
MPI families it hosts -- with app images a subset of them. Where the seam
between base and app images should lie is a study in `BenchmarkRunnerPlan.md`
(§11, item 11). Tuned base images are the factory's own decision, made in the
NCAR repository.

Option D plans no tuned base images, only portable ones. For the apps
benchmarked today, a tuned base should make **no difference on the cluster**:

- HPCG and OSU link against MPI and the compiler's runtime libraries, and
  nothing else from the base. `HPCG_LIBS` is empty in `build_hpcg.sh`.
- Every MPI family on both clusters is replaced by the host's at run time
  (`cray-mpich-abi` or `host-openmpi` in `sites/ncar/*.yaml`). The compiler
  runtimes are either prebuilt (oneAPI, nvhpc) or built before `MARCH_FLAGS`
  takes effect (gcc14).

So the libraries that tuning changes are not used by today's benchmarks.
`ldd /container/bin/xhpcg` inside any HPCG image confirms it without a job.
Tuning belongs to the app layer, through `APP_MARCH_FLAGS`.

The question comes back when an app that uses those libraries enters the
benchmark set, most likely one heavy on FFTs. The measurement then is: that
app, built with the same `APP_MARCH_FLAGS`, on a portable base and on a tuned
one. Until then, `hpcdev-derecho-x86_64` stays published for the existing pins,
and is not rebuilt.

---

## 8. The relationship with upstream

**Not tracked, as of 2026-09-29.** Upstream was active until recently -- it
merged the oneAPI change as #35 on 2026-08-18 -- but it no longer shapes what
happens here. What that gains:

- the layout no longer has to leave upstream's files where they are
  (addendum DECISION 5);
- the fork's factory can be trimmed and reorganised freely (§4);
- upstream's workflows, which do nothing here (§1), can be deleted;
- the bookkeeping in `UpstreamPRPlan.md` stops; that document is on hold.

What it costs is the maintenance listed under §3. Changes made upstream can
still be copied across by hand when they are worth having; nothing flows in
automatically.

---

## 9. Order

Rewritten 2026-10-13; §5 has the detail.

1. Decide the registry and the Actions setting, and ask benkirk to approve
   the licence pull request (§5, step 0).
2. Move the factory; trim, add and publish there (§5, steps 1 and 2).
3. Per-sub-cluster app targets, here (§5, step 3).
4. Switch this repository over, rebuild, and run the acceptance jobs (§5,
   step 4).
5. Delete the factory from here (§5, step 5).
6. Then phase 4.6, Slurm, for TACC -- starting with `hpcrun/clusterinit` and a
   probe job there, which say which parts of 4.6 the machine needs.

Phase 5 (app images) and the sub-cluster half of phase 4.5 are done, on the
old base images; the switch in step 4 is where they move onto the factory's.
