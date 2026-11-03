# Plan: GPU node types, starting with Derecho's A100 nodes (phase 5c)

Status: **proposed 2026-10-30; nothing implemented.** Step 0 ran the same day
on `deg0051` (job 8018411), and its results are under step 0 below. The CUDA
path works from inside the image. Each rank's GPU must be chosen by NUMA
domain, not by local rank. GPU-aware Cray MPICH works through the ABI shim,
but `MPICH_GPU_SUPPORT_ENABLED` slows host-buffer messages 15-fold, so it is
turned on per app, not per node type. NVIDIA's STREAM and HPL run from the
site's install inside the nvhpc CUDA image, with NCCL from `nvhpc/26.1`:
1.38 TB/s Triad a GPU, and 53.7 TFLOP/s on four GPUs, untuned (D8, D9).

Phase 5b gave each node type its own app target, with Casper as the test case.
This phase gives a node type GPUs. Derecho becomes two node types: `cpu`, the
nodes it has today, and `a100`. The `a100` node type runs app images built on
the factory's `-cuda` base images, through the same runner, app contract and
results as the CPU nodes. Those images have never been built in
`NCAR/hpc-dev-container-factory`, so part of this phase is the factory's.

## 1. Goal and acceptance

The use cases:
- **STREAM on both node types**, for GPU against CPU memory bandwidth.
  McCalpin's `stream.c` on the CPUs; NVIDIA-STREAM, which is McCalpin-derived,
  on the GPUs.
- **HPL on both.** Netlib HPL on the CPUs; HPL-NVIDIA on the GPUs.

The GPU binaries are NVIDIA's own, from the NVIDIA HPC-Benchmarks archives
(§5). Their license forbids redistribution, so they are installed by the site
and never placed in an image (D8).

Acceptance:
- `derecho-stream` and `derecho-hpl` run on `--subcluster cpu`, and
  `derecho-nvstream` and `derecho-nvhpl` on `--subcluster a100`, all from app
  images published by the app workflow. The NVIDIA ones are contract-only
  images, with the binaries bound in from the site's install.
- OSU with device buffers runs on `a100` across the six `-cuda` base images,
  through Cray MPICH's GPU transport, as the earlier work's first GPU test did.
- On the GPU cells, `run.meta` records the node type, the GPU model and driver,
  and each rank's device. A rank whose GPU is not on its NUMA domain is warned
  about.
- No file under `hpcrun/` names an app (`CLAUDE.md`).

## 2. What is there, 2026-10-30

### The machine

`pbsnodes -a` lists 82 GPU nodes (`deg0001`-`deg0082`) beside 2,488 CPU nodes.

| | CPU nodes (`dec*`) | GPU nodes (`deg*`) |
|---|---|---|
| CPU | 2 x EPYC 7763 (Milan), 128 cores | 1 x EPYC 7763, 64 cores |
| `ncpus` | 128 | 64 |
| GPUs | -- | `ngpus=4`, A100-SXM4 40 GB (`gpu_type`: a100, a100_40gb, a100_4way, cc80, ...) |
| `mem` | 240,736 MB | 498,864 MB |
| `Qlist` | cpu | a100 |

`main` is a routing queue. A request with `ngpus` lands in the `gpu` execution
queue, and `develop` routes to `gpudev`. The host driver on the login node is
580.65.06, whose driver API is CUDA 13.0 (measured below); the GPU nodes'
driver is to be confirmed in step 0. The site's `cuda/12.9.0` module and the
factory's CUDA 12.9.1 agree.

### The factory

- **No `-cuda` image has been published by `NCAR/hpc-dev-container-factory`.**
  `ghcr.io/ncar/hpcdev-x86_64` holds the CPU set and `leap-gcc-openmpi` only.
  `cluster-images-ghcr.yaml` hard-codes `gpu: nogpu`, and
  `matrix-build-images-ghcr.yaml`, the only workflow with a `cuda` axis, has
  never been dispatched there.
- `CONTRACT.md` says only that `<gpu>` in a tag is `cuda`, and that HeFFTe is
  built with CUDA in a CUDA image. It promises nothing an app built for a GPU
  would use: not `CUDA_HOME`, not `nvcc`, not where the CUDA libraries are
  found, and not the device architectures built.
