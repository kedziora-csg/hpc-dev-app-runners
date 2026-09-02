#!/bin/bash
#===============================================================================
# sites/casper/site.sh -- what a job needs to know about this machine.
#
# UNVERIFIED.  The generated block below comes from ../casper.yaml, which was
# written from PBS/OSU_casper.pbs rather than from a job that ran.  Read that
# file's header before trusting anything here, and see bench/sitegen.
#
# Sourced by every PBS script here, before anything else.  It has two halves:
#
#   THE PART YOU EDIT is four paths -- where the checkout is, where the images
#   are, where results go, which scratch.  Those are properties of the OPERATOR.
#
#   THE GENERATED PART, between the markers, is a property of the MACHINE and is
#   written from ../casper.yaml by bench/sitegen.  Edit the YAML, not the block.
#
# HOW TO USE IT
#
#   Working inside the checkout?  Nothing to do -- the paths are worked out from
#   where this file itself lives.
#
#   Submitting from anywhere on the machine?  Copy this file to
#   ~/.config/hpcdev/site.sh and set NCAR_HPC_ROOT below to your clone.  Note
#   that ~/.config holds ONE profile, so a copy there picks a site: keep the
#   copy for whichever machine you mostly work on and let the other be found by
#   walking up from the checkout.
#===============================================================================


#-------------------------------------------------------------------------------
# SETTINGS -- this is the part you edit.
#-------------------------------------------------------------------------------

# The clone: the directory containing libexec/ and PBS/.  Leave blank inside the
# checkout; set it when this file lives outside one.
NCAR_HPC_ROOT="${NCAR_HPC_ROOT:-}"

# Where the .sif images live.
BENCH_IMAGE_DIR="${BENCH_IMAGE_DIR:-}"

# Where results directories are created.  Blank means the directory the job was
# submitted from.
BENCH_RESULTS_ROOT="${BENCH_RESULTS_ROOT:-}"

# Big, fast, purgeable space, for apps that stage large input trees.
BENCH_SCRATCH="${BENCH_SCRATCH:-${SCRATCH:-/glade/derecho/scratch/${USER}}}"


#-------------------------------------------------------------------------------
# THE MACHINE -- generated.  Nothing below this line to the closing marker is
# hand-maintained; ../casper.yaml is where these values are decided.
#-------------------------------------------------------------------------------
# >>> BEGIN GENERATED -- bench/sitegen
#
# Written from sites/casper.yaml.  Do not edit between the markers: the next
# `bench/sitegen casper --write` overwrites it, and bench/test_bench.sh
# fails while it is stale.  Change the YAML instead.
#
# Every setting below honours a value already in the environment, so a
# one-off `qsub -v BENCH_QUEUE=develop ...` still wins over the file.
#
# NCAR Casper high-throughput nodes (crhtc<nn>): 2 x 18-core Xeon Gold 6240 (Cascade Lake), 36 cores, SMT on
#
# UNVERIFIED: nothing here has been confirmed by a job that ran.
# Treat every value as a hypothesis until one has.

#-- identity and scheduler -----------------------------------------------
[ -n "${BENCH_SITE:-}" ] || BENCH_SITE='casper'
[ -n "${BENCH_SCHEDULER:-}" ] || BENCH_SCHEDULER='pbspro'
[ -n "${BENCH_SUBMIT:-}" ] || BENCH_SUBMIT='qsub'
[ -n "${BENCH_QUEUE:-}" ] || BENCH_QUEUE='casper'
[ -n "${BENCH_WALLTIME_MAX:-}" ] || BENCH_WALLTIME_MAX='24:00:00'

