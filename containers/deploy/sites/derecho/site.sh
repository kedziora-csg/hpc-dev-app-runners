#!/bin/bash
#===============================================================================
# sites/derecho/site.sh -- what a job needs to know about this machine.
#
# Sourced by every PBS script here, before anything else.  It has two halves,
# and the split is the point:
#
#   THE PART YOU EDIT is four paths -- where the checkout is, where the images
#   are, where results go, which scratch.  Those are properties of the OPERATOR.
#   They differ between two people on the same machine, and nothing can work
#   them out for you.
#
#   THE GENERATED PART, between the markers below, is everything that is a
#   property of the MACHINE: the scheduler dialect, the module bootstrap, the
#   node geometry, the container bind list and the host-MPI recipe.  It is
#   written from ../derecho.yaml by bench/sitegen, and bench/test_bench.sh fails
#   while it is stale.  Edit the YAML, not the block.
#
# HOW TO USE IT
#
#   Working inside the checkout?  Nothing to do.  A job submitted from anywhere
#   under the repository finds this file by walking up, and works out the paths
#   from where this file itself lives.
#
#   Want to submit from anywhere on the machine?  Copy this file to
#   ~/.config/hpcdev/site.sh and set NCAR_HPC_ROOT below to your clone.
#   NCAR_HPC_ROOT = /path/to/demo_github_actions/containers/deploy/ncar-hpc
#   or /path/to/demo_github_actions/containers/deploy/<site_dir>
#
#   That path holds ONE site and does not say which, so a copy is used only for
#   the site it names -- asking for another one passes it over and finds the
#   checkout's own profile instead.  So keep the copy for the machine you mostly
#   work on; the others still work with no setup.  $BENCH_SITE_CONF overrides
#   both, and is refused if it names a profile for a different machine.
#
#   A copy outside the checkout goes stale silently -- sitegen --check only sees
#   the one in the repository.  Re-copy it after a site description changes.
#
#   Want a one-off change?  Every setting honours an existing value, so
#   `qsub -v BENCH_RESULTS_ROOT=$SCRATCH/runs ...` wins over the file.
#===============================================================================


#-------------------------------------------------------------------------------
# SETTINGS -- this is the part you edit.
#-------------------------------------------------------------------------------

# The clone: the directory containing libexec/ and PBS/.
#
# Leave blank when this file is inside the checkout -- it is then worked out from
# this file's own location, which is always right and survives cloning the
# repository somewhere new.  Set it when the file lives outside a checkout
# (~/.config/hpcdev/site.sh), because there is then nothing to work it out from.
NCAR_HPC_ROOT="${NCAR_HPC_ROOT:-}"
#NCAR_HPC_ROOT=/glade/derecho/scratch/${USER}/demo_github_actions/containers/deploy/ncar-hpc

# Where the .sif images live.  Separate from the harness because images are big
# and often kept on a different filesystem from the code.
BENCH_IMAGE_DIR="${BENCH_IMAGE_DIR:-}"

# Where results directories are created.  Blank means "the directory the job was
# submitted from", so you qsub where you want the output.  Point it at scratch to
# collect every run in one place instead:
#BENCH_RESULTS_ROOT=${SCRATCH}/hpcdev-bench
BENCH_RESULTS_ROOT="${BENCH_RESULTS_ROOT:-}"

# Big, fast, purgeable space, for apps that stage large input trees.
BENCH_SCRATCH="${BENCH_SCRATCH:-${SCRATCH:-/glade/derecho/scratch/${USER}}}"


#-------------------------------------------------------------------------------
# THE MACHINE -- generated.  Nothing below this line to the closing marker is
# hand-maintained; ../derecho.yaml is where these values are decided.
#-------------------------------------------------------------------------------
# >>> BEGIN GENERATED -- bench/sitegen
#
# Written from sites/derecho.yaml.  Do not edit between the markers: the next
# `bench/sitegen derecho --write` overwrites it, and bench/test_bench.sh
# fails while it is stale.  Change the YAML instead.
#
# Every setting below honours a value already in the environment, so a
# one-off `BENCH_QUEUE=develop bench/submit ...` wins over the file.
# An EMPTY value counts: `BENCH_PLACE= bench/submit ...` switches an
# optional setting off, which is not the same as leaving it unset.
#
# NCAR Derecho: 2 x AMD EPYC 7763 (Milan) per CPU node, SMT on, HPE Cray EX with Slingshot 11

