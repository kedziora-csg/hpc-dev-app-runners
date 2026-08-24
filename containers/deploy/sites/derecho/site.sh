#!/bin/bash
#===============================================================================
# sites/derecho/site.sh -- what a job needs to know about this machine.
#
# Sourced by every PBS script here, before anything else.  Answers three
# questions: where is the harness, where do results go, and how is the module
# environment set up.
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

# The name recorded in every result row.
BENCH_SITE="${BENCH_SITE:-derecho}"

#-------------------------------------------------------------------------------
# bench_site_modules -- the state every job here starts from.
#
# `module reset` after loading ncarenv is not redundant: ncarenv changes
# MODULEPATH, and reset then applies the site defaults visible under the NEW
# path.  Silenced because Lmod narrates every step; a failure still comes back
# through the return status, and modules.txt records the result either way.
#-------------------------------------------------------------------------------
bench_site_modules () {
    {
        module --force purge      && \
        module load ncarenv/25.10 && \
        module reset              && \
        module load apptainer
    } >/dev/null 2>&1
}


#-------------------------------------------------------------------------------
# Defaults for anything left blank above.  Nothing here needs editing.
#-------------------------------------------------------------------------------
_SITE_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "${NCAR_HPC_ROOT}" ] && [ -d "${_SITE_HERE}/../../ncar-hpc/libexec" ]; then
    NCAR_HPC_ROOT="$(cd "${_SITE_HERE}/../../ncar-hpc" && pwd)"
fi

: "${BENCH_IMAGE_DIR:=${NCAR_HPC_ROOT}/libexec}"
: "${BENCH_RESULTS_ROOT:=${PBS_O_WORKDIR:-$(pwd)}}"

export BENCH_SITE NCAR_HPC_ROOT BENCH_IMAGE_DIR BENCH_RESULTS_ROOT BENCH_SCRATCH

#-------------------------------------------------------------------------------
# WHAT IS NOT HERE
#
# The declarative site description -- scheduler dialect, queue, bind list,
# topology fallbacks, the container/host-MPI recipe -- is sites/derecho.yaml in
# BenchmarkRunnerPlan.md section 4, and is deliberately still unwritten.  It buys
# nothing until a second site exists to check the abstraction against (phase 4).
# This file is only the part a job cannot start without.
#-------------------------------------------------------------------------------