#-- node geometry: fallbacks, never measurements --------------------------
# The job probes lscpu and topology.json carries THAT answer.  These
# are what can be known before there is a node to ask, which is when
# an illegal ranks x threads is still cheap to reject.
[ -n "${BENCH_CORES_PER_NODE:-}" ] || BENCH_CORES_PER_NODE='36'
[ -n "${BENCH_SMT:-}" ] || BENCH_SMT='2'
[ -n "${BENCH_SOCKETS:-}" ] || BENCH_SOCKETS='2'
[ -n "${BENCH_SMT_STRIDE:-}" ] || BENCH_SMT_STRIDE='36'
[ -n "${BENCH_CORES_PER_L3:-}" ] || BENCH_CORES_PER_L3='18'
[ -n "${BENCH_CORES_PER_NUMA:-}" ] || BENCH_CORES_PER_NUMA='18'
[ -n "${BENCH_TOPOLOGY_MODE:-}" ] || BENCH_TOPOLOGY_MODE='probe'

# What this hardware runs, in report_cpu_features' spelling.  Checked
# against the app binary once at job start: a mismatch costs one line
# before the first cell instead of a SIGILL on every rank, three hours
# into a queue, with no output and exit 132.
[ -n "${BENCH_TARGET_ARCH:-}" ] || BENCH_TARGET_ARCH='x86-64-v4'

#-- the container --------------------------------------------------------
[ -n "${BENCH_CONTAINER_RUNTIME:-}" ] || BENCH_CONTAINER_RUNTIME='apptainer'
[ -n "${BENCH_BINDS:-}" ] || BENCH_BINDS='/glade /local_scratch /proc'
# Bound only where the directory exists: apptainer treats a missing bind
# SOURCE as fatal, so an unconditional bind of a filesystem this machine
# may lack turns 'that mount is absent' into 'the job will not start'.
[ -n "${BENCH_BINDS_IF_PRESENT:-}" ] || BENCH_BINDS_IF_PRESENT='/usr/lpp/mmfs /run /var/run'
# host:container pairs, for a directory that must NOT land on top of the
# container's own tree.
[ -n "${BENCH_BIND_MAP:-}" ] || BENCH_BIND_MAP='/usr/lib64:/host_lib64'
# LD_LIBRARY_PATH inside the container, in order, after whatever the MPI
# overlay prepends.  A * entry is a glob and takes its newest match.
[ -n "${BENCH_LIB_DIRS:-}" ] || BENCH_LIB_DIRS='${NCAR_ROOT_OPENMPI}/lib /usr/lpp/mmfs/lib /usr/lib64'

#-- host modules ---------------------------------------------------------
# Container compiler tag to host module.  The host MPI that
# displaces the container's must be built with a compatible
# compiler, and the tag in the image name is what names which.
bench_site_compiler_module () {
    case "$1" in
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
        openmpi ) echo 'openmpi' ;;
        *       ) echo '' ;;
    esac
}

# Modules to drop first, because one left loaded by a previous image
# would put its own mpiexec and libraries ahead of this family's.
bench_site_mpi_unload () {
    case "$1" in
        *       ) echo '' ;;
    esac
}

#-- the host-MPI recipe, per container MPI family -------------------------
# Which mpiexec dialect emits this family's placement flags.
bench_site_mpi_launcher () {
    case "$1" in
        openmpi ) echo 'openmpi' ;;
        *       ) echo '' ;;
    esac
}

# Which recipe in libexec/make_apptainer_launcher.sh swaps the host
# MPI in.  A name, not a description: the recipe body encodes
# reasoning, and reasoning does not belong in a data file.
bench_site_mpi_overlay () {
    case "$1" in
        openmpi ) echo 'host-openmpi' ;;
        *       ) echo '' ;;
    esac
}

# NAME=VALUE, space separated, set inside the container for this
# family.  Where a workaround specific to this machine goes.
bench_site_mpi_env () {
    case "$1" in
        openmpi ) echo 'UCX_POSIX_USE_PROC_LINK=n' ;;
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
        module load apptainer && \
        module load cuda
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

if [ -z "${BENCH_ROOT:-}" ] && [ -d "${NCAR_HPC_ROOT}/../bench" ]; then
    BENCH_ROOT="$(cd "${NCAR_HPC_ROOT}/../bench" && pwd)"
fi

export NCAR_HPC_ROOT BENCH_IMAGE_DIR BENCH_RESULTS_ROOT BENCH_SCRATCH BENCH_ROOT