#-- identity and scheduler -----------------------------------------------
[ -n "${BENCH_SITE+set}" ] || BENCH_SITE='derecho'
[ -n "${BENCH_SCHEDULER+set}" ] || BENCH_SCHEDULER='pbspro'
[ -n "${BENCH_SUBMIT+set}" ] || BENCH_SUBMIT='qsub'
[ -n "${BENCH_QUEUE+set}" ] || BENCH_QUEUE='main'
[ -n "${BENCH_WALLTIME_MAX+set}" ] || BENCH_WALLTIME_MAX='12:00:00'

#-- node geometry: fallbacks, never measurements --------------------------
# The job probes lscpu and topology.json carries THAT answer.  These
# are what can be known before there is a node to ask, which is when
# an illegal ranks x threads is still cheap to reject.
[ -n "${BENCH_CORES_PER_NODE+set}" ] || BENCH_CORES_PER_NODE='128'
[ -n "${BENCH_SMT+set}" ] || BENCH_SMT='2'
[ -n "${BENCH_SOCKETS+set}" ] || BENCH_SOCKETS='2'
[ -n "${BENCH_SMT_STRIDE+set}" ] || BENCH_SMT_STRIDE='128'
[ -n "${BENCH_CORES_PER_L3+set}" ] || BENCH_CORES_PER_L3='8'
[ -n "${BENCH_CORES_PER_NUMA+set}" ] || BENCH_CORES_PER_NUMA='16'
[ -n "${BENCH_TOPOLOGY_MODE+set}" ] || BENCH_TOPOLOGY_MODE='probe'

# What this hardware runs, in report_cpu_features' spelling.  Checked
# against the app binary once at job start: a mismatch costs one line
# before the first cell instead of a SIGILL on every rank, three hours
# into a queue, with no output and exit 132.
[ -n "${BENCH_TARGET_ARCH+set}" ] || BENCH_TARGET_ARCH='x86-64-v3'

#-- the container --------------------------------------------------------
[ -n "${BENCH_CONTAINER_RUNTIME+set}" ] || BENCH_CONTAINER_RUNTIME='apptainer'
[ -n "${BENCH_BINDS+set}" ] || BENCH_BINDS='/glade /local_scratch /run /var/run /opt/cray /etc/cray'
# Bound only where the directory exists: apptainer treats a missing bind
# SOURCE as fatal, so an unconditional bind of a filesystem this machine
# may lack turns 'that mount is absent' into 'the job will not start'.
[ -n "${BENCH_BINDS_IF_PRESENT+set}" ] || BENCH_BINDS_IF_PRESENT='/usr/lpp/mmfs'
# host:container pairs, for a directory that must NOT land on top of the
# container's own tree.
[ -n "${BENCH_BIND_MAP+set}" ] || BENCH_BIND_MAP='/usr/lib64:/host_lib64'
# LD_LIBRARY_PATH inside the container, in order, after whatever the MPI
# overlay prepends.  A * entry is a glob and takes its newest match.
[ -n "${BENCH_LIB_DIRS+set}" ] || BENCH_LIB_DIRS='/opt/cray/pe/lib64 /opt/cray/pals/*/lib ${NCAR_ROOT_LIBFABRIC}/lib64 /opt/cray/libfabric/*/lib64 /usr/lpp/mmfs/lib /usr/lib64'

#-- host modules ---------------------------------------------------------
# Container compiler tag to host module.  The host MPI that
# displaces the container's must be built with a compatible
# compiler, and the tag in the image name is what names which.
bench_site_compiler_module () {
    case "$1" in
        aocc    ) echo 'aocc' ;;
        clang   ) echo 'clang' ;;
        gcc     ) echo 'gcc' ;;
        gcc14   ) echo 'gcc/14.3.0' ;;
        nvhpc   ) echo 'nvhpc' ;;
        oneapi  ) echo 'intel' ;;
        *       ) echo '' ;;
    esac
}

# Container MPI family to host module.  Empty means the host MPI is
# already in the default environment and there is nothing to load.
bench_site_mpi_module () {
    case "$1" in
        mpich   ) echo '' ;;
        mpich3  ) echo '' ;;
        openmpi ) echo 'openmpi' ;;
        *       ) echo '' ;;
    esac
}

