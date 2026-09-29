#!/bin/bash
#===============================================================================
# sites/ncar/derecho/cluster.sh -- what a job needs to know about Derecho.
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
#   written by hpcrun/sitegen from TWO files -- ../../ncar.yaml, which holds
#   what every NCAR cluster shares, and ../derecho.yaml, which holds what
#   makes Derecho itself -- and hpcrun/tests/test_bench.sh fails while it is stale.
#   Edit the YAML, not the block.
#
# HOW TO USE IT
#
#   Working inside the checkout?  Nothing to do.  A job submitted from anywhere
#   under the repository finds this file by walking up, and works out the paths
#   from where this file itself lives.
#
#   Want to submit from anywhere on the machine?  Copy this file to
#   ~/.config/hpcrun/cluster.sh and set HPCRUN_ROOT below to your clone's hpcrun/.
#
#   That path holds ONE cluster and does not say which, so a copy is used only
#   for the cluster it names -- asking for another passes it over and finds the
#   checkout's own profile instead.  So keep the copy for the machine you mostly
#   work on; the others still work with no setup.  $HPCRUN_SITE_CONF overrides
#   both, and is refused if it names a profile for a different cluster.
#
#   A copy outside the checkout goes stale silently -- sitegen --check only sees
#   the one in the repository.  Re-copy it after a description changes.
#
#   Want a one-off change?  Every generated setting honours an existing value,
#   so `HPCRUN_QUEUE=develop hpcrun/submit ...` wins over the file, and an EMPTY
#   value switches an optional setting off: `HPCRUN_PLACE= hpcrun/submit ...`.
#===============================================================================


#-------------------------------------------------------------------------------
# SETTINGS -- this is the part you edit.
#-------------------------------------------------------------------------------

# The runner: the hpcrun/ directory of your clone.
#
# Leave blank when this file is inside the checkout -- it is then worked out from
# this file's own location, which is always right and survives cloning the
# repository somewhere new.  Set it when the file lives outside a checkout
# (~/.config/hpcrun/cluster.sh), because there is then nothing to work it out
# from.
HPCRUN_ROOT="${HPCRUN_ROOT:-}"
#HPCRUN_ROOT=/glade/derecho/scratch/${USER}/demo_github_actions/hpcrun

# Where the .sif images live.  Separate from the harness because images are big
# and often kept on a different filesystem from the code.  Blank means the
# clone's sif/, where `make` builds them.
HPCRUN_IMAGE_DIR="${HPCRUN_IMAGE_DIR:-}"

# Where results directories are created.  Blank means "the directory the job was
# submitted from", so you submit where you want the output.  Point it at scratch
# to collect every run in one place instead:
#HPCRUN_RESULTS_ROOT=${SCRATCH}/hpcdev-bench
HPCRUN_RESULTS_ROOT="${HPCRUN_RESULTS_ROOT:-}"

# Big, fast, purgeable space, for apps that stage large input trees.
HPCRUN_SCRATCH="${HPCRUN_SCRATCH:-${SCRATCH:-/glade/derecho/scratch/${USER}}}"


#-------------------------------------------------------------------------------
# THE MACHINE -- generated.  Nothing between the markers is hand-maintained;
# ../../ncar.yaml and ../derecho.yaml are where these values are decided.
#-------------------------------------------------------------------------------
# >>> BEGIN GENERATED -- hpcrun/sitegen
#
# Written from sites/ncar.yaml + sites/ncar/derecho.yaml.  Do not edit between the markers: the next
# `hpcrun/sitegen derecho --write` overwrites it, and hpcrun/tests/test_bench.sh
# fails while it is stale.  Change the YAML instead.
#
# Every SETTING below honours a value already in the environment, so a
# one-off `HPCRUN_QUEUE=develop hpcrun/submit ...` wins over the file.
# An EMPTY value counts: `HPCRUN_PLACE= hpcrun/submit ...` switches an
# optional setting off, which is not the same as leaving it unset.
#
# The two IDENTITY variables are the exception: they are assigned, not
# offered, because they are what this file says it describes rather
# than something to propose.
#
# NCAR Derecho: 2 x AMD EPYC 7763 (Milan) per CPU node, SMT on, HPE Cray EX with Slingshot 11

#-- identity -------------------------------------------------------------
HPCRUN_SITE='ncar'
HPCRUN_CLUSTER='derecho'

#-- scheduler ------------------------------------------------------------
[ -n "${HPCRUN_SCHEDULER+set}" ] || HPCRUN_SCHEDULER='pbspro'
[ -n "${HPCRUN_SUBMIT+set}" ] || HPCRUN_SUBMIT='qsub'
[ -n "${HPCRUN_QUEUE+set}" ] || HPCRUN_QUEUE='main'
[ -n "${HPCRUN_WALLTIME_MAX+set}" ] || HPCRUN_WALLTIME_MAX='12:00:00'

