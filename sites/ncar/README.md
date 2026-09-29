# Guide to Deploying and Testing Apptainer Containers on NCAR HPC (Derecho & Casper)

This document describes how this repository builds, deploys, and runs Apptainer (formerly Singularity) containers at native speed on NCAR's supercomputer (Derecho) and data-analysis cluster (Casper).

---

## 1. How the Repository Deploys Apptainer Containers

This repository employs a **hybrid building pattern**:
1. **GitHub Actions (Cloud)**: Builds multi-layer Linux-based Docker images of the HPC developer software stacks, publishing them to a container registry (DockerHub or GitHub Container Registry - GHCR) under the name `hpcdev` or similar. No self-hosted runners or NCAR infrastructure are used during the Docker-building phase.
2. **NCAR Cluster (On-Platform SIF Construction)**: Once the Docker images are in the registry, operators or researchers log into Derecho/Casper to rebuild them as Apptainer Singularity Image Format (`.sif`) files. SIF builders can bind low-level system drivers and directories which can only be done directly on-platform.

### Key Deployment Components

All NCAR-specific deployment files are located under [sites/ncar/](./) — this directory — with the pieces that are deliberately **not** NCAR-specific at the top of the repository:

* [hpcrun/](../../hpcrun/) — the runner.  Its shell libraries (the launcher, the placement checker, the topology probe, provenance and results) are in `hpcrun/lib/`, and its off-cluster tests in `hpcrun/tests/` (`make -C hpcrun test`). `submit` and `validate` expand a declarative experiment on the login node; `runner.sh` is the in-job sweep, with no site and no application in it; `collect` turns the resulting `results.jsonl` files into a table or a runnable configuration. Nothing here names Derecho.
* [hpcrun/env.sh](../../hpcrun/env.sh) — source it, or add that one line to `~/.bashrc`, and `validate`, `submit`, `collect` and `sitegen` work by name from any directory. Then a run is: make a directory where you want the output, `cd` into it, `submit <experiment> --account <PROJECT>`. It sets `PATH` and deliberately nothing else — exporting `HPCRUN_ROOT` or `HPCRUN_IMAGE_DIR` would be honoured by every clone's `cluster.sh` and would silently drive one checkout's jobs at another's images. `bench_env_show` says which checkout you are typing at.
* [sites/](../) — what one machine is, in three levels. `ncar.yaml` is the **site**: the module naming conventions, the `ncarenv` bootstrap, GLADE, the container runtime — everything every NCAR machine shares. `ncar/derecho.yaml` and `ncar/casper.yaml` are the **clusters**, holding only what differs: scheduler dialect, module bootstrap, node geometry, container binds and the host-MPI recipe. `ncar/derecho/cluster.sh` is the file every job actually sources — four hand-edited paths that belong to you, plus a block `hpcrun/sitegen` generates by merging those two YAMLs, so nothing on a compute node parses YAML and no value is written down twice. `hpcrun/templates/job.pbspro.tmpl` is the scheduler-directive skeleton `submit` generates from, shared by every PBS site. Adding a machine is one more cluster YAML and one more `cluster.sh`; adding an organisation is one more site YAML.

* **Template-Driven Builds**: 
  The deployment uses a Singularity definition template, [sif/Deffile](../../sif/Deffile).
  The GNU Makefile [sif/Makefile](../../sif/Makefile) utilizes this template to construct custom `.def` and build `.sif` files. By sourcing [sites/ncar/sif_env.sh](sif_env.sh), the Makefile configures user/system paths (e.g., custom `TMPDIR` and `APPTAINER_CACHEDIR` stored in paths like `${WORK}/.apptainer-cache/`) to avoid quota limits on home directories during build.

