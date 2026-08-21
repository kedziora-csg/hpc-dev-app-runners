# Guide to Deploying and Testing Apptainer Containers on NCAR HPC (Derecho & Casper)

This document describes how this repository builds, deploys, and runs Apptainer (formerly Singularity) containers at native speed on NCAR's supercomputer (Derecho) and data-analysis cluster (Casper).

---

## 1. How the Repository Deploys Apptainer Containers

This repository employs a **hybrid building pattern**:
1. **GitHub Actions (Cloud)**: Builds multi-layer Linux-based Docker images of the HPC developer software stacks, publishing them to a container registry (DockerHub or GitHub Container Registry - GHCR) under the name `hpcdev` or similar. No self-hosted runners or NCAR infrastructure are used during the Docker-building phase.
2. **NCAR Cluster (On-Platform SIF Construction)**: Once the Docker images are in the registry, operators or researchers log into Derecho/Casper to rebuild them as Apptainer Singularity Image Format (`.sif`) files. SIF builders can bind low-level system drivers and directories which can only be done directly on-platform.

### Key Deployment Components

All NCAR-specific deployment files are located under [containers/deploy/ncar-hpc/](containers/deploy/ncar-hpc/):

* **Template-Driven Builds**: 
  The deployment uses a Singularity definition template, [containers/deploy/ncar-hpc/libexec/Deffile](containers/deploy/ncar-hpc/libexec/Deffile).
  The GNU Makefile [containers/deploy/ncar-hpc/libexec/Makefile](containers/deploy/ncar-hpc/libexec/Makefile) utilizes this template to construct custom `.def` and build `.sif` files. By sourcing [containers/deploy/ncar-hpc/config_env.sh](containers/deploy/ncar-hpc/config_env.sh), the Makefile configures user/system paths (e.g., custom `TMPDIR` and `APPTAINER_CACHEDIR` stored in paths like `${WORK}/.apptainer-cache/`) to avoid quota limits on home directories during build.

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

Follow these steps to deploy and build the `.sif` images on NCAR clusters:

### Step 3.1: Log in and Clone Repository
Log into Derecho or Casper and clone this repository:
```bash
ssh <username>@derecho.hpc.ucar.edu
git clone https://github.com/ncar-cisl/demo_github_actions.git
cd demo_github_actions/containers/deploy/ncar-hpc
```

### Step 3.2: Load System Modules
Load the Apptainer module:
```bash
module purge
module load ncarenv/24.12  # Or equivalent current environment
module load apptainer gcc cuda
```

### Step 3.3: Convert a Target Image
To build a specific variant (e.g. `almalinux9-gcc-openmpi-cuda`), navigate to the `libexec` subdirectory and execute `make`:
```bash
cd libexec
make almalinux9-gcc-openmpi-cuda.sif
```
This automated flow will:
1. Parse the template [containers/deploy/ncar-hpc/libexec/Deffile](containers/deploy/ncar-hpc/libexec/Deffile) into a custom definition file `almalinux9-gcc-openmpi-cuda.def`.
2. Sourcing [containers/deploy/ncar-hpc/config_env.sh](containers/deploy/ncar-hpc/config_env.sh) will allocate healthy caching folders inside your High-Performance storage.
3. Call `apptainer build` using the corresponding Docker image hosted on the container registry.
4. Set up an executable shortcut under `../bin/` automatically mapping to [containers/deploy/ncar-hpc/libexec/wrap_apptainer.sh](containers/deploy/ncar-hpc/libexec/wrap_apptainer.sh) for execution.

---

## 4. How to Test Your Containers on Derecho and Casper

To verify complete operation of MPI, GPU mappings, and storage directories, submittable PBS scripts are provided.

### Step 4.1: Interactively Run a Container (Smoke Test)
You can directly run interactive commands in the newly generated `.sif` container through the wrap script:
```bash
../bin/almalinux9-gcc-openmpi-cuda "echo 'Hello from high-performance container' && nvidia-smi"
```

### Step 4.2: Submit a Batch Microbenchmarks Test Job
To test real multi-node execution and inter-node MPI performance using OSU Micro-Benchmarks, submit one of the pre-configured PBS scripts in [containers/deploy/ncar-hpc/PBS/](containers/deploy/ncar-hpc/PBS/):

**On Derecho:**
Ensure that the target container variable `container_img` in [containers/deploy/ncar-hpc/PBS/OSU_derecho.pbs](containers/deploy/ncar-hpc/PBS/OSU_derecho.pbs) matches the `.sif` file you compiled, then submit:
```bash
qsub PBS/OSU_derecho.pbs
```

**On Casper:**
Ensure that your target file in [containers/deploy/ncar-hpc/PBS/OSU_casper.pbs](containers/deploy/ncar-hpc/PBS/OSU_casper.pbs) is built, then submit:
```bash
qsub PBS/OSU_casper.pbs
```

### Step 4.2b: What a Benchmark Job Leaves Behind

A results directory is self-contained: reading it never requires the PBS script,
the job log, or knowing what was submitted.

| File | Contents |
|---|---|
| `results.jsonl` | one JSON object per measured cell — the machine-readable record |
| `run.meta` | the job-level `# key value` header: image, digest, geometry, launcher, job id, harness SHA |
| `topology.json` | the node topology this job probed; every placement threshold is derived from it |
| `modules.txt`, `env.txt` | the environment the run actually had |
| `launcher.sh` | the generated Apptainer launcher, verbatim |
| `ldd_*.txt` | full linkage of the report binary and the app |
| `placement_<cfg>.out` | `report_placement` output, provenance header first |
| `run_<cfg>/` | the app's own working directory: inputs, `app.out`, `metrics.kv` |

Tabulate one or many jobs:

```bash
containers/deploy/bench/collect <results-root>          # table
containers/deploy/bench/collect <results-root> --best   # the winning cell per app
containers/deploy/bench/collect <results-root> --format csv
```

`collect` never lets a row win if its placement verdict is `fail`, if the app
reported itself invalid, or if it exited non-zero — a mis-bound run measures its
binding, not the code.

The job log itself carries only the narrative: each cell's geometry, its
placement verdict, its figure of merit, and anything that aborted it. Set
`BENCH_VERBOSE=1` to also echo the captured files as they are written — useful
when bringing up a new machine or a new app, where you are watching the job
rather than reading it afterwards. It changes what is displayed, never what is
recorded.

### Step 4.3: Understanding the GPU Setup Wrapper
To map multiple MPI ranks smoothly to available hardware accelerators, the job uses the custom helper script [containers/deploy/ncar-hpc/set_gpu_rank](containers/deploy/ncar-hpc/set_gpu_rank). It extracts local/global rank variables automatically mapping each rank to a physical GPU, validating operations such as:
```bash
mpiexec set_gpu_rank ./apptainer-launch-*.sh /container/osu-micro-benchmarks/7.5/libexec/osu-micro-benchmarks/mpi/pt2pt/osu_latency D D
```
This tests device-allocated memory-to-memory GPU communication over the low-latency fabric.
