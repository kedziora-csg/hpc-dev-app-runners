# Plan: An App Benchmark Runner With A Real App Contract

Status: **design accepted 2026-08-19; all four DECISIONs answered (see §12). Not yet
implemented.**

This document proposes the concrete interfaces that `SeparateConcerns.md` and
`SeparationAnalysis.md` gesture at but do not specify. Those two argued *that* the
container factory and the application runners should be separable. This one argues *how*
the runner side should be built: what an application must provide, what a cluster must
provide, what a result looks like, and what the file layout and rename path are.

Decisions are recorded inline where they apply and collected in §12.

---

## 1. The problem, restated

`Placement_derecho_opt.pbs` is no longer a placement script. It already does four
different jobs:

1. sweeps container images (via `submit_placement_matrix.sh`, one job per image),
2. sweeps rank/thread decompositions (`CONFIGS` array),
3. verifies the resulting placement, and
4. runs and times an application, extracting a figure of merit.

Only (3) is "placement". The name is the least of it — the real problem is that (4) is
hardcoded per application. There is a `*/xhpcg)` case that writes `hpcg.dat`, and a
`grep -hoE 'GFLOP/s rating of=[0-9.]+'` that knows HPCG's output format. Adding WRF, or
MPAS, or an OSU collective means editing the runner. That does not scale, and it is the
whole reason this needs a contract instead of another `case` arm.

The three things that must be decoupled:

```
  APP CONTRACT              RUNNER                  SITE CONTRACT
  what an app must          app-agnostic,           what a cluster must
  provide so the            site-agnostic           provide so the runner
  runner can drive it       sweep + measure         can launch on it
  ------------------        --------------          ------------------
  prepare / extract         placement probe         scheduler dialect
  metric declaration        wall-clock timing       module bootstrap
  validity self-report      provenance capture      container/host-MPI overlay
  requirements              results.jsonl           topology constants
                                                    bind list, queues
```

`report_placement` and the pathology rules sit *beside* the runner as an optional
instrument, not inside it. (Benchpark calls this a *modifier*; see §2.)

---

## 2. Prior art: what exists, and what to take from it

You asked whether anything out there already does this. Yes — four things do most of it,
and none of them do the one part that is actually hard here.

### Frameworks that do the sweep-and-tabulate job