* **MPI on High-Performance Interconnects**:
  To achieve native MPI and GPU-aware MPI performance, containerized applications must interface with NCAR’s high-performance interconnect (Cray CXI fabric on Derecho) and system libraries.
  The PBS test scripts dynamically generate a launching wrapper `apptainer-launch-${NCAR_HOST}-${LMOD_FAMILY_MPI}.sh` inside the PBS job environment.
  The launcher overrides performance-critical environment variables and binds host-system libraries and files:
  - **Derecho (Cray MPICH)**: Maps `/opt/cray` and `/usr/lib64`. It overrides `LD_LIBRARY_PATH` to prioritize Cray MPICH ABI-compatible paths (e.g., `${CRAY_MPICH_DIR}/lib-abi-mpich`) and preloads the Cray GPU Transport Layer (GTL) library (`libmpi_gtl_cuda.so`) for GPU communication.
  - **Casper / Derecho (NCAR OpenMPI)**: Binds the NCAR OpenMPI environment path `${NCAR_ROOT_OPENMPI}`, GPFS file systems `/usr/lpp/mmfs`, and configures UCX flags such as `UCX_POSIX_USE_PROC_LINK=n`. This bypasses permission limitations and guarantees fast inter-node communication.
    The GPFS bind is **not optional**: NCAR's OpenMPI is built with ROMIO's GPFS backend, so `libmpi.so.40` has a hard `NEEDED` on `libgpfs.so`. On the host that resolves out of `/etc/ld.so.conf`; inside the container it does not, and every rank dies before `main()` with `libgpfs.so: cannot open shared object file`. `/usr/lpp/mmfs/lib` must therefore also be on the injected `LD_LIBRARY_PATH`, not just bind-mounted. The Cray MPICH ABI shim has no such dependency, which is why only the OpenMPI path needs it.

---

## 2. Do I Need a Self-Hosted Runner?

**No, you do not need to create or configure a self-hosted GitHub Actions runner.**

* **Docker builds and pushing**: Handled fully by standard public GitHub-hosted runners (`ubuntu-latest` as defined in workflows such as [build-hpc-dev-image-ghcr.yaml](.github/workflows/build-hpc-dev-image-ghcr.yaml)).
* **Apptainer / SIF conversion**: Intended to be run directly on the Derecho/Casper platforms because compiling SIF files must leverage the platform's local scratch file system and can only pull images natively over NCAR internal systems. Operators or users run simple shells/Make commands to create SIF files on NCAR nodes.

---

## 3. How to Deploy and Rebuild Images on Derecho / Casper

**Coming from the old layout** (everything under `containers/deploy/`, before
phase 4.7a)?  After `git pull`, once:

* move your images: `mv containers/deploy/ncar-hpc/libexec/*.sif sif/`, or set
  `HPCRUN_IMAGE_DIR` to wherever you keep them.  Git does not move ignored files,
  so they are still in the old directory; the `.def` files need not move, `make`
  regenerates them.
* if you copied a profile to `~/.config/hpcdev/`, delete it and use
  `HPCRUN_ROOT` instead (Step 4.2a).  The old directory is no longer searched.
* every `BENCH_` variable is now `HPCRUN_`: `BENCH_IMAGE_DIR` is
  `HPCRUN_IMAGE_DIR`, `BENCH_SITE_CONF` is `HPCRUN_SITE_CONF`, `BENCH_APP_DIR`
  is `HPCRUN_APP_DIR`, and so on.  Set them by their new names wherever you set
  them by hand -- in `~/.bashrc`, or on a `qsub -v` line.  Images built before
  the rename keep working: the runner still hands their hooks the old names.
* type `hpcrun/` where you typed `containers/deploy/bench/`.

Follow these steps to deploy and build the `.sif` images on NCAR clusters:

### Step 3.1: Log in and Clone Repository
Log into Derecho or Casper and clone this repository:
```bash
ssh <username>@derecho.hpc.ucar.edu
git clone https://github.com/ncar-cisl/demo_github_actions.git
cd demo_github_actions
```

### Step 3.2: Load System Modules
Load the Apptainer module:
```bash
module purge
module load ncarenv/25.10  # Or equivalent current environment
module load apptainer gcc cuda
```

### Step 3.3: Convert a Target Image
To build a specific variant (e.g. `almalinux9-gcc-openmpi-cuda`), navigate to the `sif` directory and execute `make`:
```bash
cd sif
make almalinux9-gcc-openmpi-cuda.sif
```
This automated flow will:
1. Parse the template [sif/Deffile](../../sif/Deffile) into a custom definition file `almalinux9-gcc-openmpi-cuda.def`.
2. Sourcing [sites/ncar/sif_env.sh](sif_env.sh) will allocate healthy caching folders inside your High-Performance storage.
3. Call `apptainer build` using the corresponding Docker image hosted on the container registry.
4. Set up an executable shortcut under `sif/bin/` automatically mapping to [sif/wrap_apptainer.sh](../../sif/wrap_apptainer.sh) for execution.

