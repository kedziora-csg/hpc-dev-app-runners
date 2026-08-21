#!/bin/bash
#-------------------------------------------------------------------------------
# sites/derecho/site.sh -- what a job needs to know about THIS machine.
#
# Sourced, before anything else, by every PBS script here.  It is the answer to
# "where is the harness, where do results go, and how is the module environment
# bootstrapped" -- the four facts that were previously inferred from $(pwd) and
# copied into each script's header.
#
# Inferring them from the cwd meant a job could only be submitted from the
# checkout, which is backwards: a benchmark run belongs in a scratch directory of
# the operator's choosing, and the harness belongs wherever it was cloned.  Those
# are two independent paths and neither should be derived from the other.
#
# HOW A JOB FINDS THIS FILE
#
# The PBS scripts search, first hit wins:
#
#   1. $BENCH_SITE_CONF                              explicit, e.g. via qsub -v
#   2. ./site.sh in the submission directory         per-run override
#   3. ${XDG_CONFIG_HOME:-$HOME/.config}/hpcdev/site.sh    per-user
#   4. ../sites/<site>/site.sh, walking up from the submission directory
#
# Rule 4 is the in-tree case and keeps a submit-from-the-checkout workflow
# working with no setup.  Rule 3 is what makes `qsub /path/to/Placement_derecho.pbs`
# work from ANY directory:
#
#     mkdir -p ~/.config/hpcdev
#     cp <checkout>/containers/deploy/sites/derecho/site.sh ~/.config/hpcdev/
#     $EDITOR ~/.config/hpcdev/site.sh        # set NCAR_HPC_ROOT explicitly
#
# WHY PATHS ARE DERIVED FROM THIS FILE'S OWN LOCATION
#
# The in-tree copy computes NCAR_HPC_ROOT relative to itself, so it always names
# the checkout it belongs to.  Two checkouts therefore cannot be crossed, and no
# absolute path needs editing to clone the repo somewhere new.  A copy placed
# outside a checkout (rule 3) has no checkout to point at, so it must set
# NCAR_HPC_ROOT itself -- everything below honours an already-set value.
#
# WHAT DOES *NOT* BELONG HERE
#
# The declarative site description -- scheduler dialect, queue, bind list,
# topology fallbacks, the container/host-MPI recipe -- is sites/derecho.yaml in
# BenchmarkRunnerPlan.md section 4, and is deliberately still unwritten.  It buys
# nothing until a second site exists to validate the abstraction (phase 4).  This
# file is only the imperative part, and only the part a job cannot start without.
#-------------------------------------------------------------------------------

BENCH_SITE="${BENCH_SITE:-derecho}"

_SITE_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

#-------------------------------------------------------------------------------
# The harness: libexec/ (launcher, placement rules, provenance) and PBS/.
#
# Derived from this file's location for the in-tree copy.  A copy living outside
# a checkout must set this explicitly -- there is nothing to derive it from, and
# guessing would be worse than failing.
#-------------------------------------------------------------------------------
if [ -z "${NCAR_HPC_ROOT:-}" ] && [ -d "${_SITE_HERE}/../../ncar-hpc/libexec" ]; then
    NCAR_HPC_ROOT="$(cd "${_SITE_HERE}/../../ncar-hpc" && pwd)"
fi

# Where the .sif images live.  Separate from the harness because images are big
# and often kept on a different filesystem from the code.
BENCH_IMAGE_DIR="${BENCH_IMAGE_DIR:-${NCAR_HPC_ROOT}/libexec}"

#-------------------------------------------------------------------------------
# Where results directories are created.
#
# Defaults to the directory the job was submitted from: qsub where you want the
# output, which is the least surprising rule and keeps a results directory out
# of the checkout by default.  Point it at scratch to collect runs in one place:
#
#     BENCH_RESULTS_ROOT="${SCRATCH}/hpcdev-bench"
#-------------------------------------------------------------------------------
BENCH_RESULTS_ROOT="${BENCH_RESULTS_ROOT:-${PBS_O_WORKDIR:-$(pwd)}}"

# Big, fast, purgeable.  Apps that stage large input trees ask for this via the
# geometry ABI (BenchmarkRunnerPlan.md section 3).
BENCH_SCRATCH="${BENCH_SCRATCH:-${SCRATCH:-/glade/derecho/scratch/${USER}}}"

#-------------------------------------------------------------------------------
# bench_site_modules -- put the shell into the state every job here starts from.
#
# `module reset` after loading ncarenv is not redundant: ncarenv changes
# MODULEPATH, and reset then applies the site defaults visible under the NEW
# path.  Silenced because Lmod narrates every step; a failure still surfaces
# through the return status, and modules.txt records the result either way.
#-------------------------------------------------------------------------------
bench_site_modules () {
    {
        module --force purge     && \
        module load ncarenv/25.10 && \
        module reset             && \
        module load apptainer
    } >/dev/null 2>&1
}

export BENCH_SITE NCAR_HPC_ROOT BENCH_IMAGE_DIR BENCH_RESULTS_ROOT BENCH_SCRATCH