| Tool | Origin | Config | What it gives you | Why it does not just drop in |
|---|---|---|---|---|
| [**Ramble**](https://github.com/GoogleCloudPlatform/ramble) | Google + LLNL | YAML workspace | `variables`, vectors/`zips`/`matrices` for sweeps, `figures_of_merit` extraction, `success_criteria`, `workspace analyze` → results JSON/CSV, upload/index/report | Package managers are Spack / EESSI / pip. **No container runner.** It assumes it builds or modules the software. |
| [**Benchpark**](https://github.com/LLNL/benchpark) | LLNL | YAML system + benchmark specs on Ramble | Cross-site reproducible specs; **modifiers**: `affinity=on`, `hwloc=on`, `caliper=<variant>` | Inherits Ramble's Spack assumption; adds a system-description model we would have to fit Derecho into. |
| [**JUBE**](https://github.com/FZJ-JSC/JUBE) | Jülich (JSC) | YAML or XML | Parameter combinatorics, script generation + submission (Slurm/PBS), `patternset` + analyser → result tables | Lightweight and the closest in spirit, but no container or host-MPI story at all; you would write the launcher yourself. |
| [**ReFrame**](https://github.com/reframe-hpc/reframe) | CSCS | Python classes | Parameterized tests, sanity + performance patterns, PBS/Slurm backends, and **first-class `container_platform` support (Apptainer/Singularity/Docker/Sarus/Shifter)** | Its container support runs a container; it does not inject the *host* MPI into one. Ramble's authors' critique also applies: ReFrame tests tend to bind tightly to one site's module names. |

**The part none of them do:** `make_apptainer_launcher.sh`. Displacing the container's
`libmpi.so.12` with Cray MPICH's `lib-abi-mpich` shim, getting `LD_LIBRARY_PATH` ordering
right, binding GPFS because NCAR's OpenMPI has a hard `NEEDED` on `libgpfs.so`, and
`OPAL_PREFIX` pinning — that is site × MPI-family surgery, it is the highest-value thing
in this repo, and every framework above would have us supply it as a custom launcher
anyway. So adopting one of them does not remove work; it relocates it and adds a
framework to learn.

### Tools that do the placement-reporting job

- [**xthi**](https://github.com/ARCHER2-HPC/xthi) (Cray/ARCHER2) — the canonical
  MPI+OpenMP affinity checker. Prints rank, thread, node, and pinned CPU, then a
  placement summary. Notably it distinguishes `sched_getcpu()` ("cpu", the `-g` flag)
  from the cpuset ("affinity") — **exactly the distinction `report_placement.cxx` makes,
  and the same reason** (`cpu` is a sample and varies run to run; the mask is stable).
- [**hello_jobstep**](https://github.com/PawseySC/hello_jobstep) (ORNL, via Pawsey) and
  LUMI's `hybrid_check` / `gpu_check` — same idea, plus GPU visibility per rank.
- [NERSC's affinity documentation](https://docs.nersc.gov/jobs/affinity/) is the best
  written explanation of the failure modes we are checking for.
- **Benchpark's `affinity` modifier** is the direct analog of what we have: `affinity=on`
  emits `affinity.mpi.out` with per-rank/per-thread core placement, and when Caliper is
  also on, folds that placement into the run's recorded metadata.

`report_placement` is a reimplementation of xthi with L3/NUMA/socket columns added. That
is fine and it is better instrumented than xthi for our purpose (chiplet straddling is
the Milan-specific thing we care about, and xthi does not report L3). Worth keeping.

### Recommendation

**Build the thin runner, but make its interface a deliberate subset of Ramble's
semantics**, so the exit ramp stays open:

- name the app-side hooks and fields after Ramble's (`figures_of_merit`,
  `success_criteria`, `variables`, `matrices`) — a later translation to a Ramble
  workspace then becomes mechanical rather than a redesign;
- treat placement reporting as a **modifier** (an on/off instrument), following Benchpark,
  rather than baking it into the run loop;
- follow JUBE's split of *measurement* from *judgment* (`patternset` extracts, `analyser`
  decides) — this is the same split §5 recommends for the pathology rules.

And set an explicit exit criterion so this is a decision later rather than drift:

> **Revisit adopting Ramble or ReFrame when we have ≥2 sites and ≥3 apps in the config.**
> Below that, our own runner is smaller than the framework. Above it, theirs is.

If we ever publish benchmark results as a deliverable, look at
[Caliper](https://github.com/LLNL/Caliper)/Adiak for the metadata format and
[Thicket](https://github.com/LLNL/thicket) for the analysis side, rather than growing our
own table tooling.

**DECISION 1 — answered: build thin, borrow vocabulary, revisit later.** Build on the
container infrastructure we already have; keep the exit criterion above as the trigger to
reconsider.

### The borrowed vocabulary, stated explicitly

Borrowing names only helps if the correspondence is written down, so here it is. Every
left-hand column is something this plan defines; the right-hand columns are what the same
idea is called in the framework we would migrate to.

| This plan | Ramble | ReFrame | Notes |
|---|---|---|---|
| `bench/experiments/*.yaml` | workspace `ramble.yaml` | test file + config | ours is flatter: no inheritance |
| `images` × `placements` × `omp_variants` | `variables` + `matrices` | `@parameter` decorators | our `sweep.matrix` is Ramble's `matrices`; `sweep.per_job` has no equivalent in either |
| `app.d/<app>/app.yaml` | application definition (`application.py`) | `RegressionTest` subclass | ours is declarative data, not code — deliberately, so an app author writes YAML + two scripts |
| `prepare` | `executables` / input generation | `@run_before('run')` | |
| `launch` | `executables` | `executable` + `executable_opts` | |
| `extract` → `key=value` | `figures_of_merit` (regex + units) | `@performance_function` | ours moves the regex into the image with the app version it was written for |
| `app.yaml: figures_of_merit` | `figures_of_merit` | `perf_variables` | same noun on purpose |
| `app.yaml: success_criteria` | `success_criteria` | `@sanity_function` | same noun on purpose |
| placement reporting as a toggle | Benchpark `modifier` (`affinity=on`) | no direct equivalent | Benchpark's `affinity.mpi.out` ≈ our `placement_<cell>.out` |
| `topology.json` | Benchpark system description | `system`/`partition` config | ours is probed per job, not declared |
| `sites/<site>.yaml` | Ramble/Benchpark system config | `systems:` in `settings.py` | |
| `results.jsonl` | `workspace analyze` output | `--performance-report` / run report | |
| `bench/collect` | `ramble results report` | `reframe --restore-session` | |

Two asymmetries worth remembering, because they are where a migration would actually cost
something:

- **`sweep.per_job` is ours alone.** Neither framework lets you say "these axes iterate
  inside one scheduler allocation, those axes become separate jobs." Ramble generates one
  job per experiment; ReFrame one job per test instance. Keeping this knob means a migration
  either gives it up or wraps N cells in a single generated script.
- **Nobody models the host-MPI overlay.** In both frameworks it would live in a custom
  launcher/container-platform subclass, i.e. exactly `make_apptainer_launcher.sh` with a
  different call signature.

---

## 3. The app contract

An application contributes four executables and one metadata file. The runner never
learns an application's name.

```
/container/app.d/<app>/
    app.yaml      # metadata, requirements, declared metrics
    prepare       # prepare <rundir>            -- write inputs; exit!=0 = skip this cell
    launch        # print the argv to run       -- optional; default: exec `binary`
    extract       # extract <rundir>            -- print `key=value` lines to stdout
```

### Where these live

**In the image**, installed by `scripts/build_<app>.sh` alongside the binary. The SIF then
fully describes what it can run, the extractor regex travels with the app *version* it was
written against, and a recorded result can name an image digest and mean it.

The cost is that fixing an extractor regex means rebuilding an image. So the runner also
honours `BENCH_APP_DIR=<host path>` to override, bind-mounted in — fast iteration during
development. Results produced with an override get `app_dir_override: true` in the record,
so they are never mistaken for reproducible ones.

**DECISION 2 — answered: in-image as the contract, `BENCH_APP_DIR` as the override.**

### On the "generalized layers" mental model

Worth refining before it hardens, because the metaphor holds for part of this stack and
bends in a specific place. There are really *two* composition mechanisms, and only one of
them is layers:

| | Build-time composition | Run-time composition |
|---|---|---|
| Mechanism | OCI layers, selected by build-args | bind mounts, `LD_LIBRARY_PATH`, env injection |
| Behaviour | **additive** — each layer only adds | **substitutive** — the host MPI *displaces* the container's `libmpi.so.12` |
| Artifacts | `base_os → … → compiler → mpi → iolibs → final`, then the app image `FROM` it | the generated launcher |
| Where it lives | `containers/devenv/Dockerfile`, `containers/apps/Dockerfile` | `make_apptainer_launcher.sh` + the site profile |
| Portable? | yes — that is the image contract | no — deliberately host-specific |

So: the app image genuinely *is* another Docker layer, and that is the strongest argument
for DECISION 2 — the contract rides the topmost build layer, so it travels with the content
it describes. But the Apptainer step is **not** a layer; it is a format change that
*flattens* the OCI layers into one immutable SquashFS. And the host-MPI overlay is a
run-time substitution, which no Docker layer can express — layers cannot remove or replace,
only add. The benchmark runner is not a layer at all: it is a driver that sits outside the
container and invokes it.

Stated that way the model earns its keep, because it predicts the right design: the app
contract belongs in the image (build-time, additive, portable), and the site profile cannot
(run-time, substitutive, host-specific). Baking the site into the image would destroy the
portability the overlay exists to provide.

### The seam has a provenance gap

The OCI → SIF flattening loses layer identity, which matters for §7. Both
`libexec/Deffile` and `libexec/Deffile.apps` bootstrap from a **mutable tag**:

```
From: ghcr.io/kedziora-csg/hpcdev-apps-x86_64:<tag>-latest
```

There is no `%labels` block and no digest anywhere, so a finished `.sif` cannot say which
image build produced it — and two SIFs built a week apart from the same `-latest` tag are
different content with no way to tell them apart. The `image.digest` field in §7's result
record is therefore **currently unfillable**.

Fix at SIF build time, in `libexec/Makefile`: resolve the tag to a digest once
(`docker buildx imagetools inspect --format '{{.Manifest.Digest}}'`, or `skopeo inspect`),
and stamp it into the definition file's `%labels` along with the app name and version.
`apptainer inspect` then recovers it, and the runner reads it into every result row. Without
this, phase 1 records an image name that cannot be resolved to an artifact — which defeats
the point of recording it.

### The geometry ABI

Hooks are handed the run geometry through the environment — the same variables for every
app, so a hook is a small shell script and not an argument-parsing exercise:

| Variable | Meaning |
|---|---|
| `BENCH_APP` | app name |
| `BENCH_RUNDIR` | private, empty, writable cwd for this cell |
| `BENCH_NODES` | nodes in this job |
| `BENCH_RANKS` | total ranks |
| `BENCH_RANKS_PER_NODE`, `BENCH_THREADS` | the decomposition |
| `BENCH_PLACEMENT` | placement name (`ccd`, `numa`, …) — for labelling only |
| `BENCH_SCALE` | app-defined size class (`smoke`, `node`, `weak`, `strong`) |
| `BENCH_TARGET_SECONDS` | how long the run should aim to take |
| `BENCH_CORES_PER_NODE`, `BENCH_CORES_PER_L3`, `BENCH_CORES_PER_NUMA` | probed topology, for apps that size inputs from cache/memory |
| `BENCH_SCRATCH` | site scratch, for apps needing large input trees |

### `app.yaml`

```yaml
app: hpcg
version: "3.1"
binary: /container/bin/xhpcg
requires:
  mpi: true
  openmp: true
  min_ranks: 1
primary_fom: gflops
figures_of_merit:            # Ramble's noun, on purpose
  gflops: {units: GFLOP/s, better: higher}
  wall_s: {units: s, better: lower, provided_by: runner}
success_criteria:
  app_self_validates: true   # extract must emit valid=true|false
notes: |
  Runs shorter than 1800 s are not valid HPCG submissions -- comparison only.
```

### Hook rules

- `prepare` writes into `$BENCH_RUNDIR` and nothing else. Exit non-zero to decline a cell
  (e.g. ranks are not a supported shape) — the runner records `skipped` with the reason
  rather than failing the job.
- `extract` reads only `$BENCH_RUNDIR`, does no network, and prints `key=value` lines.
  Unparseable output is a *missing metric*, not a failed run: exit 0 with no output.
- `extract` emits `valid=true|false` when `app_self_validates` is set. A `valid=false` row
  is recorded but excluded from any "best configuration" comparison.
- **An app with no hooks at all is legal.** Drop in an `app.yaml` with just `binary:` and
  you get wall time. That zero-effort entry point matters for adoption; a contract nobody
  can satisfy in ten minutes will be bypassed.

### What this deletes

From the current PBS script: the `HPCG_NX`/`HPCG_SECONDS` knobs, the `if [ "${APP}" =
"hpcg" ]` block, the `*/xhpcg)` `hpcg.dat` heredoc, and the `GFLOP/s rating` grep. All of
it moves into `/container/app.d/hpcg/{prepare,extract}`, built by `build_hpcg.sh` — which
already writes a reference `hpcg.dat` and already knows the output filename pattern, so
the knowledge is moving to where it already lives.

---

## 4. The site contract

Derecho first, but the abstraction is worth doing now because **the duplication has
already started**: `PBS/OSU_derecho.pbs` and `PBS/OSU_casper.pbs` are two copies of one
idea, and `Placement_derecho.pbs` and `Placement_derecho_opt.pbs` are two more.

### Already site-agnostic (keep as is)

- `mpi_launch_flags` — the PALS-vs-OpenMPI dialect split. This is the right shape already.
- `_launcher_sniff_family` / `_launcher_sniff_compiler`.

### Site-specific but not yet named as such

| Thing | Where it is now |
|---|---|
| `#PBS` directives, `$PBS_NODEFILE` | copied into every PBS script |
| `module --force purge && module load ncarenv/25.10 …` | copied into every PBS script |
| Cray/PALS/libfabric/GPFS paths | `_launcher_common_paths` |
| container-tag → host-module map | `_launcher_compiler_module`, `load_host_modules` |
| bind list (`/glade`, `/local_scratch`, `/opt/cray`, `/usr/lpp/mmfs`) | `make_apptainer_launcher` |
| **topology constants** | `check_placement.sh`: `SMT_SIBLING_STRIDE=128`, `SMT_CPUS_PER_CORE=2`, `MILAN_CORES_PER_L3=8` |
| queue, walltime, account handling | `submit_placement_matrix.sh` + PBS headers |

### Proposed: `sites/<site>.yaml` + `sites/<site>/`

```yaml
site: derecho
scheduler: pbspro                 # pbspro | slurm
submit: qsub
queue: main
node:                             # fallbacks; `topology: probe` overrides at job start
  cores: 128
  smt: 2
  smt_stride: 128
  cores_per_l3: 8
  cores_per_numa: 16
  sockets: 2
topology: probe
modules:
  bootstrap: >
    module --force purge && module load ncarenv/25.10 &&
    module reset && module load apptainer
  compiler_map: {oneapi: intel, gcc14: gcc/14.3.0, nvhpc: nvhpc, gcc: gcc}
container:
  runtime: apptainer
  overlay: cray-mpich-abi         # selects the launcher recipe in libexec/
  binds: [/glade, /local_scratch, /opt/cray, /etc/cray, /usr/lpp/mmfs]
launcher: {mpich: pals, mpich3: pals, openmpi: openmpi}
scratch: "${SCRATCH}"
```

with `sites/derecho/job.tmpl` (the scheduler-directive skeleton) and
`sites/derecho/site.sh` (anything genuinely imperative). Adding Casper is then a second
YAML plus whatever its overlay recipe differs by; adding a Slurm site is a second
`job.tmpl` and a `srun` arm in `mpi_launch_flags`.

### `site.sh` is split out early; the YAML is not

The two halves have very different payback, so they land in different phases.

`sites/derecho/site.sh` exists **as of phase 1**, because without it a PBS script has
no way to answer "where is the harness" except `$(pwd)` — which forces every job to be
submitted from inside the checkout. That is backwards: a benchmark run belongs in a
scratch directory of the operator's choosing, and the harness belongs wherever it was
cloned. Those are independent paths and neither should be derived from the other.
It also removes the `module --force purge && module load ncarenv/25.10 …` bootstrap
that was copied into all five PBS scripts.

It carries five settings and one function — `NCAR_HPC_ROOT`, `BENCH_IMAGE_DIR`,
`BENCH_RESULTS_ROOT`, `BENCH_SCRATCH`, `BENCH_SITE`, and `bench_site_modules` — and is
found in three places, first one found wins: `$BENCH_SITE_CONF`, then
`~/.config/hpcdev/site.sh`, then `sites/<site>/site.sh` walking up from
`$PBS_O_WORKDIR`. The last keeps a submit-from-the-checkout workflow working with no
setup; the middle one is what makes `qsub /path/to/Placement_derecho.pbs` work from any
directory on the machine.

A copy inside the checkout works `NCAR_HPC_ROOT` out from its own location, so two
checkouts cannot be crossed and cloning the repository somewhere new needs no edit. A
copy outside one has nothing to work it out from and must state it — which is the single
line the setup instructions tell you to change.

`sites/derecho.yaml` — scheduler dialect, queue, bind list, topology fallbacks, the
container/host-MPI recipe — stays at **phase 4**, unchanged. It is a *description*
rather than a dependency: nothing is blocked without it, and its shape cannot be
validated until a second site exists to disagree with it. Splitting it out now would be
guessing at Casper's requirements from Derecho's.

### Probe the topology, do not hardcode it

`check_placement.sh` argues — correctly — that `MILAN_CORES_PER_L3` must not be *measured
from the placement report*, because a run that does not fill a node touches only part of
each CCD and would silently under-count, then declare the resulting placement optimal.

That argument is against inferring topology from the *run*. It is not an argument for
hardcoding. Probe the *machine* instead, once per job, on a compute node:

```bash
lscpu -p=CPU,CORE,SOCKET,NODE   # SMT stride, cores/socket, NUMA count
lscpu -C                        # or: lstopo-no-graphics --of xml   (hwloc)
```

Write the result to `topology.json` in the results directory and derive every constant
from it. This keeps the stated intent, removes three Milan-specific constants, makes the
rules correct on Casper and on any future non-Milan node, and captures the topology as
provenance — which we currently do not record at all. Keep the YAML values as fallbacks
for when the probe fails.

---

## 5. Placement reporting: warn only on pathology, and make rules cheap to add

You asked for exactly two things here. The good news is that half of it already exists.

### There are already two checkers, and the sweep uses the wrong one

- `check_placement <file> <expected_L3_groups>` — asserts against a **caller-supplied
  expectation**. Used by `Placement_derecho_opt.pbs` and `submit_placement_matrix.sh
  --collate`, both of which carry a hardcoded `want=2` for the `numa` config.
- `placement_summary <file>` — **derives** the expectation from the data plus topology
  (`ceil(threads / cores_per_l3)`) and prints named pathologies. Used by
  `Placement_derecho.pbs`.

`placement_summary` is already the design you are asking for. The action is to **delete
`check_placement` from the benchmark path** and use `placement_summary` everywhere, which
also removes the duplicated `case "${cfg}" in numa) want=2` logic from the collator.

### The checker cannot express a deliberate experiment

`Placement_derecho_opt.pbs` currently sets, uncommented:

```bash
export OMP_PROC_BIND=spread
export OMP_PLACES=threads
```

`OMP_PLACES=threads` binds each OpenMP thread to a **single logical CPU**.
`report_placement.cxx` reports `nallowed`/`affinity` from `sched_getaffinity` called *on
each OpenMP thread* (confirmed at `scripts/report_placement.cxx:466`), so under this
setting every thread reports `nallowed 1` and an affinity list of one CPU.

`check_placement` requires `nallowed == SMT_CPUS_PER_CORE` (2) and `affinity == c,c+128`.
Both fail. **As committed, every configuration in the sweep reports PLACEMENT NOT AS
INTENDED**, and `--collate` prints `FAIL` for all of them.

The defect is in the *checker*, not the script. Toggling `OMP_PLACES` between `threads` and
`cores` is a deliberate experiment — it is how you ask whether SMT siblings should
participate in the threaded computation — and `check_placement` simply has no way to
represent the `threads` intent. It asserts `OMP_PLACES=cores` against every run regardless
of what the run declared.

So the fix is not to change the script back, it is the argument for the design: **the rules
must be told
the intent.** `OMP_PLACES=cores` → expect `smt_cpus_per_thread=2`; `OMP_PLACES=threads` →
expect 1. Since OpenMP settings are about to become a swept axis (§6), the rule set has to
take them as input.

A second, latent instance of the same class: `max_numa > 1` and `max_sock > 1` are
**absolute** thresholds in `placement_summary`, while the L3 rule is derived. Today's three
configurations top out at 16 threads = one NPS4 domain, so neither fires. A `4:32`
configuration would trip `max_numa > 1` for a rank that *cannot* fit in one NUMA domain.
Derive both the same way L3 is derived.

### Split measurement from judgment

Today one awk program both computes facts and decides pathology, which is why adding a
rule means editing awk in the middle of a `printf`. Split it:

1. **awk emits facts only**, as a flat block — `rows`, `ranks`, `nodes`, `threads`,
   `worst_occ`, `oversub_cores`, `max_core`, `max_l3`, `max_numa`, `max_sock`, `strays`,
   `single`, `roam`, `splitcore`.
2. **bash evaluates a rule table**, where a rule is one line:

```bash
#    name              severity  condition                            message
rule oversubscription  fail  '(( worst_occ > want_smt ))'             '%d core(s) carry more threads than intended (worst %d)' oversub_cores worst_occ
rule unpinned          fail  '(( roam > 0 ))'                         '%d thread(s) free to migrate across cores' roam
rule partial_core      warn  '(( single > 0 && want_smt == 2 ))'      '%d thread(s) on one SMT sibling, not a whole core' single
rule split_mask        fail  '(( splitcore > 0 ))'                    '%d thread(s) masked across two different cores' splitcore
rule l3_straddle       warn  '(( max_l3   > min_l3 ))'                'rank spans %d L3 groups; %d would do' max_l3 min_l3
rule numa_straddle     warn  '(( max_numa > min_numa ))'              'rank spans %d NUMA domains; %d would do' max_numa min_numa
rule socket_straddle   fail  '(( max_sock > min_sock ))'              'rank spans %d sockets' max_sock
```

where `want_smt`, `min_l3`, `min_numa`, `min_sock` are derived from the probed topology
and the run's intent. Adding a pathology is then one line, and the runner's contract with
the rest of the world is just:

- **no rule fires** → print nothing beyond a one-line summary. This is the "only warn if
  something is pathological" behaviour you asked for.
- **`warn` fires** → print it, record it, still compare the timing.
- **`fail` fires** → print it, record it, **exclude the timing from best-configuration
  comparison.** A mis-bound run measures the binding, not the code.

### Make the rules testable

`libexec/fixtures/` already holds `trap_openmpi.out`, `trap_mpich.out`, `bound_mpich.out`.
Add `libexec/fixtures/expected/<fixture>.rules` listing the rule names that must fire, and
`libexec/test_rules.sh` to assert it. Then "easy to add new pathological cases" means:
capture one bad run into `fixtures/`, add one `rule` line, add one expectation file. And
the existing three fixtures immediately become regression tests, which they are not today.

### Parse the CSV rows, not the prose

`report_placement` already emits `csv: rank,thread,nthreads,host,cpu,core,socket,numa,l3,
place,nallowed,affinity` rows with a header. `check_placement.sh` parses the *human*
`MPI rank …` lines with positional `for (i…) if ($i == "core")` scanning. Parse the `csv:`
rows instead — that is the stable machine interface the tool already offers, and it means
a change to the human format cannot silently break the checker.

---

## 6. The configuration file

Host-side authoring format is YAML. **The job never parses YAML**: `bench/submit` expands
the matrix and writes a flat `job.env` (plus `job.json` for provenance) into each results
directory, and the in-job runner sources that. This avoids YAML-in-bash entirely and makes
each job's inputs an artifact you can read after the fact.

```yaml
# bench/experiments/derecho-hpcg.yaml
schema: 1
site: derecho
account: SCSG0001                  # --account overrides
defaults:
  nodes: 2
  walltime: "00:30:00"
  repeats: 3                       # see timing hygiene, §7

images:
  from_make: derecho-hpcg          # ask libexec/Makefile -- one definition of "the six"
  # list: [leap-oneapi-mpich-hpcg.sif, ...]   # or name them explicitly

apps:
  - name: hpcg
    scale: node
    target_seconds: 60

placements:
  - {name: pureMPI, ranks_per_node: 128, threads: 1}
  - {name: ccd,     ranks_per_node: 16,  threads: 8}
  - {name: numa,    ranks_per_node: 8,   threads: 16}

omp_variants:
  # Default is ONE variant.  Measured on HPCG (2026-08-19) the difference between these
  # two is minor at best, so crossing them doubles every sweep for little signal -- opt in
  # per experiment instead, via sweep.matrix below.
  - {name: percore, OMP_PROC_BIND: close,  OMP_PLACES: cores}    # 2 logical CPUs/thread
  # - {name: perthr,  OMP_PROC_BIND: spread, OMP_PLACES: threads}  # 1 logical CPU/thread

sweep:
  matrix:  [images, apps, placements, omp_variants]   # the full cross product
  per_job: [placements, omp_variants]                 # what ONE job iterates
```

**First measured data point.** On HPCG, `OMP_PLACES=threads` versus `cores` made little or
no difference to the score. That is consistent with HPCG being memory-bandwidth-bound — DRAM
is the limit, not core throughput or the shared FPU that SMT siblings contend for — so the
*magnitude* of this axis should be expected to be app-dependent, and an FP-throughput-bound
code (HPL, dense kernels) could behave quite differently. Two consequences:

- keep the toggle, drop it from the default cross-product (above);
- treat "which axes actually move this app" as something `app.yaml` could eventually
  declare, so a sweep does not spend node hours on axes a given app is insensitive to.

`per_job` is the knob that is hardcoded today (one job per image; all placements inside
it). Naming it explicitly lets you trade queue wait against job length without editing a
script — and lets a long app go one-cell-per-job.

`ranks × threads` is currently constrained to `cores_per_node` by prose in the header
comment. Make it a validation in `bench/submit`, but with **two** legal products rather than
one:

| `ranks × threads` | Meaning | SMT siblings |
|---|---|---|
| `cores_per_node` (128) | one thread per physical core | **not** used for compute |
| `cores_per_node × smt` (256) | one thread per hardware thread | both siblings compute |
| anything else | rejected unless `allow_undersubscribed: true` | — |

The rejection matters because `--cpu-bind depth` packs consecutively from core 0, so a
smaller product crowds every rank onto the low chiplets rather than idling cores — a wrong
answer that looks like a valid data point.

The 256 row is the one worth calling out, because it is easy to conflate with `OMP_PLACES`.
**At `ranks × threads == 128`, neither `OMP_PLACES=cores` nor `OMP_PLACES=threads` puts work
on both SMT siblings** — you have 128 threads on 128 cores either way, and the two settings
differ only in whether a thread's mask is one logical CPU or two. Genuinely engaging SMT for
computation requires the 256 product (e.g. `16 ranks × 16 threads`, or `8 × 32`). So
"threads vs cores" and "SMT on vs off for compute" are two different axes, and the config
needs to express both.

### Running the winner

Once the sweep has an answer, the same tool runs the best configuration:

```yaml
profiles:
  production:
    placement: ccd
    omp: percore
    images: [leap-oneapi-mpich-hpcg.sif]
```

`bench/submit --profile production` then runs only that cell. Better:
`bench/collect --emit-profile` **generates that block** from the results, so the
benchmark's output is the production configuration rather than something transcribed by
hand from a table.

**DECISION 3 — answered: YAML, definitively.** Human readability of the experiment
definition is a requirement, not a preference; JSON stays only as the degraded fallback if
PyYAML is unavailable.

### Designing for an eventual local-LLM agent

Asked whether a future agent that authors these configs and app contracts should influence
the design. It does — but almost entirely by *reinforcing* the same choices, with three
cheap additions. It does not argue for a different architecture.

What already helps, unchanged: declarative YAML over imperative scripts; `results.jsonl`
over prose; `key=value` from `extract`; the facts/rules split in §5; `csv:` rows from
`report_placement`. An agent and a careful human want the same things.

The three additions worth making, and they help humans first:

1. **A JSON Schema for both YAML formats** (`bench/schema/experiment.json`,
   `bench/schema/app.json`). This is the single highest-value item: it turns "did I write
   this correctly?" into a check that runs in a second instead of a build failure three
   hours into a queue. It also gives editors autocomplete, and gives an agent a target it
   can validate against without a cluster.
2. **`bench validate` with structured output and stable exit codes.** Expand the matrix,
   check every image exists, check every referenced app declares a contract, print the cells
   that *would* run — submit nothing. Distinguish, by exit code, *config invalid* /
   *image missing* / *app contract missing* / *geometry rejected by the app*. An agent
   cannot read prose failure text reliably; neither can a script.
3. **Keep files small and single-purpose.** A local model has a small context window, so
   five 150-line scripts with a header comment each beat one 700-line runner. This also
   happens to be the right call for review and testing.

What to **avoid** doing for an agent's sake: adding templating, conditionals, or macros to
the YAML to make it more expressive. Agents do worse with clever formats, not better — the
same as humans. And do not build a natural-language front end; the schema *is* the
interface.

The observation that makes this tractable: **the app contract already turns app onboarding
into an agent-sized task.** "Write `prepare` and `extract` for app X, then prove it under
`BENCH_SCALE=smoke` in CI" is bounded, has a fast verifier, and cannot damage anything else.
That is a far better shape for delegation than "modify the runner."

Schema and `validate` are cheap enough that they belong in **phase 3**, alongside the config
file they describe, rather than waiting for phase 6.

---

## 7. The results contract

### What the runner always records, for every cell

`wall_s`, `exit`, the placement verdict and the list of rules that fired. No app
cooperation needed.

### The record

One JSON object per cell, appended to `results.jsonl` in the job's results directory.
JSONL rather than CSV because metric sets differ per app, appending is crash-safe, and
`bench/collect` can flatten to CSV or a table at read time.

```json
{
  "schema": 1,
  "timestamp": "2026-08-17T18:04:11Z",
  "site": "derecho", "job_id": "7024910.desched1", "nodes": 2,
  "image": {"sif": "leap-oneapi-mpich-hpcg.sif",
            "digest": "sha256:…", "os": "leap",
            "compiler": "oneapi", "mpi": "mpich"},
  // digest: requires the SIF-labels fix in §3 -- today's Deffiles bootstrap
  // from a mutable `-latest` tag and record no digest at all.
  "app": {"name": "hpcg", "version": "3.1", "scale": "node",
          "app_dir_override": false},
  "placement": {"name": "ccd", "ranks_per_node": 16, "threads": 8,
                "omp": {"OMP_PROC_BIND": "close", "OMP_PLACES": "cores"},
                "mpiexec_flags": "-ppn 16 --cpu-bind core -d 8",
                "verdict": "ok", "rules": []},
  "repeat": 1,
  "wall_s": 71.4, "exit": 0, "valid": true,
  "metrics": {"gflops": 12.83}
}
```

### Provenance header

You asked that the app output, or a file beside it, carry everything that is in the
`Placement_derecho.pbs` file header. `run_placement()` in that script already writes a
`# key value` block into each `.out`; generalize it into one `emit_provenance` function
used by every cell, and write these siblings into each results directory:

| File | Contents |
|---|---|
| `run.meta` | the `# key value` header: image, digest, compiler, MPI family, nodes, ranks, threads, OMP settings, exact `mpiexec` line, launcher path, site, job id, git SHA of the harness |
| `topology.json` | probed node topology (§4) |
| `modules.txt` | `module list` output |
| `env.txt` | full environment as the run saw it |
| `launcher.sh` | the generated Apptainer launcher, verbatim |
| `job.env` / `job.json` | the expanded configuration this job was given |
| `placement_<cell>.out` | `report_placement` output, header block included |
| `results.jsonl` | the records above |

Keep the `# key value` shape — `grep '^#'` gives a human the header, and it stays
machine-parseable. The rule is: **a results directory is self-contained.** Reading it
should never require the config file, the workflow log, or knowing which script ran.

### What goes to stdout

The same rule settles what the job log should look like, because the two are the same
question asked twice. Both PBS scripts currently print their diagnostics — `module
list`, the environment dump, `ldd`, the generated launcher — into the log.
`Placement_derecho.pbs` spends about 86 lines on it once, which is tolerable.
`Placement_derecho_opt.pbs` spends roughly 375 lines per job on it against about 40
lines of narrative, and two items account for most of that: a 113-line `cat
${launcher}`, and an unfiltered `ldd` repeated for every configuration.

The fix is **not** a `--verbose` flag. Relocate, do not suppress: every file in the
table above is written unconditionally, and stdout carries only what a person reads
while a job is queued or after it fails —

- the geometry of each cell and its placement verdict,
- the figure of merit and the wall time,
- anything that made the runner decline, skip or abort a cell.

A flag that *hides* detail by default is the wrong trade for the case it exists to
serve. Porting to a new site, or bringing up a new app, is exactly when the detail is
wanted — and exactly when re-queuing a job to get it back costs hours. A file costs
nothing and is there either way. So `BENCH_VERBOSE=1` means only "also echo those
files to stdout as they are written", for watching a live job. It changes what is
*displayed*, never what is *recorded*, and no run is ever missing information because
nobody set it.

Two specifics to carry into the rewrite, since they are the current noise and both
dissolve once the loop moves into `bench/runner.sh`:

| Today | Then |
|---|---|
| `cat ${launcher}` into the log | `launcher.sh`, verbatim, in the results directory — already in the table above |
| unfiltered `ldd` per configuration | the one `libmpi` line into `run.meta`, the full `ldd` into a sibling file, once per image rather than once per cell |

Note while moving the second one: it is announced as `--- ldd check on $APP ---` but
inspects `${REPORT_EXE}`, so it has never checked the application binary it names.

### Timing hygiene

- **`SECONDS` has 1-second granularity.** The current `t0=${SECONDS}` is too coarse for
  short cells. Use `date +%s.%N` (SLES 15 ships bash 4.4, so `EPOCHREALTIME` is not
  available).
- `wall_s` is launch-to-exit and **includes** per-rank Apptainer startup and the first
  read of the `.sif` off GPFS. That cold-cache cost lands on whichever cell runs first.
  Either run one discarded warm-up cell per image, or record `warm: false` on the first
  cell so it can be excluded. Prefer the app's own timer for cross-configuration
  comparison and treat `wall_s` as the fallback.
- `repeats:` with min-and-median reporting, not a single sample.
- Record whether the node was shared (`#PBS -l place=…`); an unshared node is a
  precondition for comparing anything.
- Rows with a `fail` placement rule, or `valid=false`, are recorded but never win.

---

## 8. File layout and the rename path

```
containers/deploy/
  bench/
    submit                     # host: read YAML, expand matrix, generate + submit jobs
    runner.sh                  # in-job: site- and app-agnostic sweep body
    collect                    # host: results.jsonl* -> table/CSV; --emit-profile
    experiments/
      derecho-hpcg.yaml
      derecho-osu.yaml
  sites/
    derecho.yaml
    derecho/{job.tmpl,site.sh}
    casper.yaml                # later
  ncar-hpc/
    libexec/                   # unchanged: launcher, placement rules, fixtures, Makefile
    PBS/
      App_benchmarker_derecho.pbs    # was Placement_derecho_opt.pbs
      Placement_derecho.pbs          # KEEP, unchanged in purpose (see below)
      OSU_{derecho,casper}.pbs       # fold into bench/ as an app, then delete
```

### On the rename

`App_benchmarker_derecho.pbs` becomes a **thin** entry point — PBS directives, source the
site profile, `exec bench/runner.sh` — for the hand-`qsub` case. For matrix submission,
`bench/submit` generates a job script per job from `sites/derecho/job.tmpl` and submits
that. Both paths run the same `runner.sh`.

Why generate rather than reuse one static file: scheduler directives cannot be fully
parameterized inside the file. You are already fighting this — `submit_placement_matrix.sh`
overrides `-l select=` and `-l walltime=` on the `qsub` line and smuggles the rest through
`-v NCAR_HPC_ROOT=…,container_img=…,RESULTS_DIR=…`. A generated script puts the real
`select=` in the file, drops the `-v` channel, and leaves behind *the exact script that
ran* as an artifact. JUBE and Ramble both generate; it is the right call.

### Keep the two placement scripts separate

`Placement_derecho.pbs` answers **"does this image work on this host?"** — does the Cray
MPICH ABI shim displace the container's `libmpi`, does the binding come out clean. It is
an image-certification integration test, and it belongs to the factory.

`App_benchmarker_derecho.pbs` answers **"which configuration is fastest?"** It is a
consumer of certified images.

Different questions, different audiences, different cadence. Do not merge them. They
already share everything worth sharing through `libexec/`, which is the correct amount of
coupling.

---

## 9. `hpcg-smoketest-ghcr.yaml` → `app-image-builder-ghcr.yaml`

Current shape: HPCG's name appears in the workflow name, the job name, the tag string, the
Dockerfile path, the smoke-test body (`test -x /container/bin/xhpcg`, the `hpcg.dat`
heredoc, the `GFLOP/s` grep), the artifact name, and the log filename.

Target shape:

```yaml
on:
  workflow_dispatch:
    inputs:
      app: {type: choice, options: [hpcg, osu, wrf, kokkos], default: hpcg}
      os: {type: choice, options: [leap, almalinux9, noble], default: leap}
      compilers: {type: string, default: "oneapi,gcc14,nvhpc"}
      mpis: {type: string, default: "mpich,openmpi"}
      image_version: {type: string, default: "26.08"}
  workflow_call:                # so a controller can drive it
    inputs: { ...same... }
```

Two changes make it genuinely app-generic:

1. **One Dockerfile for all apps.** Replace `containers/apps/hpcg/Dockerfile` with
   `containers/apps/Dockerfile` taking `ARG APP` and running
   `/container/extras/build_${APP}.sh`. The current file is already app-agnostic apart from
   the two `HPCG_`/`xhpcg` strings. Per-app extras go in an optional
   `containers/apps/<app>/args.env` sourced for build args.
2. **The smoke test runs the app contract**, not app-specific YAML steps:

```bash
docker run --rm --env OMP_NUM_THREADS=2 "$app_image" bash -lc '
  d=/container/app.d/'"$app"'
  test -d "$d"                                  # contract present?
  rundir=$(mktemp -d) && cd "$rundir"
  BENCH_SCALE=smoke BENCH_RANKS=2 BENCH_THREADS=2 BENCH_RUNDIR="$rundir" \
    "$d"/prepare "$rundir"
  mpiexec -n 2 $mpiexec_args $("$d"/launch)
  "$d"/extract "$rundir"                        # must print key=value
'
```

That is the payoff of the contract: **CI exercises the same hooks the Derecho benchmark
calls**, so a broken extractor fails in GitHub Actions rather than three hours into a
queued PBS job. `BENCH_SCALE=smoke` is what keeps it seconds long.

Also worth doing here: stamp the app name, version, and `app.yaml` digest into image labels
so a results record can name the exact image it measured.

Note the matrix-axis gotcha from `CLAUDE.md` applies: if `compilers`/`mpis` become
dispatch inputs, they have to be expanded into the matrix via `fromJSON` on a base axis,
not bolted on with `include:`.

**DECISION 4 — answered: it replaces `matrix-smoketest-applications.yaml`**, with
benkirk's consent to the direction.

So phase 5 *deletes* that workflow rather than leaving it beside the new one. Two
consequences:

- The old workflow builds apps inside base images and discards them; the new one publishes
  app-bearing images and smoke-tests them through the app contract. Anything the old matrix
  covered that the new one does not — notably its `arch: [x86_64, aarch64]` axis and its
  `continue-on-error` app list — has to move into `app-image-builder-ghcr.yaml`'s inputs, or
  be dropped deliberately rather than by omission. Enumerate that before deleting.
- `matrix-smoketest-applications.yaml` is currently in **`UpstreamPRPlan.md` Bucket A** (PR 2
  edits it to swap `hello_world_mpi` → `report_placement`). Upstream still has the file, so
  that hunk stays valid for PR 2 — but with benkirk's consent on record, the replacement
  itself becomes a *future* upstream contribution rather than a fork-only change. Noted
  there.

---

## 10. Phasing

Each phase is independently useful and independently revertible.

| Phase | Work | Why first / value |
|---|---|---|
| **0** | Split measurement from judgment in `check_placement.sh`; rule table with severities; probe topology into `topology.json`; make `want_smt` follow `OMP_PLACES`; derive the NUMA/socket thresholds; turn `fixtures/` into a test | Fixes the FAIL-everything bug in §5, and nothing else can be trusted until the checker is. No renames, no new files outside `libexec/`. |
| **1** | `emit_provenance`, `run.meta`, `results.jsonl`, `bench/collect`; **stamp the source image digest into SIF `%labels`** (§3); **quiet the job log by relocating the diagnostics into the sibling files, with `BENCH_VERBOSE=1` to echo them** (§7); **`sites/derecho/site.sh` so a job can be submitted from anywhere** (§4) | Results become self-contained and machine-readable. Still HPCG-specific. Without the digest stamp, `image.digest` cannot be filled. The stdout cleanup is the same edit as writing the sibling files, so it costs nothing here and would be duplicated work done separately. |
| **2** | App contract: `/container/app.d/<app>/{app.yaml,prepare,launch,extract}` installed by `build_<app>.sh`; `libexec/app_contract.sh` drives it; runner stops knowing about `hpcg.dat`; `bench/collect` ranks by the app's declared `primary_fom` and `better:` | The structural change. Every HPCG string is gone from the PBS script. Proven by adding OSU as the second app with no runner edit — deliberately unlike HPCG (no input file, flags via `launch`, results on stdout), and `libexec/test_app_contract.sh` exercises both off-cluster. |
| **3** | `bench/{submit,runner.sh}` + YAML config + generated job scripts; **JSON Schema for both YAML formats + `bench validate` with stable exit codes** (§6); rename to `App_benchmarker_derecho.pbs`; retire `submit_placement_matrix.sh` | The rename lands here, after it is true. Schema and `validate` come now, not at phase 6 — they pay for themselves in human use and are what make agent authoring viable later. |
| **4** | `sites/derecho.yaml` (the declarative half; `site.sh` landed in phase 1, see §4); fold the remaining `OSU_*.pbs` / `FE_derecho.pbs` module bootstraps onto it; add Casper | Second site validates the abstraction. Doing this before Casper is speculative. |
| **5** | `app-image-builder-ghcr.yaml` + generic `containers/apps/Dockerfile`; **delete `matrix-smoketest-applications.yaml`** after enumerating what it covered (§9) | CI now validates the contract on every app build. |
| **6** | Decision point: Ramble/ReFrame re-evaluation against the §2 exit criterion, using the mapping table in §2 | Deliberate, with data. |
| **6+** | Agent-assisted app onboarding, on top of the phase-3 schema | Optional. The contract, not the tooling, is what makes it possible. |

Phases 0–2 are worth doing regardless of whether you accept the rest of this document.

---

## 11. Open questions

All four DECISIONs are answered — see §12. What remains open:

1. **Repo boundary.** This plan keeps everything in one repo and makes the boundary visible
   through directories (`bench/`, `sites/`, `containers/apps/`), which is what
   `SeparationAnalysis.md` recommends. Does `bench/` belong under `containers/deploy/` at
   all? It is not a container and not a deployment. `benchmark/` at the repo root may be
   the more honest location, and a cleaner thing to move out later.
2. **Where do results live?** Per-job directories under `results/` are fine for one user.
   If these become a shared record, they need a naming convention that includes site, date,
   and harness git SHA — and a decision about whether they are committed, published as
   workflow artifacts, or pushed somewhere.
3. **GPU placement.** `report_placement` is CPU-only. Benchpark separates
   `affinity.mpi` from `affinity.cuda`/`affinity.rocm`, and `hello_jobstep`/`gpu_check`
   report per-rank GPU visibility. Casper and any GPU app will need this. Add it to the
   contract now as an optional field, or defer?
4. **Multi-node scaling.** `nodes` is currently a single value per job. Weak/strong scaling
   studies need it as a swept axis, which changes what "the same problem" means across
   cells — an app concern (`BENCH_SCALE`) as much as a runner one.
5. ~~**Does the HPCG OpenMP reduction patch survive phase 2?**~~ **Answered: kept, on its
   own merits rather than as a defence.** It was carried as insurance against an assertion
   later traced to an oneAPI 2026.0.0 codegen bug, which it did not in fact fix. But the
   change stands independently: replacing an unnamed `#pragma omp critical` with
   `reduction(+:...)` is semantically identical for a sum and removes a serialization point
   that every row of the local problem passes through during problem generation — roughly
   1.1M entries per rank at the 104³ default. Phase 1's measurements show setup is a real
   cost (19–23 s of an 83 s threaded cell), so this is not a hypothetical.

   Removing it would be a change with no evidence behind it and a six-image rebuild plus
   re-run to verify, so it stays. The build already fails loudly if upstream moves the code
   out from under the patch, which is the risk worth guarding. If anyone wants it settled:
   build one image with and without, and compare HPCG's own `Benchmark Time Summary` setup
   figures at 8 and 16 threads.

---

## 12. Decision log

Answered 2026-08-19.

| # | Question | Answer |
|---|---|---|
| 1 | Thin runner, or adopt ReFrame up front? | **Thin runner**, built on the container infrastructure we already have, borrowing Ramble/ReFrame vocabulary. Correspondence table in §2; revisit at ≥2 sites × ≥3 apps. |
| 2 | App contract in the image or on the host? | **In the image**, `BENCH_APP_DIR` as the development override. The app image is genuinely another build layer, so the contract travels with the content — see the layers discussion in §3. |
| 3 | YAML, or JSON-only stdlib? | **YAML.** Human readability is a requirement. JSON remains the fallback if PyYAML is missing. A future local-LLM agent reinforces this choice and adds schema + `validate` at phase 3; it does not argue for a different architecture. |
| 4 | Replace `matrix-smoketest-applications.yaml`? | **Yes, replace it**, with benkirk's consent. Phase 5 deletes it after enumerating its coverage. |

Two findings surfaced while answering these, both folded into the phases above:

- The SIF-to-image **provenance gap** (§3): today's Deffiles bootstrap from a mutable
  `-latest` tag and record no digest, so `image.digest` in §7 is unfillable until phase 1
  stamps it into `%labels`.
- **`sweep.per_job` has no equivalent** in either Ramble or ReFrame (§2), so it is a real
  cost to weigh at the phase-6 decision rather than a free abstraction.

---

## Sources

- [Ramble](https://github.com/GoogleCloudPlatform/ramble) ·
  [docs](https://ramble.readthedocs.io/en/latest/) ·
  [SC'23 paper](https://dl.acm.org/doi/fullHtml/10.1145/3624062.3624132)
- [Benchpark](https://github.com/LLNL/benchpark) ·
  [modifiers](https://software.llnl.gov/benchpark/modifiers.html) ·
  [adding an experiment](https://software.llnl.gov/benchpark/add-an-experiment.html)
- [JUBE](https://github.com/FZJ-JSC/JUBE) ·
  [docs](https://apps.fz-juelich.de/jsc/jube/docu/index.html)
- [ReFrame](https://github.com/reframe-hpc/reframe) ·
  [docs](https://reframe-hpc.readthedocs.io/)
- [xthi (ARCHER2)](https://github.com/ARCHER2-HPC/xthi) ·
  [hello_jobstep](https://github.com/PawseySC/hello_jobstep) ·
  [NERSC process and thread affinity](https://docs.nersc.gov/jobs/affinity/) ·
  [LUMI binding training](https://lumi-supercomputer.github.io/LUMI-training-materials/2day-20240502/07_Binding/)
- [Caliper](https://github.com/LLNL/Caliper) · [Thicket](https://github.com/LLNL/thicket)