- **The CUDA stage has not changed since 2025-09** (`12121e3`, "CUDA from base
  images"). The images the fork built in August, `ghcr.io/kedziora-csg/hpcdev-x86_64:leap-*-cuda-26.08`
  (all six of the clusters' set), therefore carry today's CUDA set-up. They
  differ from today's images below the CUDA stage: no DYNAMIC_ARCH OpenBLAS, no
  FFTW SIMD codelets, and no `-tp=x86-64-v3` for nvhpc.

### One of those images, inspected on Derecho

Inspected 2026-10-30: `leap-gcc14-openmpi-cuda-26.08`, pulled as a 2.9 GB
`.sif`. The login node has the NVIDIA driver but no GPU.

- **The CUDA libraries resolve without `config_env.sh`.** The runfile installer
  writes `/etc/ld.so.conf.d/cuda-12-9.conf`, so `libcudart`, cuBLAS, cuFFT and
  `libnvblas` are in the linker cache. This matters, because hpcrun's launcher
  replaces `LD_LIBRARY_PATH` and never sources `config_env.sh`.
- **So are the stubs.** `cuda-stubs.conf` puts `libcuda.so.1` and
  `libnvidia-ml.so.1` into the cache as stubs, which lets the image link and
  start on a host with no GPU. If nothing ahead of the cache supplies the
  host's driver, a program starts and then reports `CUDA driver is a stub library`.
  This was measured with a small probe (`gpu_probe.cu`, step 0) in three
  launches:

  | Launch | `libcuda.so.1` loaded from | Driver API |
  |---|---|---|
  | `LD_LIBRARY_PATH` with no host directory | the image's stub | 0 (stub) |
  | hpcrun's Derecho launch: `/usr/lib64` bound as `/host_lib64` and on the path | `/host_lib64/libcuda.so.1` | 13000 |
  | `--nv` | `/.singularity.d/libs/libcuda.so.1` | 13000 |

  Apptainer appends `/.singularity.d/libs` to `LD_LIBRARY_PATH` even when the
  launcher sets the variable with `--env`. So the launcher already reaches the
  host driver through `/host_lib64`, and `--nv` adds the device set-up on top.
- **Device code is portable by default.** `NVCC_PREPEND_FLAGS` carries
  `-arch=all-major`, which builds SASS for sm_50 through sm_120, sm_80
  included. An app's own `-arch=sm_80` overrides it: nvcc warns
  `incompatible redefinition for option 'gpu-architecture'` and uses the last
  value. Tuning for the GPU can therefore live in the app layer, as the CPU
  target does.
- **HeFFTe** is built twice. `HEFFTE_ROOT` names `2.4.1-cuda` (sm 80 and 90),
  which installs to `lib64/`. `heffte.conf` names `lib/`, so that library is not
  in the cache. The CPU build has the same mismatch.
- **OSU** is built with `--enable-cuda`, and its binaries need `libcuda.so.1`.
- `scripts/hello_world.cu` checks no CUDA errors. On a node with no GPU it
  prints its input unchanged and exits 0, so it cannot fail a test.

### How the earlier work ran GPUs

Checked 2026-10-30 against `kedziora-csg/demo_github_actions`, where the
runner came from. Its GPU jobs are the legacy scripts this repository still
carries byte for byte in `sites/ncar/legacy/`: `OSU_derecho.pbs`,
`FE_derecho.pbs` (FastEddy), `OSU_casper.pbs` and `set_gpu_rank`.

- **`--nv` always**, with `/usr/lib64` bound as `/host/lib64` at the end of
  `LD_LIBRARY_PATH`. This is the launch measured below, under its old name.
- **GPU-aware Cray MPICH from the start.** For a `*cuda*` image, the generated
  launcher preloads `/opt/cray/pe/mpich/${CRAY_MPICH_VERSION}/gtl/lib/libmpi_gtl_cuda.so.0`.
  For the mpich family, `set_gpu_rank` sets `MPICH_GPU_SUPPORT_ENABLED=1` and
  `MPICH_OFI_NIC_POLICY=GPU`. FastEddy, the one real GPU app run that way,
  needs both.
- **`set_gpu_rank` chooses the device on the host side**, outside `apptainer
  exec`: `CUDA_VISIBLE_DEVICES = local rank % NGPUS`. The local rank comes from
  `PMI_LOCAL_RANK` (mpich) or `OMPI_COMM_WORLD_LOCAL_RANK`, and it pays no
  attention to NUMA. Without MPI it shows every GPU.
- **The request** is `-q main` with `select=N:ncpus=64:mpiprocs=4:ompthreads=4:ngpus=4`.
- **The first GPU test was OSU with device buffers** (`osu_latency D D`,
  `osu_bibw D D`), within and across nodes, and the collectives with
  `-d managed`. That tests the GTL path before any app does.
- **Names.** `sif/Makefile` built a `-cuda.sif` beside every CPU image, as
  `<os>-<compiler>-<mpi>-cuda.sif`. The images were almalinux9 and noble, not
  leap.
- `derecho-images-ghcr.yaml` left GPU images "a later axis (they need --nv,
  set_gpu_rank and an ngpus PBS select line)", which is what D4 and D5 below
  provide.
- **Upstream** (`benkirk/demo_github_actions`) has an unmerged `cuda13` branch,
  of 2026-06-27, that moves CUDA to 13.2.1. Derecho's 580.65 driver is CUDA
  13.0, so a 13.2 runtime would run only through CUDA's minor-version
  compatibility. That is a reason to stay on 12.9, which matches both the
  driver and the site's `cuda/12.9.0` module, until the driver moves.

The plan below keeps all of this except the NUMA-blind choice of device, and
takes GPU-aware MPICH in at the start, where the first draft deferred it.

### The runner

The runner has no GPU support:
- no `--nv` in the launcher;
- no `ngpus` in the select statement;
- no GPU in `node:`, in `topology.json` or in the geometry handed to hooks;
- no GPU column in the placement report (§11 item 3 of `BenchmarkRunnerPlan.md`);
- no `requires:` an app can use to say it needs a GPU.

A sub-cluster's `images:` replaces only `target` and `march`. Phase 5b decided
that the OS, compilers, MPI families and apps follow the host's modules, and so
stay cluster-wide.

## 3. Decisions proposed

**D1. The base images are the clusters' six, with `-cuda`:**
`leap-{oneapi,gcc14,nvhpc}-{mpich,openmpi}-cuda`, built and published by one
dispatch of `cluster-images-ghcr.yaml` with a new `gpu` input. That workflow,
not the full matrix, because it is how the CPU set is built and kept, and the
August run shows all six build. The CUDA version and runfile URL mirror
`matrix-build-images-ghcr.yaml`, as the compiler versions already do.

**D2. A sub-cluster's `images:` replaces its cluster's key by key.**
- **Today** it may carry `target` and `march`.
- **It may now also carry `gpu`, `apps` and `compilers`.** The OS and the MPI
  families stay cluster-wide.
- **This widens a 5b decision, for a different reason.** An app that needs a
  GPU has no business on a CPU node, and HPCG on a GPU node measures the wrong
  thing. The GPU node type also takes one compiler (D9).
- **The modules argument still holds for MPI.** It no longer decides the
  compilers: the host's modules are the same on both node types, but the GPU
  node type uses only one of them.

```yaml
# sites/ncar/derecho.yaml (sketch)
images:
  os: leap
  compilers: [oneapi, gcc14, nvhpc]
  mpi: [mpich, openmpi]
  apps: [hpcg, heffte, blas, stream, hpl]

# Software the site installs and a container borrows, by name (D8).  ${mpi}
# is the image's MPI family: the mpich archive links libmpi.so.12 (Cray's ABI
# shim), the openmpi one libmpi.so.40 (the host Open MPI).
host_software:
  nvidia_hpc_benchmarks:
    description: "NVIDIA HPC-Benchmarks 26.02.04, CUDA 12 build: HPL, HPL-MxP, HPCG, STREAM"
    version: "26.02.04"
    path: /glade/<site install>/nvidia_hpc_benchmarks_${mpi}-linux-x86_64-26.02.04-archive/cuda12
    mount: /opt/nvidia-hpc-benchmarks
  # NCCL and NVSHMEM for CUDA 12.9 from the site's nvhpc module (D9).  Quoted:
  # expanded once load_host_modules has loaded nvhpc/26.1, as an MPI root is.
  nvhpc_comm_libs:
    description: "NCCL 2.29.2 and NVSHMEM 3.5.19 for CUDA 12.9, from nvhpc/26.1"
    path: '${NCAR_ROOT_NVHPC}/Linux_x86_64/26.1/comm_libs/12.9'
    lib_dirs: [nccl/lib, nvshmem/lib]

modules:
  compiler_map:
    nvhpc: nvhpc/26.1   # pinned: the default, 25.9, has NCCL 2.27.7 (D9)

default_subcluster: cpu
subclusters:
  cpu:
    description: "2 x AMD EPYC 7763 (Milan), 128 cores, SMT on"
    images: {target: znver3, march: {default: -march=znver3, nvhpc: -tp=zen3}}
    node: {...}             # today's node: block, moved here unchanged
  a100:
    description: "1 x AMD EPYC 7763 (Milan), 64 cores, 4 x NVIDIA A100-SXM4-40GB"
    verified: false
    images:
      target: znver3
      march: {default: -march=znver3, nvhpc: -tp=zen3}
      gpu: {runtime: cuda, target: sm80, arch: -arch=sm_80}
      compilers: [nvhpc]      # D9
      apps: [nvstream, nvhpl]
    node:
      cores: 64
      smt: 2
      ncpus: 64
      sockets: 1
      smt_stride: 64          # measured, deg0051: node0 is CPUs 0-15,64-79
      cores_per_l3: 8
      cores_per_numa: 16      # measured: 4 NUMA domains (NPS4), ~126 GB each
      target_arch: x86-64-v3
      gpus: {count: 4, vendor: nvidia, model: a100_40gb}
      select: mem=480GB
      topology: probe
```

**D3. Names.** An app image on a `-cuda` base keeps the base's word and gains
the GPU target, for example `leap-nvhpc-openmpi-cuda-stream-znver3-sm80`. One
tag still means one build. The image is labelled `hpcdev.gpu=cuda` and
`hpcdev.gpu_target=sm80`, beside `hpcdev.target`. `sitegen --check`'s rule
that a target is spelled once across the site covers `sm80` too. Without a
`gpu.target`, an app is built for `all-major` and its name has no GPU word.
`checks._target_in_name` must skip the `cuda` word, but it is only the
fallback for unlabelled images, and none of these will be unlabelled.

A contract-only app image (D8) compiles nothing, so it carries no target of
either kind: `leap-gcc14-mpich-cuda-nvhpl`. Its empty `hpcdev.target` label is
portable, which the 5b check already accepts on any node type.

**D4. GPUs are a node fact.**
- `node.gpus: {count, vendor, model}` is stated once. The job file derives the
  scheduler's spelling from it: `:ngpus=4` for PBS Pro, `--gpus-per-node`
  for Slurm.
- The launcher adds `--nv` for `vendor: nvidia` (`--rocm` for amd, later).
  That is apptainer's spelling, so it is code in the launcher, not data.
  `/host_lib64` stays, since it already supplies the same driver.

**D5. One GPU a rank, by default, chosen by NUMA domain.** Step 0 showed that
`set_gpu_rank`'s choice, local rank modulo the GPU count, gives every rank on a
Derecho GPU node the GPU furthest from it. So:
- A wrapper on the host side of `apptainer exec`, as `set_gpu_rank` was, gives
  each rank the GPU on its own NUMA domain.
  - The GPU is taken from **the job's own `CUDA_VISIBLE_DEVICES`**. PBS sets
    that variable to the UUIDs of the GPUs it allocated, so a job on part of a
    node stays on its own GPUs. A bare index such as `0`, as `set_gpu_rank`
    used, would address a GPU the job was not given.
  - Each GPU is identified by UUID or PCI bus ID, never by CUDA index, because
    the two orders differ (step 0).
  - Its NUMA domain comes from `/sys/bus/pci/devices/<bus id>/numa_node`,
    probed once per job.
- The local index comes from `PMI_LOCAL_RANK` under PALS,
  `OMPI_COMM_WORLD_LOCAL_RANK` or `SLURM_LOCALID`.
- With more ranks than GPUs, the ranks on one NUMA domain share its GPU. When a
  rank's cores span several domains, it takes the GPU of its first core.
- An experiment can turn binding off with `gpu_bind: none`, and then every rank
  sees every GPU the job was given.

**D6. Apps say they need a GPU.** `requires: {gpu: cuda}` in `app.yaml`.
- `validate` and `submit` refuse a GPU app on a node type without GPUs, with
  the exit code used for a wrong image.
- `apps/smoke.sh` on a GitHub runner, which has no GPU, resolves the contract
  and runs its prepare and launch hooks. It then prints
  `run skipped: host has no GPU` and exits 0, as it already does for a missing
  ISA, and the workflow raises a warning.

**D7. GPU-aware Cray MPICH on the GPU node type from the start, as before.**
The earlier launchers enabled it for every CUDA image on Derecho, and FastEddy
needed it. The pieces divide between code and data, as the overlays already
do:
- **Code.** The `cray-mpich-abi` recipe gains a GPU arm for a node type with
  NVIDIA GPUs. It always preloads
  `${CRAY_MPICH_DIR%/ofi/*}/gtl/lib/libmpi_gtl_cuda.so.0`, which step 0
  measured to cost nothing on host buffers. Which library carries the
  transport is an argument, like `lib-abi-mpich`, so it lives in code.
- **`MPICH_GPU_SUPPORT_ENABLED=1` is on only for an app that passes device
  buffers to MPI.** Step 0 measured it raising host-buffer latency from 0.47
  to 6.94 us, so turning it on for every cell would slow every CPU-buffer app
  that happens to run on a GPU node. An app asks for it in `app.yaml`
  (`requires: {gpu: cuda, gpu_aware_mpi: true}`), and an experiment can force
  it either way as a variant. Without it a device buffer crashes the rank, so
  a cell that needs it and lacks it fails loudly rather than measuring the
  wrong thing.
- **Data.** `MPICH_OFI_NIC_POLICY: GPU` goes in the description of the node
  type: the four NICs are a fact about the GPU nodes.
- **On a CPU node type, neither.** `MPICH_GPU_SUPPORT_ENABLED=1` without the GTL
  library fails at `MPI_Init`, and the GTL library needs `libcuda`.
- **One preload list.** The runner already preloads a host library for a
  variant through `APPTAINERENV_LD_PRELOAD`, so the two preloads are joined,
  never one written over the other.
- **The first GPU acceptance test is OSU with device buffers**, as it was
  before: `derecho` (the base set) on `a100`. OSU's `launch` hook passes only
  `-m`, so it needs one more knob (`OSU_BUFFERS="D D"`). That knob is the
  factory's (step 1), copied into `hpcrun/tests/fixtures/app.d/osu/`.
- **Open MPI waits.** Whether the host Open MPI is CUDA-aware is not yet known.
  STREAM does not need it.

**D8. Vendor binaries are host software: the site installs them, the image
carries the contract.** NVIDIA's HPC-Benchmarks license (§5) grants internal
use only, and its §2.2 forbids distributing any part of the software, and
`ghcr.io/kedziora-csg/hpcdev-apps-x86_64` is public. So the NVIDIA binaries
enter no image, base or app, and no repository. Instead:
- **Install.** The site downloads the archive from NVIDIA's own URL, checks it
  against a pinned sha256, and unpacks it on GLADE. A script under
  `sites/ncar/` does that, and holds only the URL and the checksum, never the
  software.
- **Description.** The cluster names the install under `host_software:`, with
  its version, its path (templated on the image's MPI family) and the mount
  point inside the container. It is the same pattern as `host_libraries:`, and
  it is a property of the site, not of an app.
- **Contract.** The contract is ours. `apps/nvhpl/` and `apps/nvstream/` hold
  `app.yaml` and hooks that name `/opt/nvidia-hpc-benchmarks/...` as the
  binary, and a `build.sh` that installs only `app.d/`. The app workflow
  publishes them as contract-only images on the `-cuda` bases, so the contract
  still travels in the image (decision 2 of `BenchmarkRunnerPlan.md` §12).
- **The runner stays generic.** An app states `requires: {host_software:
  nvidia_hpc_benchmarks}`.
  - `validate` and `submit` refuse a cluster that lacks it, or whose path does
    not exist for the image's MPI family.
  - The launcher binds the path at the mount.
  - `run.meta` records the name, version, path and the sha256 of the binary.
    The image digest no longer identifies what ran, so this is what makes the
    result reproducible.
  - Nothing under `hpcrun/` names NVIDIA or an app.
- **The CUDA 12 build, not the CUDA 13 one.** It needs `libcublas.so.12`,
  `libcublasLt.so.12`, `libcudart.so.12` and `libcurand.so.10`, which the
  factory's CUDA 12.9 image supplies, and a CUDA 12 driver, which Derecho's
  580.65 is. The CUDA 13 build would need a runtime the factory does not ship.
- **The launch is ours, not `hpl.sh`.** `hpl.sh` reads the local rank from
  `OMPI_COMM_WORLD_LOCAL_RANK`, `SLURM_LOCALID` or `MPI_LOCALRANKID` only, so
  under PALS any of its affinity options stops with
  `could not determine local rank`. The runner binds the GPU itself (D5). The
  `launch` hook calls `xhpl` or `stream_test` directly, with the archive's own
  `lib/nccl` and `lib/nvshmem` first on `LD_LIBRARY_PATH`. It also sets the
  variables the mpich build's `hpc-benchmarks-gpu-env.sh` sets for an HPE Cray
  system: `NVSHMEM_REMOTE_TRANSPORT=libfabric`,
  `NVSHMEM_LIBFABRIC_PROVIDER=cxi`, `FI_CXI_DISABLE_HOST_REGISTER=1`,
  `MPICH_NO_BUFFER_ALIAS_CHECK=1` and `HPL_USE_NVSHMEM=0`.
- **No GPU-aware MPI for HPL.** HPL-NVIDIA communicates between GPUs with NCCL
  (`HPL_P2P_AS_BCAST=1`, its default) and pivots over host MPI, so `nvhpl`
  does not ask for `gpu_aware_mpi`, and does not pay D7's latency cost.

**D9. The GPU node type uses nvhpc only, with the site's `nvhpc/26.1`
module on the host.** Proposed 2026-10-30.
- **The GPU toolchain.** OpenACC and CUDA Fortran build only with nvhpc, and
  NCAR's GPU codes (MURaM, MPAS on GPUs) use them. `nvc++` builds CUDA C++
  as well.
- **NVIDIA's binaries do not care which compiler the image has.** One image per
  MPI family is enough, so the `a100` sets are 2 images, not 6. That disposes of
  the six-copies risk in §6.
- **The host side follows.** `load_host_modules` loads the nvhpc module, and
  with it:
  - Cray MPICH's NVIDIA build (`ofi/nvidia/23.3`);
  - an Open MPI built with nvhpc 26.1
    (`openmpi/5.0.9/nvhpc/26.1/2z45`).

  That is the same path the CPU nodes' nvhpc images already take.
- **NCCL and NVSHMEM come from the module**, not from each app. `nvhpc/26.1`
  ships `comm_libs/12.9/{nccl,nvshmem}` for CUDA 12.9, matching the factory's
  CUDA, at NCCL 2.29.2 and NVSHMEM 3.5.19, the very versions the NVIDIA archive
  bundles. Declared as host software, they are one NCCL for every GPU app on the
  node type, maintained by the site. The archive's `lib/` copies go unused.
  Checked 2026-10-30, `ldd` in `leap-nvhpc-mpich-cuda-26.08` with `nvhpc/26.1`
  loaded: `xhpl` resolves
  - `libnccl` and `libnvshmem_host` from the module's `comm_libs/12.9`;
  - `libmpi.so.12` from the NVIDIA build of Cray's shim;
  - cuBLAS from the image.
- **The pin.** The site maps `nvhpc` to the bare module name, which loads the
  default, 25.9. 25.9 is a Casper-tree install with NCCL 2.27.7. Derecho's
  `compiler_map` pins `nvhpc/26.1`, which is also nearer the image's nvhpc
  26.5. This changes the CPU nodes' nvhpc cells too, so one `derecho-hpcg`
  nvhpc run confirms them before anything else depends on the pin.
- **The factory still builds all six `-cuda` images** (D1), because the set is
  the clusters' and Casper may want others. Derecho pulls two.
- **What the module does not bring: NCCL across nodes.** Its network plugins
  (HPC-X's `nccl_rdma_sharp_plugin` and `nccl_spectrum-x_plugin`) are for
  InfiniBand and RoCE, not libfabric. Slingshot still needs aws-ofi-nccl (§6).
- **The August `leap-nvhpc-mpich-cuda-26.08` image has no OSU.** `find
  /container -name osu_latency` finds nothing. Step 1 found why: OSU's CUDA
  kernel does not compile under nvc++ 26.x, and the build script exited 0
  anyway. Both are fixed there.

## 4. Steps

### Step 0 -- one A100 node, with the August image (no code)

Written, not submitted, because a job needs a billable account:
`a100_check.pbs` and `gpu_probe.cu`, in the session scratchpad and to be
copied into the repository with step 3's tests. Fifteen minutes on one node of
`develop`:

```bash
qsub -A <PROJECT> a100_check.pbs
```

It answers:
- whether the probe sees four A100s and runs a kernel in each of the three
  launches above;
- the GPU nodes' driver;
- `lscpu`, `numactl --hardware` and `nvidia-smi topo -m`: the `a100` geometry,
  and which NUMA domain each GPU is on;
- whether four ranks under PALS `--cpu-bind depth -d 16`, with
  `CUDA_VISIBLE_DEVICES` set from `PMI_LOCAL_RANK` by a wrapper outside the
  container (`set_gpu_rank`'s way), each see one device;
- whether `osu_latency D D` between two GPUs runs through Cray MPICH's ABI shim
  with GTL preloaded and `MPICH_GPU_SUPPORT_ENABLED=1`, in
  `leap-gcc14-mpich-cuda-26.08`, launched as hpcrun launches an mpich image.
  This is the earlier work's first GPU test, run on the factory's leap
  images.

If any launch finds no device, D4 is wrong and is redone before anything is
built.

**Results, 2026-10-30, job 8018411 on `deg0051`** (log in
`/glade/work/kedziora/Jelissa/launch_cf/a100-cuda-check.o8018411`):

- **Driver** 580.65.06 (CUDA 13.0), the same as the login node. Four
  A100-SXM4-40GB, cc 8.0, all connected by NVLink (`NV4`).
- **Geometry.** One EPYC 7763, 64 cores, SMT 2 with block layout (stride 64),
  and 4 NUMA domains of 16 cores and about 126 GB each. The `a100` sketch in D2
  now carries these values.
- **All three launches pass.** In each, the probe sees four devices and a kernel
  runs, at driver API 13000 and runtime 12090:
  - hpcrun's present launch, with no `--nv`, loads `/host_lib64/libcuda.so.1`;
  - `--nv` with hpcrun's library path loads the same file;
  - `--nv --cleanenv` loads `/.singularity.d/libs/libcuda.so.1`.

  So D4 holds, and `--nv` adds the device set-up without changing which driver
  loads. With `/var/run` bound, `--nv` prints a harmless warning about the
  `nvidia-persistenced` socket.
- **The GPUs' NUMA domains run in reverse of the cores'.**

  | GPU (PCI order) | Bus | NUMA domain | CPUs |
  |---|---|---|---|
  | 0 | 03:00 | 3 | 48-63, 112-127 |
  | 1 | 41:00 | 2 | 32-47, 96-111 |
  | 2 | 82:00 | 1 | 16-31, 80-95 |
  | 3 | C1:00 | 0 | 0-15, 64-79 |

  Four ranks under `--cpu-bind depth -d 16` land on NUMA domains 0-3 in order.
  With `set_gpu_rank`'s `CUDA_VISIBLE_DEVICES = local rank`, each saw exactly
  one device and ran its kernel, but rank 0 (NUMA 0) got 03:00 (NUMA 3), rank 1
  got 41:00, and so on: **every rank got the GPU furthest from it.** This is why
  D5 now chooses by NUMA domain.
- **PBS sets `CUDA_VISIBLE_DEVICES`** to the job's four GPU UUIDs. They come in
  an order that is neither PCI's nor NUMA's: CUDA's device 0 was 41:00. Under
  `--cleanenv` the variable is dropped and CUDA enumerates in PCI order. The
  launcher does not use `--cleanenv`, so the binding wrapper must read this list
  rather than overwrite it.
- **OSU through Cray MPICH with GTL: not tested.** Every rank exited with code
  127, `libifport.so.5: cannot open shared object file`. The job left the
  default `intel` environment loaded, so `CRAY_MPICH_DIR` was Cray's Intel
  build (`ofi/intel/2022.1`), whose `lib-abi-mpich` needs Intel's Fortran
  runtime. hpcrun's `load_host_modules` loads `gcc/14.3.0` for a gcc14 image,
  which selects `ofi/gnu/12.3`. Checked on the login node: with that build,
  `ldd` of the image's `osu_latency` resolves everything, `libmpi_gtl_cuda.so.0`,
  the shim's `libmpi.so.12`, the host's `libcuda.so.1` and the image's
  `libcudart.so.12`.
- **The rerun** (`a100_osu_gtl.pbs`, on `deg0039`) loaded `gcc/14.3.0` first,
  and got `CRAY_MPICH_DIR=.../ofi/gnu/12.3`. Each rank got the GPU on its own
  NUMA domain (rank 0, CPUs 0-15, GPU 3 at C1:00). Every case then failed in
  `MPI_Init`, host buffers as well as device buffers:
  `_pmi_pals_init:pals_init2() failed: 2`, then `PMI_Init returned 1`. Error
  2 is ENOENT, so something PALS looks for is missing inside the container.
  This is not GPU-specific, since `H H` failed too. Three explanations are ruled
  out:
  - **PALS version:** `/opt/cray/pals/default` is `1.6`, the version the shim
    links and the working CPU launcher resolves first;
  - **the dropped `/var/run` bind:** in the image `/var/run` is a symlink to
    `/run`, which was bound.
  - **the GTL preload alone:** the `H H` case set `MPICH_GPU_SUPPORT_ENABLED`
    too, so it did not isolate anything.

  The launch differed from hpcrun's working CPU launch in several ways at once:
  the GNU MPICH build, `--nv`, the GTL preload, the GPU variables, and three
  binds (`/var/run`, `/local_scratch`, `/usr/lpp/mmfs`). `a100_pmi_bisect.pbs`
  starts from hpcrun's exact launch and adds one of them per case. It also
  prints the `PALS_*` and `PMI_*` variables and `/run/palsd` as rank 0 sees
  them inside the container.
- **The bisection** (`a100_pmi_bisect.pbs`, job 8018725, on `deg0011`) found
  the cause, and every case reached MPI.
  - **Why job 2 failed.** PALS puts each launch's spool directory, and the
    `apinfo` file PMI reads, under the job's `TMPDIR`:
    `PALS_SPOOL_DIR=/glade/derecho/scratch/kedziora/tmp/<apid>`. Job 2 bound
    only a subdirectory of that tree, not `/glade`, so `apinfo` was missing in
    the container. That missing file was the ENOENT. hpcrun binds `/glade`, which
    is why its launches work, but only because this operator's `TMPDIR` is on
    GLADE. Step 3 makes that explicit: the launcher binds `PALS_SPOOL_DIR`, or
    refuses to start when that directory is not under a bound path.
  - **Measured.** `osu_latency`, two ranks on one node, each on its NUMA-near
    GPU, Cray MPICH 8.1.32 (GNU build) through the ABI shim:

    | Case | Buffers | 8 B | 64 KiB |
    |---|---|---|---|
    | A: hpcrun's launch | host | 0.47 us | 16.1 us |
    | B: + `--nv` | host | 0.47 | 15.2 |
    | C: + GTL preload | host | 0.48 | 15.9 |
    | D: + `MPICH_GPU_SUPPORT_ENABLED=1` | host | **6.94** | 21.7 |
    | E: + `MPICH_OFI_NIC_POLICY=GPU` | device | 15.9 | 22.3 |
    | F: GTL preloaded, GPU support off | device | segfault (signal 11), as expected | |

  - **GPU-aware MPICH works from a factory-style image** (E). Without
    `MPICH_GPU_SUPPORT_ENABLED` a device buffer crashes the rank (F).
  - **`--nv` and the GTL preload cost nothing** on host buffers (B, C).
  - **Turning GPU support on costs host buffers about 6.5 us a message** (D
    against C): small-message latency rises 15-fold. D7 changes accordingly:
    GPU support is not switched on for every cell of the GPU node type.
  - **Device-to-device within a node is 16 us at 8 bytes**, against the 2-3 us
    that CUDA IPC over NVLink should give. It looks staged through the host. A
    likely cause is `MPICH_SMP_SINGLE_COPY_MODE=NONE`, which the Derecho
    description sets because cross-process memory access does not work in the
    container namespace. That is an open question for measurement against a
    native run, not a blocker. (Answered in step 3, "Single copy": `NONE`
    turns off GPU IPC, and XPMEM works with `libxpmem` preloaded.)
  - OSU 7.5 prints `could not identify the local rank` for device buffers,
    because it does not read `PMI_LOCAL_RANK`. That is harmless: each rank sees
    one GPU.
- **The nvhpc path end to end** (`a100_nvhpc_check.pbs`, 2026-10-30).
  - **Set-up:**
    - `leap-nvhpc-mpich-cuda-26.08`, with `nvhpc/26.1` on the host;
    - Cray MPICH's `ofi/nvidia/23.3` shim;
    - the NVIDIA archive bound from GLADE;
    - four ranks under `--cpu-bind depth -d 16`, each on its NUMA-near GPU;
    - GTL preloaded and `MPICH_GPU_SUPPORT_ENABLED` off.

  Everything ran and both HPL runs passed their residual check. **D8 and D9
  hold.**

  | Run | Result |
  |---|---|
  | NVIDIA-STREAM, 2^28 doubles a GPU, one copy per GPU | Triad 1.382-1.386 TB/s on each GPU, 89% of the A100's 1555 GB/s; Copy 1.402-1.404 TB/s; 5.53 TB/s Triad for the node |
  | HPL-NVIDIA, N = 100352, NB 1024, 2 x 2, NCCL and NVSHMEM from `nvhpc/26.1` | 53.73 TFLOP/s (13.43 a GPU), 12.54 s, residual 4.2e-4 PASSED |
  | The same, NCCL and NVSHMEM from the archive | 53.71 TFLOP/s, 12.54 s, the same residual, PASSED |

  - **NCCL.** Both runs report `NCCL version 2.29.2+cuda12.9`, and their
    figures agree within 0.04%. Taking NCCL from the module costs nothing.
  - **GTL preloaded with GPU support off** does not trouble HPL-NVIDIA, which
    moves data between GPUs with NCCL.
  - **No `Illegal instruction`.** The August image's own libraries ran on
    Milan, although they predate the factory's `-tp=x86-64-v3` fix.
  - **The HPL figure is not a tuned one.** It is 69% of the A100's 19.5 TFLOP/s
    FP64 tensor peak, with the running rate near 67 TFLOP/s before the tail.
    N = 100352 fills about half of each GPU's 40 GB. `nvhpl`'s `prepare`
    should size N from GPU memory, about 134,000 for four 40 GB GPUs, before
    any figure is reported.

### Step 1 -- the factory (`NCAR/hpc-dev-container-factory`, a branch)

1. `cluster-images-ghcr.yaml`: a `gpu` input (`nogpu` by default, or `cuda`)
   carrying the x86_64 CUDA 12.9.1 runfile build arguments. Dispatch it from
   the branch with `publish=false`. nvhpc with CUDA is the one most likely to
   run out of runner disk.
2. `CONTRACT.md`, a new section, "GPU images":
   - the `-cuda` tag;
   - `CUDA_HOME`, `CUDA_VERSION` and `nvcc` on `PATH`;
   - the CUDA libraries resolvable through the linker cache and not only
     through `LD_LIBRARY_PATH`;
   - device code built `-arch=all-major`, and an app's own `-arch=` wins;
   - the driver stubs in the cache, so that the image builds and starts
     without a GPU, and the driver is the host's at run time (`--nv`, or the
     host's directory ahead on `LD_LIBRARY_PATH`);
   - HeFFTe's CUDA build and its architectures.

   Each promise is one that step 0 or the inspection above has shown to hold.
3. `check_base_contract.sh`: the same promises, checked in a `-cuda` image.
   - `nvcc` compiles a probe.
   - `ldconfig -p` resolves `libcudart.so.12` outside `stubs/`.
   - The probe's run on a GPU-less host reports the stub, which is the
     expected answer there.
4. **A GPU report in every `-cuda` image**, `/container/bin/report_gpus`,
   added to the contract's §3 tools. It is the probe above: which `libcuda`
   loaded, the driver and runtime versions, and the devices this process sees
   with their PCI bus IDs. It is to the GPU what `report_placement` is to the
   CPU, and it gives the runner a per-rank answer without involving an app
   (open question 3).
5. OSU's `launch` hook takes `OSU_BUFFERS` (for example `D D`, or `-d managed`
   for the collectives), so that its contract can drive the device-buffer
   runs of D7. It is copied into `hpcrun/tests/fixtures/app.d/osu/`.
6. `heffte.conf` names the directory HeFFTe installs to. `hello_world.cu`
   checks its errors, or is no longer used as a test.
7. Merge, then publish the six `-cuda` images to `ghcr.io/ncar/hpcdev-x86_64`.
   That is a public, outward step, taken by decision and not by default.

**Results, 2026-10-30.** Items 1-6 are on the factory branch `cuda-images`
(commits `782055f` and `afe601e`).

- **CI, `publish=false`.** All twelve images built and passed the contract
  check:
  - the six `-cuda` images, in run 41137691527, which took 88 minutes without
    a build cache;
  - the six CPU images, in run 41137694469, which took 22 minutes.
  - Runner disk was enough for nvhpc with CUDA.
- **Every `-cuda` image passes all of check 11:**
  - `CUDA_HOME=/container/cuda/12.9`;
  - the five libraries resolve through the linker cache outside `stubs/`;
  - nvcc's default is sm_50 to sm_120, and `-arch=sm_90` alone gives sm_90;
  - `report_gpus` runs and answers `CUDA driver is a stub library`, exit 2,
    as a GPU-less runner should;
  - `HEFFTE_ROOT` is `/container/heffte/2.4.1-cuda`.

  Every CPU image passes `EXPECT_GPU=nogpu` and skips the GPU checks. Check 10
  (`libheffte` in the linker cache, `lib64/`) passes in all twelve.
- **CI's OSU test hid a failure.** In both nvhpc `-cuda` images OSU's
  `util/kernel.cu` did not compile:
  - OSU runs `nvcc -cuda`, then `$CXX` on the output, and nvc++ 26.x rejects
    that output with a redeclaration in `_cplus_nvcc.h`;
  - OSU's own remedy, `--nvcchost --no_preincludes`, is applied only when
    `$CXX -V` says `pgc++`, and it fails too, as do the other flag
    combinations tried, and g++ as nvcc's host compiler.

  `build_osu-micro-benchmarks.sh` still exited 0, because nothing checked the
  configure and make chain and its last line ends `|| true`. That is how the
  August nvhpc image came to have no OSU.
- **The fix**, in `afe601e`:
  - nvhpc builds OSU `--enable-cuda=basic`, without the kernels. `D D`,
    `-d cuda` and `-d managed` still work; only point-to-point managed buffers
    (`MD`, `MH`) and the GPU compute in the overlap tests go. OSU's `app.yaml`
    says so.
  - The script exits 1 when the build, or the installed `osu_latency`, fails.

  Run in the August nvhpc-mpich-cuda and gcc14-mpich-cuda images on the login
  node, the script builds OSU and runs `osu_latency` in both (rc 0), and a
  forced download failure exits 1. CI run 41148533187 rebuilt the `-cuda` set
  with the fix in 13 minutes, from cache. All six pass the contract check
  again, and OSU builds and runs `osu_latency` in each: nvhpc with
  `--enable-cuda=basic`, the others with the kernels.
- **`hello_world.cu`** (item 6) is used by no build step or check; check 11's
  probes replace it.

### Step 2 -- the description

- `schema/cluster.json`:
  - `subclusters.<name>.images` gains `gpu` and `apps`, and its `required`
    drops to nothing, since a GPU node type might state only `gpu`;
  - `node` gains `gpus`.
- `sitefile.py`:
  - `image_target` becomes "the node type's images, key by key";
  - `image_sets`, `app_builds` and `render_images_mk` add the `cuda` word and
    the GPU target;
  - `target_conflicts` also compares GPU targets.
- `derecho.yaml` moves to `cpu` and `a100` as in D2. `cpu` is the default, so
  every existing Derecho experiment runs as it does today, and
  `sitegen derecho --write` regenerates `cluster.sh` and `images.mk`.
- Tests:
  - `apps/matrix.py derecho --table` lists the CPU images once and the
    `a100` apps once, on the `-cuda` bases;
  - `make derecho-stream` expects both sets;
  - the existing suite is unchanged.

**Done, 2026-11-02**, with these differences from the list above:
- **Derecho is `cpu` (the default) and `a100`.**
  - `cpu` states no `images:` of its own.
  - `a100` states `gpu: {runtime: cuda, target: sm80, arch: -arch=sm_80}`,
    `compilers: [nvhpc]` and `apps: []`, and takes the cluster's znver3 target.
  - Its node is as measured in step 0, and PBS offers it 64 CPUs and 498864mb
    (`pbsnodes deg0066`).
  - So `derecho` on `a100` is `leap-nvhpc-{mpich,openmpi}-cuda.sif`, `cpu` is
    unchanged, and `make derecho` builds all eight. It pulls the `-cuda` pair
    only once those are published.
- **No apps were added to either list.** `stream`, `hpl`, `nvstream` and
  `nvhpl` do not exist yet. Listing them would give `make` sets with no images,
  and the app workflow, by default, jobs that fail. Each is added with its
  contract in step 4. The `a100` naming is tested on a copy of the description
  instead: `leap-nvhpc-mpich-cuda-nvstream-znver3-sm80` from
  `leap-nvhpc-mpich-cuda`, built with `-tp=zen3` and `-arch=sm_80`.
- **Taken from step 3: the GPU request.** `node.gpus` reaches `cluster.sh`
  (`HPCRUN_GPUS_PER_NODE`, `_VENDOR`, `_MODEL`), and the job's select chunk
  ends `:ngpus=4`. Without it an `a100` experiment would have landed on a CPU
  node described as an A100 one. `validate` shows the GPUs on its node line.
- **Left for later:**
  - the `nvhpc/26.1` pin (D9), because it moves the CPU nodes' nvhpc cells,
    and goes in with the run that checks them;
  - `host_software` (D8), in step 3 as planned.
- **Open for step 4: how the description knows an app is contract-only (D3).**
  `nvstream` and `nvhpl` compile nothing, so they should carry no target. A
  name is made from the description alone today. Either the app says so in
  `apps/<app>/` and sitegen reads it, or the description's `apps:` entry does.
- **Schema.** `gpu` is a sub-cluster key only, and `node.gpus` is allowed in
  both `node:` blocks.
- **Checks.**
  - **`sitegen --check`** refuses:
    - a `cuda` node type whose node has no NVIDIA GPUs;
    - a GPU target without its arch, or a sub-cluster target without its march;
    - a sub-cluster compiler with no host module;
    - one GPU target spelled two ways.
  - **Tests:** `test_bench.sh` has 204 tests; it gains 9, and four are
    reworked: the three that took Derecho to be one node type now use a
    one-node-type copy of it, and its base set has two more images.

### Step 3 -- the run path (generic; no app named)

- ~~`jobfile.py`: the GPU request from `node.gpus.count`.~~ Done in step 2.
- `make_apptainer_launcher.sh`:
  - `--nv`;
  - the per-rank device of D5. It is chosen in a wrapper on the host side of
    `apptainer exec`, as `set_gpu_rank` did, because the local-rank variables
    are set there and the launcher does not use `--cleanenv`;
  - the GTL arm of D7, with its preload joined to a variant's;
  - a bind of `PALS_SPOOL_DIR`, or a refusal when it is not under a bound path.
    PALS keeps `apinfo` there, under the job's `TMPDIR`, and a rank that cannot
    read it fails in `PMI_Init` (step 0). This applies to the CPU node types
    too; it has held so far only because the operator's `TMPDIR` is on GLADE.
- `probe_topology.sh`: `gpus`, `gpu_model`, each GPU's NUMA domain (from
  `/sys/bus/pci/devices/<bus id>/numa_node`, so that it does not depend on
  `nvidia-smi`), and `mem_per_node_mb`. That last one is not GPU-specific: HPL
  sizes its matrix from memory, and nothing in the geometry ABI says how much
  there is.
- The geometry ABI (`APP_CONTRACT.md`): `HPCRUN_GPUS_PER_NODE`,
  `HPCRUN_GPUS_PER_RANK`, `HPCRUN_GPU_MEM_MB` and `HPCRUN_MEM_PER_NODE_MB`.
- `checks.py`, `validate` and `submit`: `requires.gpu` (D6), and the GPU
  target against the node type, as 5b did for the CPU target.
- `host_software` (D8):
  - `schema/cluster.json` gains the block, and `schema/app.json` gains
    `requires.host_software`;
  - `sitegen` emits each install's path and mount into `cluster.sh`, as it does
    for `host_libraries`;
  - the launcher binds it for a cell whose app requires it;
  - `validate` refuses one that is missing;
  - `run.meta` records the binary's sha256.
- `run.meta`: GPU model, driver, CUDA runtime (the `cuda` label), and each
  rank's device and its NUMA domain. The placement rules gain one: `gpu_far`,
  a warning when a rank's cores and its GPU are on different NUMA domains.
- `apps/smoke.sh` and the app workflow: the no-GPU skip of D6, and the
  `hpcdev.gpu*` labels.
- Tests: the off-cluster suite covers all of these with fixtures, as
  `test_bench.sh` already does for `pbsnodes` output with `ngpus`.

**Part 1 done, 2026-11-02: the launch path, enough for OSU on `a100`.**
- **`make_apptainer_launcher.sh`** on a node type whose `node.gpus.vendor` is
  `nvidia`:
  - adds `--nv`;
  - sources `lib/gpu_bind.sh` before the exec, so each rank gets one GPU;
  - in the `cray-mpich-abi` recipe, preloads GTL through
    `APPTAINERENV_LD_PRELOAD`, ahead of a variant's preload rather than over
    it, and refuses to start without the library.
  - `MPICH_GPU_SUPPORT_ENABLED` stays the app's or the experiment's to set.
- **On every node type, the launcher binds `PALS_SPOOL_DIR`** at run time,
  unless a site bind already covers it.
- **`lib/gpu_bind.sh`** is D5 as written:
  - the GPU on the NUMA domain of the rank's first core, chosen from the job's
    `CUDA_VISIBLE_DEVICES` UUIDs;
  - read from `/proc/driver/nvidia/gpus/*/information` and `/sys`, a few
    small files per rank instead of a call to `nvidia-smi`;
  - a UUID that is not on this node is dropped, because PALS gives every node
    the first node's list, and a node left with none uses all of its own GPUs;
  - a list of bare indices is left alone;
  - `HPCRUN_GPU_BIND=none` turns the binding off. It is an environment
    variable for now: a variant's `env:` may not set `HPCRUN_*`, so the
    experiment's `gpu_bind: none` waits.
  - Tried on the login node's two A100s: a rank on CPU 24 (NUMA 3) got
    03:00 (NUMA 3), and `report_gpus` in `leap-nvhpc-mpich-cuda` ran its
    kernel there with GTL preloaded.
- **`runner.sh`** on a GPU node type:
  - each cell's placement run logs every rank's GPU to `gpu_bind_<cell>.txt`;
  - `report_gpus`, part of the factory's contract for `-cuda` images, then runs
    once per rank into `gpus_<cell>.out`;
  - one line reports the ranks, their GPUs, whether each is NUMA-near, and on
    how many ranks a kernel ran;
  - a cell where a kernel did not run on some rank is skipped with its reason;
  - a far GPU adds the rule `gpu_far` to the row;
  - `run.meta` gains `gpus`, `gpu_driver` (from `/proc/driver/nvidia/version`)
    and `image_cuda` (the image's `CUDA_VERSION`).
- **`experiments/derecho-osu-gpu.yaml`**: OSU on `a100`, two ranks of 32 cores
  each, on the two nvhpc `-cuda` images: `osu_latency` with host buffers, then
  `osu_latency` and `osu_bw` with `D D` and `MPICH_GPU_SUPPORT_ENABLED=1`. It
  makes 6 one-node jobs. This is D7's first acceptance test, through hpcrun.
- **Tests:** `test_cluster.sh` gains 25: the launcher on a GPU node type and a
  CPU one, the joined preload, the spool bind, and the binding on a fixture of a
  Derecho A100 node, with its reversed NUMA order.

**Single copy, 2026-11-02: XPMEM in place of `NONE`, on both node types.**
- **What `derecho-osu-gpu` showed.** Every job passed, with each rank on its
  NUMA-near GPU. But Cray MPICH moved device buffers at 6.5 GB/s between two
  A100s, where the host Open MPI moved them at 84 GB/s. Cray's `intro_mpi(3)`
  says `MPICH_SMP_SINGLE_COPY_MODE=NONE`, which Derecho's description set, also
  turns off GPU IPC.
- **Job 8052051 (`a100_single_copy.pbs`)** tried `NONE`, `XPMEM`, `CMA` and the
  variable unset:
  - without `NONE`, device buffers reached 88 GB/s;
  - but host buffers over 8 KiB aborted the rank: MPICH fell back to CMA, and
    the container refuses `process_vm_readv` ("Operation not permitted");
  - XPMEM was never used. MPICH said "XPMEM symbols are not visible to Cray
    MPICH": they are weak, Cray's compiler wrappers link `libxpmem` into a
    native app, and an app built in an image has no such link.
- **Jobs 8052660 (`a100`) and 8052661 (`cpu`), `xpmem_check.pbs`**, with the
  host's `libxpmem` preloaded:
  - XPMEM worked between ranks in separate containers on both node types;
  - OSU's `-c` data check passed at every size, point to point and alltoall;
  - with the variable unset, MPICH chose XPMEM itself;
  - against `NONE`:

    | Node | Test | `NONE` | XPMEM |
    |---|---|---|---|
    | cpu | latency across sockets, 4 MiB | 1103 us | 122 us |
    | cpu | bandwidth across sockets, 4 MiB | 3.7 GB/s | 35 GB/s |
    | cpu | alltoall, 128 ranks, 64 KiB | 23.2 ms | 9.7 ms |
    | a100 | latency, host buffers, 4 MiB | 737 us | 120 us |
    | a100 | bandwidth, device buffers, 4 MiB | 6.5 GB/s | 88 GB/s |
    | a100 | alltoall, 4 ranks, device buffers, 1 MiB | 1100 us | 92 us |

  - small messages did not change: single copy starts at 8 KiB on host buffers
    and GPU IPC at 1 KiB, so device latency at 8 bytes stays near 16 us;
  - compute nodes have `libxpmem` only at `/opt/xpmem/lib64`. Cray's
    `/opt/cray/xpmem` is on the login nodes alone, so the first run of the
    job (8052251, 8052263) found no library.
- **The change:**
  - a new key in the cluster schema, `mpi.<family>.preload`: host libraries the
    host MPI needs and an image's app is not linked with. sitegen emits it as
    `bench_site_mpi_preload`, and refuses a path that no bind puts inside the
    container;
  - the launcher preloads it for every image of the family, ahead of GTL's
    and a variant's, and refuses to start if the file is missing;
  - Derecho's `mpich` and `mpich3` drop `MPICH_SMP_SINGLE_COPY_MODE=NONE`,
    preload `/opt/xpmem/lib64/libxpmem.so.0`, and bind `/opt/xpmem` where it
    exists;
  - on the login node, a singleton through the new launcher reports
    `MPICH_SMP_SINGLE_COPY_MODE = XPMEM`;
  - 8 more tests (5 in `test_cluster.sh`, 3 in `test_bench.sh`).
- **MPICH results on Derecho from before 2026-11-02 were measured with two
  copies.** Anything communication-heavy measures differently from now on, so
  old and new results are not directly comparable. Each results directory
  keeps its launcher, which records the setting.
- **To confirm through hpcrun:** `derecho-osu-gpu` and `derecho-osu` again.
- **Open MPI** has single copy turned off the same way
  (`OMPI_MCA_btl_vader_single_copy_mechanism=none`) and was not tested. Its
  1.97 us host latency, against Cray MPICH's 0.5 us, may come from that.
- **Still to do in step 3:**
  - `probe_topology.sh`'s GPU and memory keys;
  - the geometry ABI;
  - `requires.gpu` and `gpu_aware_mpi` (D6, D7);
  - `host_software` (D8);
  - `MPICH_OFI_NIC_POLICY=GPU`, which needs a per-node-type `env`. That is the
    only thing left for it, now that single copy is the same on both node
    types; it matters once a job spans nodes;
  - the `smoke.sh` skip;
  - the `nvhpc/26.1` pin.

### Step 4 -- the apps

Two apps per benchmark, one per node type, with figures of the same names, so
that `hpcrun/collect` compares them directly. BabelStream, the first draft's
choice, is dropped: NVIDIA-STREAM is McCalpin's kernels on the GPU, so
McCalpin's own code on the CPU gives the closer comparison.

- **`stream` (CPU nodes): McCalpin's `stream.c` 5.10**, built from source with
  OpenMP and `APP_MARCH_FLAGS`. Its license allows redistribution.
  - `prepare` sets `STREAM_ARRAY_SIZE` at run time (the 5.10 source takes it as
    a define, so `build.sh` builds it to read the size from the environment, or
    builds a few sizes). The three arrays are at least four times the node's L3:
    512 MB on the CPU nodes, so 2 GB or more.
  - One rank a node with `OMP_NUM_THREADS` over every core is the STREAM run
    rules' configuration. Ranks on several NUMA domains are a variant.
  - Figures: `copy_gbs`, `scale_gbs`, `add_gbs`, `triad_gbs` (primary), and
    `valid=` from the solution check.
- **`nvstream` (A100 nodes): NVIDIA-STREAM 26.2.0** (`stream_test`, from the
  archive, D8).
  - It is not MPI. Each rank runs one copy on the GPU the runner gave it, and
    the launch passes `-d 0`, because each rank sees only its own GPU.
  - `prepare` chooses `-n` from `HPCRUN_GPU_MEM_MB`: a fixed fraction of the
    40 GB, far past the 40 MB of L2.
  - A small wrapper in the app writes each rank's output to its own file.
    `extract` reports the same four figures, summed across ranks, and the
    slowest rank's Triad.
  - Results are labelled as NVIDIA's variant of STREAM, as McCalpin's rule 3b
    asks.
- **`nvhpl` (A100 nodes): HPL-NVIDIA 26.02.04** (`xhpl`, from the archive, D8),
  one rank per GPU.
  - `prepare` writes `HPL.dat` from the archive's `sample-dat/HPL-<n>GPUs.dat`
    shape: N from the GPUs' memory (about N^2 x 8 bytes, roughly 0.9 of
    4 x 40 GB at `node` scale, which gives N about 134,000; small at `smoke`),
    NB 1024, and P x Q from the rank count (2 x 2 for one node), column-major.
  - `extract` reads HPL's result line (`gflops`, primary) and the residual
    check (`valid=`).
  - **No AVX-512.** Checked 2026-10-30: neither binary names a `%zmm` register,
    and `xhpl` is AVX2 code, so both run on Milan.
- **`hpl` (CPU nodes): netlib HPL 2.3 on the base's OpenBLAS** (CBLAS; serial, so one rank
  a core), CPU nodes only to begin with.
  - `prepare` writes `HPL.dat`: N from `HPCRUN_MEM_PER_NODE_MB` and the node
    count (about 80% of memory at `node` scale, small at `smoke`), and P x Q
  from the rank count.
  - HPL's residual check gives `valid=`.
  - HPL's time is spent in DGEMM, which OpenBLAS dispatches at run time, so this
    is not the "first compute-bound app" that 5b wanted for measuring an app's
    own tuned loops.

### Step 5 -- builds and acceptance

The site installs the NVIDIA archives first (D8). Then
`gh workflow run app-image-builder-ghcr.yaml -f cluster=derecho -f apps=stream,hpl,nvstream,nvhpl`,
then `make derecho-stream derecho-hpl derecho-nvstream derecho-nvhpl`, then:
- `derecho` (OSU, device buffers) on `a100`, the six `-cuda` base images;
- `derecho-stream` and `derecho-hpl` on `cpu`;
- `derecho-nvstream` and `derecho-nvhpl` on `a100`;
- `hpcrun/collect` over the results, where Triad GB/s and HPL GFLOP/s of the
  two node types sit in one table.

The node count can stay at one throughout: the question is whether the path
works and what one node gives, not scaling.

## 5. HPL and STREAM on the GPUs: NVIDIA's HPC-Benchmarks archives

*Revised 2026-10-30.* The first draft had no good GPU HPL. NVIDIA publishes
the binaries of its NGC `hpc-benchmarks` container as plain archives as well,
one per MPI family:

```
https://developer.download.nvidia.com/compute/nvidia-hpc-benchmarks/redist/nvidia_hpc_benchmarks_mpich/linux-x86_64/nvidia_hpc_benchmarks_mpich-linux-x86_64-26.02.04-archive.tar.xz
https://developer.download.nvidia.com/compute/nvidia-hpc-benchmarks/redist/nvidia_hpc_benchmarks_openmpi/linux-x86_64/nvidia_hpc_benchmarks_openmpi-linux-x86_64-26.02.04-archive.tar.xz
```

Both are unpacked in `/glade/derecho/scratch/kedziora/NvidiaBench/`, about
370 MB each. Inspected 2026-10-30.

- **Contents.** Each archive has a `cuda12/` and a `cuda13/` tree, each with:
  - HPL-NVIDIA (`xhpl`, netlib HPL 2.1 underneath, with `sample-dat/` inputs and
    `TUNING`);
  - HPL-MxP;
  - HPCG;
  - NVIDIA-STREAM (`stream_test` and `stream_test_fp32`);
  - NCCL, NVSHMEM and OpenMP microbenchmarks;
  - `lib/` with NCCL 2.29.2, NVSHMEM 3.5.19 and OpenMP runtimes.
- **The mpich archive is built for an HPE Cray system.** Its
  `hpc-benchmarks-gpu-env.sh` selects NVSHMEM over libfabric's `cxi`
  provider, which is Slingshot. `xhpl` links `libmpi.so.12`, which Cray
  MPICH's ABI shim provides.
- **It resolves in the factory's image.** In `leap-gcc14-mpich-cuda-26.08` with
  hpcrun's mpich launch (`gcc/14.3.0` loaded), `ldd` resolves every library of
  `xhpl`:
  - `libcuda` and `libnvidia-ml` from `/host_lib64`;
  - `libcublas.so.12` and `libcublasLt.so.12` from the image's CUDA 12.9;
  - `libmpi.so.12` from `ofi/gnu/12.3/lib-abi-mpich`;
  - `libnccl` and `libnvshmem_host` from the archive's `lib/`.

  `stream_test` needs only `libcudart`, `libcurand` and `libnvidia-ml`. Not
  yet run on a GPU node.
- **The license, the same in both archives, decides how they are used.** It
  grants use "only for your internal use", and its §2.2 forbids distributing
  "any portion of the Software" except to the licensee's own employees and
  contractors on its network (§3). Hence D8: the site installs the archive,
  and no image or repository carries it.
- **Its "Purpose" clause is a question for NCAR, not for this plan.** The
  grant is for use "in systems with NVIDIA GPUs and NVIDIA CPUs". Derecho's A100
  nodes have AMD CPUs. Whether that clause reaches them should be settled
  before results are published.

What the archives do not change:
- **HPL on the CPU nodes stays netlib HPL.** The x86_64 archives carry no CPU
  HPL; NVIDIA's CPU builds are for Grace.
- NVBLAS-offloaded netlib HPL, the first draft's first option, is no longer
  needed.

The same mechanism brings **NVIDIA's HPCG** to the A100 nodes, for comparison
with the CPU `hpcg` app that Derecho already runs, and **HPL-MxP**. Each is
one more contract-only app, with no runner change. They are follow-ons, not
part of this phase's acceptance.

## 6. Risks and open questions

- ~~**GPU-node geometry.**~~ Measured in step 0: NPS4, block SMT, and the GPUs'
  NUMA domains in reverse of PCI order.
- ~~**Intra-node device-to-device latency**~~ (16 us, step 0). It was
  `MPICH_SMP_SINGLE_COPY_MODE=NONE`, which turns off GPU IPC: with XPMEM, 88
  GB/s between two A100s (step 3, "Single copy"). The 16 us at 8 bytes stands.
  It is below the GPU IPC threshold.
- **Across nodes** nothing GPU-related has been run. The two-node OSU run that
  the earlier work did is part of step 5.
- **HPL-NVIDIA across nodes needs NCCL to reach Slingshot.**
  - Within a node, NCCL uses NVLink.
  - Across nodes, it needs a libfabric network plugin, aws-ofi-nccl. None of
    these has one:
    - the archive;
    - Derecho's 25.10 module tree (`module spider nccl` and `aws-ofi-nccl` find
      nothing);
    - `nvhpc/26.1`, whose plugins are InfiniBand ones (D9).
  - Without it NCCL falls back to TCP sockets. Until then a multi-node `nvhpl`
    cell uses host MPI for its broadcast (`HPL_P2P_AS_BCAST=3`), or stays on
    one node.
  - The fix is a site build of aws-ofi-nccl against Derecho's libfabric, as a
    module or in a Spack downstream. It is declared as one more
    `host_software` entry and found through `NCCL_NET_PLUGIN`.