To build the whole set a cluster runs, name the cluster: `make derecho` and
`make derecho-hpcg` build Derecho's six base and six HPCG images, `make casper`
and `make casper-hpcg` Casper's three.  Each set is stated once, in the
`images:` block of [derecho.yaml](derecho.yaml) or [casper.yaml](casper.yaml),
as an OS, a list of compilers and a list of MPI families; `hpcrun/sitegen
--write` turns it into the `images.mk` beside that cluster's `cluster.sh`, which
`sif/Makefile` includes.  A compiler with no host module, or an MPI family the
cluster cannot host, is refused there rather than built.

---

## 4. How to Test Your Containers on Derecho and Casper

To verify complete operation of MPI, GPU mappings, and storage directories, submittable PBS scripts are provided.

### Step 4.1: Interactively Run a Container (Smoke Test)
You can directly run interactive commands in the newly generated `.sif` container through the wrap script:
```bash
bin/almalinux9-gcc-openmpi-cuda "echo 'Hello from high-performance container' && nvidia-smi"
```

### Step 4.2: Submit a Batch Microbenchmarks Test Job
To test real multi-node execution and inter-node MPI performance using OSU Micro-Benchmarks, submit one of the pre-configured PBS scripts in [sites/ncar/legacy/](legacy/):

**On Derecho:**
Ensure that the target container variable `container_img` in [sites/ncar/legacy/OSU_derecho.pbs](legacy/OSU_derecho.pbs) matches the `.sif` file you compiled, then submit:
```bash
qsub sites/ncar/legacy/OSU_derecho.pbs
```

**On Casper:**
Ensure that your target file in [sites/ncar/legacy/OSU_casper.pbs](legacy/OSU_casper.pbs) is built, then submit:
```bash
qsub sites/ncar/legacy/OSU_casper.pbs
```

### Step 4.2a: Running a Job From Anywhere

The PBS scripts get their paths from a **site profile**,
`sites/ncar/derecho/cluster.sh`, rather than from the directory you
submitted from. So a run can live wherever you want its results.

**Submitting from inside the checkout: nothing to set up.** The scripts walk up
from the submission directory, find `sites/ncar/derecho/cluster.sh`, and work the paths
out from where that file itself lives.

**Submitting from anywhere else: name your clone.** Set `HPCRUN_ROOT` once, in
`~/.bashrc`, and pass it to the job by name:

```bash
export HPCRUN_ROOT=<checkout>/hpcrun          # once, in ~/.bashrc
qsub -A <PROJECT> -v HPCRUN_ROOT,APP=hpcg,container_img=<checkout>/sif/leap-oneapi-mpich-hpcg.sif \
    <checkout>/sites/ncar/derecho/App_benchmarker_derecho.pbs
```

PBS does not hand your environment to a job, so the name has to be in the `-v`
list; a name with no `=value` is copied from the shell you run `qsub` in. The
job then finds `sites/*/<cluster>/cluster.sh` inside that clone. The clone has
a profile for every cluster, so the same line works on Derecho and on Casper,
which share a home directory, and there is no copy to go stale. If the job
cannot find a profile, its error says what `HPCRUN_ROOT` it received.

A copy in `~/.config/hpcrun/cluster.sh` still works, for the one cluster it
describes, but it goes stale whenever a description changes; `HPCRUN_ROOT` is
the better choice. Or name one profile outright for the session:

```bash
export HPCRUN_SITE_CONF=<checkout>/sites/ncar/derecho/cluster.sh
```

The scripts look in four places, first one found wins: `$HPCRUN_SITE_CONF`,
then `sites/*/<cluster>/cluster.sh` in the clone `$HPCRUN_ROOT` names, then
`~/.config/hpcrun/cluster.sh` if it describes that cluster, then
`sites/*/<cluster>/cluster.sh` walking up from the submission directory.
`hpcrun/submit` and `hpcrun/validate` search the same way.

**What the profile sets:**