#-- node geometry: fallbacks, never measurements --------------------------
# The job probes lscpu and topology.json carries THAT answer.  These
# are what can be known before there is a node to ask, which is when
# an illegal ranks x threads is still cheap to reject.
[ -n "${HPCRUN_CORES_PER_NODE+set}" ] || HPCRUN_CORES_PER_NODE='128'
[ -n "${HPCRUN_SMT+set}" ] || HPCRUN_SMT='2'
[ -n "${HPCRUN_SOCKETS+set}" ] || HPCRUN_SOCKETS='2'
[ -n "${HPCRUN_SMT_STRIDE+set}" ] || HPCRUN_SMT_STRIDE='128'
[ -n "${HPCRUN_CORES_PER_L3+set}" ] || HPCRUN_CORES_PER_L3='8'
[ -n "${HPCRUN_CORES_PER_NUMA+set}" ] || HPCRUN_CORES_PER_NUMA='16'
[ -n "${HPCRUN_TOPOLOGY_MODE+set}" ] || HPCRUN_TOPOLOGY_MODE='probe'

# How to ask the scheduler for THIS node type.  Appended to the select
# directive by hpcrun/submit.  Without it a job takes whatever the pool
# offers, which is how the first Casper run measured hardware this file
# did not describe.
[ -n "${HPCRUN_NODE_SELECT+set}" ] || HPCRUN_NODE_SELECT='mem=230GB'

# What this hardware runs, in report_cpu_features' spelling.  Checked
# against the app binary once at job start: a mismatch costs one line
# before the first cell instead of a SIGILL on every rank, three hours
# into a queue, with no output and exit 132.
[ -n "${HPCRUN_TARGET_ARCH+set}" ] || HPCRUN_TARGET_ARCH='x86-64-v3'

#-- the container --------------------------------------------------------
[ -n "${HPCRUN_CONTAINER_RUNTIME+set}" ] || HPCRUN_CONTAINER_RUNTIME='apptainer'
[ -n "${HPCRUN_BINDS+set}" ] || HPCRUN_BINDS='/glade /local_scratch /run /var/run /opt/cray /etc/cray'
# Bound only where the directory exists: apptainer treats a missing bind
# SOURCE as fatal, so an unconditional bind of a filesystem this machine
# may lack turns 'that mount is absent' into 'the job will not start'.
[ -n "${HPCRUN_BINDS_IF_PRESENT+set}" ] || HPCRUN_BINDS_IF_PRESENT='/usr/lpp/mmfs'
# host:container pairs, for a directory that must NOT land on top of the
# container's own tree.
[ -n "${HPCRUN_BIND_MAP+set}" ] || HPCRUN_BIND_MAP='/usr/lib64:/host_lib64'
# LD_LIBRARY_PATH inside the container, in order, after whatever the MPI
# overlay prepends.  A * entry is a glob and takes its newest match.
[ -n "${HPCRUN_LIB_DIRS+set}" ] || HPCRUN_LIB_DIRS='/opt/cray/pe/lib64 /opt/cray/pals/*/lib ${NCAR_ROOT_LIBFABRIC}/lib64 /opt/cray/libfabric/*/lib64 /usr/lpp/mmfs/lib /usr/lib64'

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

# Which recipe in hpcrun/lib/make_apptainer_launcher.sh swaps the host
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

export HPCRUN_SITE HPCRUN_CLUSTER HPCRUN_SCHEDULER HPCRUN_SUBMIT HPCRUN_QUEUE
export HPCRUN_CORES_PER_NODE HPCRUN_SMT HPCRUN_TOPOLOGY_MODE
export HPCRUN_CONTAINER_RUNTIME HPCRUN_BINDS HPCRUN_BINDS_IF_PRESENT
export HPCRUN_BIND_MAP HPCRUN_LIB_DIRS
export HPCRUN_WALLTIME_MAX HPCRUN_SOCKETS HPCRUN_SMT_STRIDE HPCRUN_CORES_PER_L3 HPCRUN_CORES_PER_NUMA HPCRUN_TARGET_ARCH HPCRUN_NODE_SELECT
# <<< END GENERATED


#-------------------------------------------------------------------------------
# Defaults for anything left blank above.  Nothing here needs editing.
#-------------------------------------------------------------------------------
_CLUSTER_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# sites/<site>/<cluster>/ is three levels below the repository root, which is
# where hpcrun/ and sif/ are.  A generated job script names runner.sh outright,
# so this is for the hand-qsub path, which has only the profile to go on.
if [ -z "${HPCRUN_ROOT}" ] && [ -x "${_CLUSTER_HERE}/../../../hpcrun/runner.sh" ]; then
    HPCRUN_ROOT="$(cd "${_CLUSTER_HERE}/../../../hpcrun" && pwd)"
fi

if [ -z "${HPCRUN_IMAGE_DIR}" ] && [ -d "${HPCRUN_ROOT}/../sif" ]; then
    HPCRUN_IMAGE_DIR="$(cd "${HPCRUN_ROOT}/../sif" && pwd)"
fi
: "${HPCRUN_RESULTS_ROOT:=${PBS_O_WORKDIR:-$(pwd)}}"

export HPCRUN_ROOT HPCRUN_IMAGE_DIR HPCRUN_RESULTS_ROOT HPCRUN_SCRATCH