- ~~**Six copies of a contract-only image.**~~ Settled by D9: the GPU node type
  builds nvhpc images only, two per app.
- **The nvhpc pin moves the CPU nodes too** (D9). `nvhpc/26.1` instead of the
  default 25.9 changes the host Open MPI build and the Cray MPICH flavour
  that every nvhpc cell on Derecho loads.
- ~~**Runner disk for nvhpc with CUDA.**~~ It fit, in step 1's CI.
- **Image size.** The gcc14 CUDA `.sif` is 2.9 GB, against a CPU image's; that
  is fine on GLADE, but six of them per app set add up.
- **oneAPI with CUDA.** nvcc uses the system gcc as its host compiler. It built
  in August; whether a mixed icx/nvcc app links is found out in step 4.
- **FastEddy** (`build_fasteddy.sh` in the factory's `scripts/`) was the earlier
  work's real GPU app, and it uses GPU-aware MPI. It is the natural third GPU
  app, after STREAM and HPL, once D7 is shown to work.
- **CUDA 13.** Upstream's `cuda13` branch would put a 13.2 runtime on a 13.0
  driver. Revisit when Derecho's driver moves.
- **Casper's GPUs** (A100 and H100 `nvgpu` nodes) are the next node types this
  fits. The H100 is sm_90, a second GPU target, and so a test of D3's naming.
- `BenchmarkRunnerPlan.md` §11 item 3 (GPU placement) is answered by D5, step
  1.4 and the `gpu_far` rule, if they are accepted.