| Name | Meaning |
|---|---|
| `HPCRUN_ROOT` | the clone's `hpcrun/` — where `runner.sh`, its `lib/` and the sweep tools live |
| `HPCRUN_IMAGE_DIR` | where the `.sif` images live (default: the clone's `sif/`) |
| `HPCRUN_RESULTS_ROOT` | where results directories are created (default: the submission directory) |
| `HPCRUN_SCRATCH` | big, fast, purgeable space for apps that stage large inputs |
| `HPCRUN_QUEUE` | the queue `hpcrun/submit` puts jobs in |
| `HPCRUN_CORES_PER_NODE`, `HPCRUN_SMT` | what one node has, so `hpcrun/validate` can reject an illegal `ranks × threads` before a job is queued. The job itself probes `lscpu` and uses that instead |
| `bench_site_modules` | the module set-up every job here starts from |

Every one honours a value that is already set, so a one-off change needs no
edit at all:

```bash
qsub -v HPCRUN_RESULTS_ROOT=$SCRATCH/hpcdev-bench sites/ncar/derecho/Placement_derecho.pbs
```

### Step 4.2b: Sweeping a Matrix — `hpcrun/submit`

An **experiment** says what to sweep: which images, which applications, which
rank/thread decompositions, and how the cross product is split into jobs. It is
YAML, it lives in
[hpcrun/experiments/](../../hpcrun/experiments/), and **the job
never reads it** — `hpcrun/submit` expands the matrix on the login node and
writes a flat `job.env` into each results directory.

```bash
cd <checkout>/hpcrun
./validate derecho-hpcg                        # expand it, check it, submit nothing
./submit   derecho-hpcg --account <PROJECT>    # six jobs, three cells each
```

`validate` is worth running first every time. It expands the matrix, checks
every `.sif` exists, checks every image carries a contract for the app, checks
the geometry, and prints the cells that *would* run. It costs a second, against
a queue wait for the same answer.

It also has **stable exit codes**, so a script or a CI step can act on the
result rather than parse prose:

| Code | Meaning |
|---|---|
| 0 | fine |
| 2 | bad command line |
| 3 | the experiment does not parse, or fails `hpcrun/schema/experiment.json` |
| 4 | a placement's `ranks × threads` is not a legal product for this node |
| 5 | a named `.sif` is not on disk |
| 6 | an image carries no contract for the app |

The two schemas — [`hpcrun/schema/experiment.json`](../../hpcrun/schema/experiment.json)
and [`hpcrun/schema/app.json`](../../hpcrun/schema/app.json) — are also what an editor
uses for autocomplete, and what makes an experiment or a contract something you
can check without a cluster:

```bash
./validate --app ../../../scripts/app.d/*/app.yaml
```

Every key of both formats, with its type, its constraints and what it means, is
tabulated in [`hpcrun/schema/README.md`](../../hpcrun/schema/README.md). That file is
generated from the schemas by `hpcrun/schemadoc`, so it cannot describe a key that
does not exist or miss one that does; `test_bench.sh` fails if it is stale.

**Useful options:**

```bash
./submit derecho-hpcg --dry-run                # write job.pbs/env/json, submit nothing
./submit derecho-hpcg --nodes 4 --walltime 01:00:00
./submit derecho-hpcg --images "leap-oneapi-mpich-hpcg.sif"
./submit derecho-hpcg --account <PROJECT> --profile production   # just the winner
```

Each job gets its own directory holding **what it was asked to do** as well as
what it found: `job.pbs` (the generated script, with real `#PBS` directives —
the exact thing that ran), `job.env` (the flat expansion the runner sources) and
`job.json` (the same, structured).

#### Editing an experiment

Two knobs matter more than the rest.

`sweep.per_job` decides how the cross product is cut into jobs. It is the trade
between queue wait and job length, and it is a line rather than a script edit:

```yaml
sweep:
  matrix:  [images, apps, placements, omp_variants]
  per_job: [placements, omp_variants]   # one job per image, all cells inside
  # per_job: []                         # one cell per job -- for a long app
```

`placements` states only what each configuration *asks* for. Whether it got it
is derived from the topology the job probes, so there is no expectation to keep
in step. `ranks_per_node × threads` has exactly two legal products — 128 (one
thread per physical core) or 256 (one per hardware thread, both SMT siblings
computing). Anything else is refused, because `--cpu-bind depth` packs from core
0: a smaller product does not idle the spare cores, it crowds every rank onto
the low chiplets, which is a wrong answer that looks like a valid data point.

Note that "128 with `OMP_PLACES=threads`" is **not** SMT: at 128 you have 128
threads on 128 cores either way, and the setting only changes whether a thread's
mask is one logical CPU or two. Engaging SMT for computation takes the 256
product, e.g. `16 ranks × 16 threads`.

### Step 4.2c: Benchmarking One Image By Hand

For iterating — a new image, a new contract, a fix you want to see fail fast —
skip the experiment file:

```bash
qsub -A <project> -v APP=hpcg /path/to/sites/ncar/derecho/App_benchmarker_derecho.pbs
qsub -A <project> -v APP=osu,OSU_BENCHMARK=osu_allreduce \
    /path/to/sites/ncar/derecho/App_benchmarker_derecho.pbs
```

Both paths run the same [`hpcrun/runner.sh`](../../hpcrun/runner.sh). With no
`job.env` to read, it derives its three cells from the topology it probes — one
rank per core, one per L3, one per NUMA domain — which on Derecho is exactly
128×1, 16×8 and 8×16.

The runner knows nothing about either app. What to write before the run, how to
launch it, and how to read its output all come from `/container/app.d/<app>/` —
see [`scripts/app.d/README.md`](../../../scripts/app.d/README.md). Adding a third
application is a directory there and a line in its `build_<app>.sh`; it is not a
change to the runner.

A bare executable also works, and gets you wall time and a placement verdict:

```bash
qsub -A <project> -v APP=/glade/work/$USER/bin/wrf.exe \
    sites/ncar/derecho/App_benchmarker_derecho.pbs
```

To fix an extractor without rebuilding an image, point `HPCRUN_APP_DIR` at a copy
of the contract on a filesystem the container binds (on Derecho, `/glade`):

```bash
qsub -A <project> -v APP=hpcg,HPCRUN_APP_DIR=/glade/work/$USER/app.d ...
```

Rows produced that way carry `app_dir_override: true`, so they are never mistaken
for reproducible ones.

### Step 4.2d: What a Benchmark Job Leaves Behind

A results directory is self-contained: reading it never requires the PBS script,
the job log, or knowing what was submitted.

| File | Contents |
|---|---|
| `results.jsonl` | one JSON object per measured run — the machine-readable record |
| `job.pbs`, `job.env`, `job.json` | what this job was asked to do, generated by `hpcrun/submit` (absent for a hand `qsub`) |
| `run.meta` | the job-level `# key value` header: image, digest, geometry, launcher, job id, harness SHA |
| `topology.json` | the node topology this job probed; every placement threshold is derived from it |
| `modules.txt`, `env.txt` | the environment the run actually had |
| `launcher.sh` | the generated Apptainer launcher, verbatim |
| `ldd_*_host.txt` | linkage through the launcher, i.e. after the host libraries displace the container's |
| `placement_<cfg>.out` | `report_placement` output, provenance header first |
| `app.yaml` | the contract that was in force: what declared each metric, and which one decides |
| `run_<cfg>[_r<n>]/` | the app's own working directory (`$HPCRUN_RUNDIR`): inputs, `app.out`, `metrics.kv`, `prepare.log`. One per repeat when `repeats:` is more than 1 |

Tabulate one or many jobs:

```bash
hpcrun/collect <results-root>          # one line per cell
hpcrun/collect <results-root> --best   # the winning cell per app
hpcrun/collect <results-root> --per-run   # every repeat
hpcrun/collect <results-root> --format csv
```

`collect` never lets a row win if its placement verdict is `fail`, if the app
reported itself invalid, or if it exited non-zero — a mis-bound run measures its
binding, not the code.

An experiment's `repeats:` runs each cell several times, and `collect` ranks on
the **median**: a mean follows the one run that hit a noisy neighbour, and a
single sample of a shared machine is not a measurement. The min is printed
beside it, because the gap between the two is what says whether a difference
between two configurations means anything.

When the sweep has an answer, `collect` writes it as a runnable configuration
rather than a table you retype:

```bash
hpcrun/collect <results-root> --emit-profile >> hpcrun/experiments/derecho-hpcg.yaml
hpcrun/submit derecho-hpcg --account <PROJECT> --profile production
```

The job log itself carries only the narrative: each cell's geometry, its
placement verdict, its figure of merit, and anything that aborted it. Set
`HPCRUN_VERBOSE=1` to also echo the captured files as they are written — useful
when bringing up a new machine or a new app, where you are watching the job
rather than reading it afterwards. It changes what is displayed, never what is
recorded.

### Step 4.3: Understanding the GPU Setup Wrapper
To map multiple MPI ranks smoothly to available hardware accelerators, the job uses the custom helper script [sites/ncar/legacy/set_gpu_rank](legacy/set_gpu_rank). It extracts local/global rank variables automatically mapping each rank to a physical GPU, validating operations such as:
```bash
mpiexec set_gpu_rank ./apptainer-launch-*.sh /container/osu-micro-benchmarks/7.5/libexec/osu-micro-benchmarks/mpi/pt2pt/osu_latency D D
```
This tests device-allocated memory-to-memory GPU communication over the low-latency fabric.
