# Plan: Who Builds the Images, and Where They Are Published

Status: **option D decided 2026-09-29.** The factory becomes its own product in
[`NCAR/hpc-dev-container-factory`](https://github.com/NCAR/hpc-dev-container-factory),
trimmed and maintained by this fork's author, and this repository stops
building base images once that factory publishes. The fork no longer tracks
upstream (`benkirk/demo_github_actions`). Still open: the registry and the
remaining practical questions in §6, and the naming of app images (§2), which
phase 5 settles.

The NCAR repository exists, created on 2026-07-28 and still empty. As of
2026-09-29 it is **public**, it is **owned jointly** -- benkirk, who wrote the
original factory, is an admin beside this fork's author -- and its code will
be licensed under **Apache License 2.0** (§4, "License").

Phase 4.7 (`BenchRunnerPlanAddendum.md`) does not depend on any of this: it
moves nothing out of `containers/` or `scripts/`, and changes no image name.

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

1. **Settle what is left in §6:** the registry (Q3) and the Actions setting
   for outside contributors (Q2). Q1 and Q2 themselves are answered.
2. **Copy the factory, with its history, into the NCAR repository.** On a
   fresh clone -- never the working one -- `git filter-repo` rewrites the
   history to keep only the paths in §4, and the result is pushed to the empty
   repository. Keeping the history keeps the commit messages that explain each
   factory fix, which `CLAUDE.md` refers to. The first change on top of it
   replaces `LICENSE.md` with Apache 2.0's `LICENSE` and adds `NOTICE`, as a
   pull request benkirk approves (§4, "License"). The pushes are yours to
   make.
3. **Trim and publish there:** the `chown` fix and optional conda (§4), the
   workflows reduced to one set and pointed at the chosen registry, and a first
   full publish of the combinations in §4.
4. **Switch this repository to the new images.** This waits for phase 5's
   `apps/Dockerfile`, because the new factory's images no longer carry
   `build_hpcg.sh`, and today's app layer runs it out of the base image
   (finding F1). Then `GHCR_BASE_REF` in the delivery `Makefile` and the app
   workflow's base repository point at the new factory.
5. **Delete the factory from here:** `containers/devenv`, `test`, `publish`
   and `demo`, the rest of `scripts/`, `src/`, `.github/actions/`, the four
   `*-ghcr` factory workflows, and upstream's workflows listed in §1. The old
   registry repositories stay in place until nothing pins them, then can be
   deleted. This repository's own license is a separate decision, best taken
   once the factory's Creative Commons files have left it.

This repository is then `apps/`, `sif/`, `hpcrun/` and `sites/`, one app-image
workflow, and a `CLAUDE.md` about the runner. It depends on the factory only
through the base contract in §4, and it publishes only app images.

---

## 6. Questions for benkirk and NCAR's GitHub administrators

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

**Q3. Which registry?** GHCR under the NCAR organization, or Docker Hub
`ncarcisl`. If Docker Hub, check its limits on anonymous pulls: every user of a
shared login node pulls from the same network address. With the repository
public, GHCR is the simpler choice: the factory's workflows already publish to
GHCR, and a workflow's own token can push to its organization's registry
without a separate account or stored password.

**Q4. Can the tag format stay** `<os>-<compiler>-<mpi>-latest` and `-YY.MM`?
The Deffiles and the digest pinning depend on it.

---

## 7. Tuned base images, and the measurement that can wait

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

1. Q1 and Q2 in §6 are answered. Choose the registry (Q3), and make the
   Actions setting for outside contributors (Q2).
2. Move the factory and trim it (§5, steps 2 and 3).
3. Phase 5 of `BenchmarkRunnerPlan.md`: `apps/`, the generic app Dockerfile,
   app images named by §2 and built on the new factory's images; then switch
   this repository over (§5, step 4).
4. Delete the factory from this repository (§5, step 5).

Meanwhile the benchmark work continues unchanged: phase 4.7 and the
sub-cluster half of phase 4.5 touch neither the factory nor any image name.
