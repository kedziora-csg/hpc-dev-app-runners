# Machine descriptions

`sites/` says what each machine is, so nothing else in the repository has to.
There are three levels, and each states only what the level above does not:

```
sites/
  <site>.yaml              the SITE: what all its clusters share -- module
                           naming, the module bootstrap, shared filesystems,
                           the container runtime, default paths
  <site>/
    <cluster>.yaml         a CLUSTER: its scheduler and queue, its node types
                           (sub-clusters), its host-MPI recipes, its images,
                           its host libraries
    <cluster>/cluster.sh   what every job sources: generated from the two
                           YAML files, plus four optional paths of your own
```

The YAML files are the authority, and `hpcrun/schema/cluster.json` defines
them. [hpcrun/schema/README.md](../hpcrun/schema/README.md) lists every key
and what it means. `cluster.sh` is generated from the YAML by
`hpcrun/sitegen`, and a test fails while it is stale. So you never edit the
generated block, and no value is written down twice. NCAR's two clusters,
Derecho and Casper, are worked examples. [ncar/README.md](ncar/README.md)
covers running on them.

## Adding a cluster

The aim: everything the machine can answer is asked of the machine, and
everything it cannot is a marked TODO, never a guess. Casper took three tries
because its first description came from a documentation table. That table
named a processor type the scheduler did not hand out and a CPU count the
scheduler would not grant.

### 1. Draft the description from a login node

```bash
hpcrun/clusterinit draft <site>/<cluster>        # e.g. tacc/stampede3
```

This writes `sites/<site>/<cluster>.yaml`, and a skeleton
`sites/<site>.yaml` if the site is new. It asks the machine for the
following.

| What | Asked of |
|---|---|
| scheduler | which of `qsub`/`pbsnodes` or `sbatch`/`sinfo` is on `PATH` |
| node types, and the CPUs a job may request | `pbsnodes -a -F json` (grouped by `cpu_type`, or `--select-attr`), or `sinfo` (partition, CPUs, sockets x cores x threads) |
| distro, and so the base-image OS | `/etc/os-release` (leap, almalinux*N*, jammy, noble) |
| compiler modules for the image tags | Lmod: `intel`/`intel-oneapi-compilers` for oneapi, `gcc/14.*` for gcc14, `nvhpc`, `aocc` |
| host MPI, and its install-prefix variable | Lmod: `openmpi`, `cray-mpich`, and `module show` for the variable |
| MKL as a host library | Lmod: the default `mkl` module's `MKLROOT` |
| container runtime | an `apptainer` or `singularity` module or binary |

The draft is marked `verified: false`. Anything required that it could not
determine is left commented out with a TODO, so the next step names exactly
what is missing.

### 2. Measure a compute node

```bash
hpcrun/clusterinit probe-job <site>/<cluster> --select cpu_type=genoa --account <PROJECT>   # PBS
hpcrun/clusterinit probe-job <site>/<cluster> --select <partition>    --account <PROJECT>   # Slurm
```

This writes a one-CPU, five-minute job beside the description. Submit it as
the command prints. Its log ends in a `node:` block to paste: cores, SMT,
sockets, SMT stride, cores per L3 and per NUMA domain, all measured by the
same `probe_topology` every job runs, plus the x86-64 level the node supports.
Keep the draft's `ncpus` and `select`. Those are what the scheduler grants,
which on Casper is two fewer than the hardware has. Run one probe job per
node type. If you keep more than one, list them under `subclusters:`, each
with its own full `node:`, and name a `default_subcluster`.

### 3. Fill in the TODOs

Each of these has to come from a person:

- **`scheduler.queue`** -- and `walltime_max`, so `validate` can refuse a
  longer request.
- **`modules.bootstrap`** -- the module commands a batch job needs before
  `module load` works, in order. Copy them from a job script that already
  works on the machine.
- **`container.binds`** -- the shared filesystems jobs read and write.
  Directories that are only sometimes there go under `binds_if_present`.
- **`mpi.<family>.root`** -- if the draft could not find the variable the
  MPI module sets to its install prefix.
- **`images.target` and `march`** -- only if app images should be built for
  this machine's microarchitecture rather than at the base images' flags.
  Name it after the CPU (`icelake`, `sapphirerapids`), not the cluster. Spell
  it per compiler: nvhpc takes `-tp=`, the others `-march=`.

A value that every cluster of the site states identically belongs in
`sites/<site>.yaml` instead. Lists and maps merge with the cluster's, and
scalars take the cluster's value.

### 4. Generate and check

```bash
hpcrun/sitegen <cluster> --write      # writes sites/<site>/<cluster>/cluster.sh, whole
hpcrun/sitegen --check                # every cluster's profile current
make -C hpcrun test                   # the off-cluster checks
hpcrun/validate <experiment>          # an experiment with `cluster: <cluster>`
```

`sitegen` refuses an incomplete description by name ("no scheduler.queue:
-- state it in ..."), and refuses combinations that cannot run. Examples: a
host-openmpi recipe with no `root`, a Cray MPICH shim under the wrong
launcher, an image set naming a compiler with no host module. The profile it
writes for a new cluster works as written. It finds its clone, its images,
the scheduler's submit directory and the site's scratch on its own. The four
paths at the top are there for when a default is wrong for you.

### 5. Run one small job, then mark it verified

Copy `hpcrun/experiments/casper-hpcg.yaml`, the partial-node plumbing check,
for the new cluster. Build the images it names (`make <cluster>-hpcg` in
`sif/`, after the app workflow has published them), submit, and read
`job.log`. Check four lines:

- `host MPI` should name the host's library, not `/container`;
- the `placement` verdict;
- `cpu`, against `target_arch`;
- the exit codes.

Then delete `verified: false`. Do the same for each sub-cluster's own
`verified:`.

## Notes for a Slurm site (TACC)

`clusterinit` and `sitegen` handle Slurm. The draft takes geometry straight
from `sinfo`, and the profile defaults its results root to
`SLURM_SUBMIT_DIR`. Three things are not built yet, and all are phase 4.6 in
[BenchmarkRunnerPlan.md](../BenchmarkRunnerPlan.md):

- **The job template.** `hpcrun/templates/` has `job.pbspro.tmpl` only, and
  `jobfile` renders PBS's single `select=` chunk. Slurm needs
  `--nodes`/`--ntasks-per-node`/`--cpus-per-task`/`--exclusive` and a
  `job.slurm.tmpl`. Until then `validate` works and `submit` does not.
- **The node list** in `runner.sh` reads `$PBS_NODEFILE`. Slurm's
  `$SLURM_JOB_NODELIST` is a range expression, and needs
  `scontrol show hostnames` to expand.
- **The host MPI.** TACC's machines run Intel MPI or MVAPICH. Neither has an
  overlay recipe. Intel MPI implements the MPICH ABI (`libmpi.so.12`), so an
  mpich image should run on it through a generic "mpich-abi" overlay,
  modelled on the Cray one. `clusterinit` lists such modules as present but
  unsupported, rather than inventing a recipe. The launcher may also be
  `ibrun` rather than `srun`, which `mpi_launch_flags` would need as a
  dialect.

The probe job, the description and `validate` are worth doing first, before
any of that. They are what tell you which of these the machine actually
needs.