# Modules to drop first, because one left loaded by a previous image
# would put its own mpiexec and libraries ahead of this family's.
bench_site_mpi_unload () {
    case "$1" in
        mpich   ) echo 'openmpi' ;;
        mpich3  ) echo 'openmpi' ;;
        *       ) echo '' ;;
    esac
}

#-- the host-MPI recipe, per container MPI family -------------------------
# Which mpiexec dialect emits this family's placement flags.
bench_site_mpi_launcher () {
    case "$1" in
        mpich   ) echo 'pals' ;;
        mpich3  ) echo 'pals' ;;
        openmpi ) echo 'openmpi' ;;
        *       ) echo '' ;;
    esac
}

# Which recipe in libexec/make_apptainer_launcher.sh swaps the host
# MPI in.  A name, not a description: the recipe body encodes
# reasoning, and reasoning does not belong in a data file.
bench_site_mpi_overlay () {
    case "$1" in
        mpich   ) echo 'cray-mpich-abi' ;;
        mpich3  ) echo 'cray-mpich-abi' ;;
        openmpi ) echo 'host-openmpi' ;;
        *       ) echo '' ;;
    esac
}

# NAME=VALUE, space separated, set inside the container for this
# family.  Where a workaround specific to this machine goes.
bench_site_mpi_env () {
    case "$1" in
        mpich   ) echo 'MPICH_SMP_SINGLE_COPY_MODE=NONE MPICH_VERSION_DISPLAY=1' ;;
        mpich3  ) echo 'MPICH_SMP_SINGLE_COPY_MODE=NONE MPICH_VERSION_DISPLAY=1' ;;
        openmpi ) echo 'OMPI_MCA_btl_vader_single_copy_mechanism=none UCX_POSIX_USE_PROC_LINK=n' ;;
        *       ) echo '' ;;
    esac
}

#-- the module environment every job starts from --------------------------
# Order is the content, so this is a list rather than one command.
# Silenced because Lmod narrates every step; a failure still comes back
# through the return status, and modules.txt records the result anyway.
bench_site_modules () {
    {
        module --force purge && \
        module load ncarenv/25.10 && \
        module reset && \
        module load apptainer
    } >/dev/null 2>&1
}

export BENCH_SITE BENCH_SCHEDULER BENCH_SUBMIT BENCH_QUEUE
export BENCH_CORES_PER_NODE BENCH_SMT BENCH_TOPOLOGY_MODE
export BENCH_CONTAINER_RUNTIME BENCH_BINDS BENCH_BINDS_IF_PRESENT
export BENCH_BIND_MAP BENCH_LIB_DIRS
export BENCH_WALLTIME_MAX BENCH_SOCKETS BENCH_SMT_STRIDE BENCH_CORES_PER_L3 BENCH_CORES_PER_NUMA BENCH_TARGET_ARCH
# <<< END GENERATED


#-------------------------------------------------------------------------------
# Defaults for anything left blank above.  Nothing here needs editing.
#-------------------------------------------------------------------------------
_SITE_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "${NCAR_HPC_ROOT}" ] && [ -d "${_SITE_HERE}/../../ncar-hpc/libexec" ]; then
    NCAR_HPC_ROOT="$(cd "${_SITE_HERE}/../../ncar-hpc" && pwd)"
fi

: "${BENCH_IMAGE_DIR:=${NCAR_HPC_ROOT}/libexec}"
: "${BENCH_RESULTS_ROOT:=${PBS_O_WORKDIR:-$(pwd)}}"

# bench/ is a sibling of ncar-hpc/, not a child: it is site-agnostic, and
# ncar-hpc/ is not.  A generated job script names runner.sh outright, so this is
# for the hand-qsub path, which has only the site profile to go on.
if [ -z "${BENCH_ROOT:-}" ] && [ -d "${NCAR_HPC_ROOT}/../bench" ]; then
    BENCH_ROOT="$(cd "${NCAR_HPC_ROOT}/../bench" && pwd)"
fi

export NCAR_HPC_ROOT BENCH_IMAGE_DIR BENCH_RESULTS_ROOT BENCH_SCRATCH BENCH_ROOT
