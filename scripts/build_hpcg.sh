#!/usr/bin/env bash

set -e

#-------------------------------------------------------------------------bh-
# Common Configuration Environment:

SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
source ${SCRIPTDIR}/build_common.cfg \
    || source /container/extras/build_common.cfg \
    || { echo "cannot locate a suitable build_common.cfg!!"; exit 1; }
#-------------------------------------------------------------------------eh-

#-------------------------------------------------------------------------------
# HPCG -- High Performance Conjugate Gradient.
#
# A hybrid MPI+OpenMP, memory-bandwidth-bound benchmark.  Unlike HPL it is
# dominated by sparse memory access rather than dense FLOPs, which makes it both
# representative of real science codes and sensitive to exactly the NUMA/chiplet
# placement that report_placement measures.  It emits one headline GFLOP/s
# figure, which is what makes it tabulate cleanly across toolchain combinations.
#
# Build model (see the upstream QUICKSTART): write setup/Make.<arch>, then run
# ./configure <arch> from a build directory, then make.  The single most
# important line in that file is
#
#     HPCG_OPTS =
#
# left EMPTY.  Defining -DHPCG_NO_OPENMP or -DHPCG_NO_MPI is what turns the
# hybrid off, and hybrid is the entire point here.
#
# At run time HPCG reads ./hpcg.dat from the CURRENT DIRECTORY, so a harness
# controls problem size and duration by writing its own hpcg.dat in the run
# directory -- see PBS/Placement_derecho_opt.pbs.  A reference copy is installed
# alongside the binary.
#
# NOTE ON OFFICIALNESS: an official HPCG submission requires a run of at least
# 1800 seconds.  Anything shorter is fine for comparing toolchains against each
# other, but must not be reported as an HPCG result.
#-------------------------------------------------------------------------------

HPCG_VERSION="${HPCG_VERSION:-3.1}"
HPCG_TAG="${HPCG_TAG:-HPCG-release-3-1-0}"
HPCG_URL="${HPCG_URL:-https://github.com/hpcg-benchmark/hpcg/archive/refs/tags/${HPCG_TAG}.tar.gz}"

# Reference problem size written next to the binary.  nx/ny/nz are the LOCAL
# problem per rank and must each be a multiple of 8.  104^3 puts the per-rank
# working set well beyond Milan's 32 MB L3, which is required for the
# memory-bandwidth signal to mean anything.
HPCG_NX="${HPCG_NX:-104}"
HPCG_NY="${HPCG_NY:-${HPCG_NX}}"
HPCG_NZ="${HPCG_NZ:-${HPCG_NX}}"
HPCG_SECONDS="${HPCG_SECONDS:-60}"

# Post-build smoke run: deliberately tiny, just enough to prove the binary
# launches and validates.  Set 0 to skip (used during `docker build`).
HPCG_RUN="${HPCG_RUN:-1}"
NRANKS="${NRANKS:-2}"

HPCG_SRC="${STAGE_DIR}/hpcg-${HPCG_TAG}"
HPCG_BUILD_DIR="${HPCG_SRC}/BUILD"
HPCG_INSTALL_DIR="${INSTALL_ROOT}/hpcg/${HPCG_VERSION}"

MPICXX="${MPICXX:-mpicxx}"
which ${MPICXX} >/dev/null 2>&1 \
    || { echo "no ${MPICXX} found -- is this an MPI image?"; exit 1; }

#-------------------------------------------------------------------------------
# Probe for the OpenMP flag rather than switching on COMPILER_FAMILY: the same
# approach as build_report-placement.sh, and it keeps working if COMPILER_FAMILY
# is unset or a new family appears.  -fopenmp (gcc/clang/aocc, and nvhpc as an
# alias), -mp (nvhpc native), -qopenmp (Intel classic spelling).
#-------------------------------------------------------------------------------
openmp_flag=""
mkdir -p ${STAGE_DIR}
probe="${STAGE_DIR}/hpcg_ompprobe.cxx"
cat <<'EOF' > ${probe}
#include <omp.h>
int main () { return omp_get_max_threads () > 0 ? 0 : 1; }
EOF
for flag in -fopenmp -mp -qopenmp; do
    if ${MPICXX} ${flag} -o ${probe}.exe ${probe} >/dev/null 2>&1; then
        openmp_flag="${flag}"
        break
    fi
done
rm -f ${probe} ${probe}.exe
[ -n "${openmp_flag}" ] \
    || { echo "no working OpenMP flag found -- HPCG would be MPI-only, refusing"; exit 1; }

# MARCH_FLAGS is exported into the image environment by the devenv Dockerfile and
# already carries the right spelling for this compiler (nvhpc needs -tp=, not
# -march=, which it silently ignores).  Do not second-guess it here.
echo "OpenMP flag : ${openmp_flag}"
echo "MARCH_FLAGS : ${MARCH_FLAGS:-<unset, using compiler default>}"

#-------------------------------------------------------------------------------
# Fetch
#-------------------------------------------------------------------------------
rm -rf ${HPCG_SRC}
mkdir -p ${STAGE_DIR}
cd ${STAGE_DIR}
echo "downloading ${HPCG_URL} ..."
curl --retry 3 --retry-delay 5 -sSL "${HPCG_URL}" | tar xz
[ -d "${HPCG_SRC}" ] || { echo "unexpected tarball layout; got: $(ls -d ${STAGE_DIR}/hpcg* 2>/dev/null)"; exit 1; }

#-------------------------------------------------------------------------------
# Patch: HPCG 3.1 predates OpenMP 4.0, which removed the rule that const
# variables are predetermined shared.  Its single default(none) region therefore
# omits the loop bound `n`, and every OpenMP >= 4.0 compiler (gcc >= 9, icpx,
# nvc++, clang) rejects it:
#
#     ComputeResidual.cpp:59:13: error: 'n' not specified in enclosing 'parallel'
#
# `n` is read-only, so naming it shared is exactly what the original intended.
# Verify the patch landed -- a silent no-op after an upstream change would put us
# right back at the same build failure with a confusing message.
#-------------------------------------------------------------------------------
sed -i 's/shared(local_residual, v1v, v2v)/shared(local_residual, v1v, v2v, n)/' \
    ${HPCG_SRC}/src/ComputeResidual.cpp
grep -q 'shared(local_residual, v1v, v2v, n)' ${HPCG_SRC}/src/ComputeResidual.cpp \
    || { echo "ComputeResidual.cpp default(none) patch did not apply -- did upstream change?"; exit 1; }
echo "patched: ComputeResidual.cpp default(none) shared clause"

#-------------------------------------------------------------------------------
# Patch: use explicit OpenMP reductions for HPCG's nonzero counters instead of the
# 3.1 source's unnamed critical sections.  GenerateProblem_ref records the matrix
# metadata and CheckProblem validates it; both accumulate the same count inside a
# parallel loop.  Defensive only -- no failure is known to require it, and removing
# it is untested (BenchmarkRunnerPlan.md, open questions).
#-------------------------------------------------------------------------------
for file in ${HPCG_SRC}/src/GenerateProblem_ref.cpp ${HPCG_SRC}/src/CheckProblem.cpp; do
    perl -0pi -e 's/(local_int_t localNumberOfNonzeros = 0;\n\s*\/\/ TODO:.*?\n#ifndef HPCG_NO_OPENMP\n\s*)#pragma omp parallel for/${1}#pragma omp parallel for reduction(+:localNumberOfNonzeros)/s' \
        ${file}
    perl -0pi -e 's/\n#ifndef HPCG_NO_OPENMP\n\s*#pragma omp critical\n#endif\n(\s*localNumberOfNonzeros \+= numberOfNonzerosInRow;)/\n${1}/' \
        ${file}
    grep -q 'parallel for reduction(+:localNumberOfNonzeros)' ${file} \
        || { echo "${file}: OpenMP nonzero reduction patch did not apply"; exit 1; }
    grep -q 'localNumberOfNonzeros += numberOfNonzerosInRow' ${file} \
        || { echo "${file}: nonzero accumulation was removed unexpectedly"; exit 1; }
done
echo "patched: OpenMP nonzero counters use reductions"

#-------------------------------------------------------------------------------
# Configure.  Deliberately NOT using upstream's -ffast-math: it means different
# things to different compilers and can perturb HPCG's own validation, which
# would defeat the point of comparing toolchains on equal terms.
#-------------------------------------------------------------------------------
cat <<EOF > ${HPCG_SRC}/setup/Make.container
SHELL        = /bin/sh
CD           = cd
CP           = cp
LN_S         = ln -s -f
MKDIR        = mkdir -p
RM           = /bin/rm -f
TOUCH        = touch
TOPdir       = .
SRCdir       = \$(TOPdir)/src
INCdir       = \$(TOPdir)/src
BINdir       = \$(TOPdir)/bin
MPdir        =
MPinc        =
MPlib        =
HPCG_INCLUDES = -I\$(INCdir) -I\$(INCdir)/\$(arch) \$(MPinc)
HPCG_LIBS     =
HPCG_OPTS     =
HPCG_DEFS     = \$(HPCG_OPTS) \$(HPCG_INCLUDES)
CXX          = ${MPICXX}
CXXFLAGS     = \$(HPCG_DEFS) -O3 ${MARCH_FLAGS} ${openmp_flag}
LINKER       = \$(CXX)
LINKFLAGS    = \$(CXXFLAGS)
ARCHIVER     = ar
ARFLAGS      = r
RANLIB       = echo
EOF

echo && echo "--- setup/Make.container ---" && cat ${HPCG_SRC}/setup/Make.container && echo

mkdir -p ${HPCG_BUILD_DIR}
cd ${HPCG_BUILD_DIR}
${HPCG_SRC}/configure container
make --no-print-directory --jobs ${MAKE_J_PROCS:-$(nproc)}

[ -x "${HPCG_BUILD_DIR}/bin/xhpcg" ] \
    || { echo "build produced no bin/xhpcg"; exit 1; }

#-------------------------------------------------------------------------------
# Install.  HPCG has no `make install`, so place the binary and a reference
# hpcg.dat by hand, following the ${INSTALL_ROOT}/<pkg>/<version> convention.
#-------------------------------------------------------------------------------
mkdir -p ${HPCG_INSTALL_DIR}/bin
cp ${HPCG_BUILD_DIR}/bin/xhpcg ${HPCG_INSTALL_DIR}/bin/

cat <<EOF > ${HPCG_INSTALL_DIR}/bin/hpcg.dat
HPCG benchmark input file
Reference hpcg.dat installed by build_hpcg.sh -- copy into your run directory.
${HPCG_NX} ${HPCG_NY} ${HPCG_NZ}
${HPCG_SECONDS}
EOF

# Also expose it on PATH alongside report_placement.
mkdir -p ${INSTALL_ROOT}/bin
ln -sf ${HPCG_INSTALL_DIR}/bin/xhpcg ${INSTALL_ROOT}/bin/xhpcg

echo && echo "installed:" && ls -l ${HPCG_INSTALL_DIR}/bin/
report_cpu_features ${HPCG_INSTALL_DIR}/bin/xhpcg 2>/dev/null || ldd ${HPCG_INSTALL_DIR}/bin/xhpcg || true

command -v docker-clean >/dev/null 2>&1 && docker-clean || true

#-------------------------------------------------------------------------------
# Smoke run: tiny problem, few seconds.  Proves the binary launches, that MPI and
# OpenMP are both live, and that HPCG's own validation passes.  It is NOT a
# benchmark -- the harness runs the real thing with its own hpcg.dat.
#-------------------------------------------------------------------------------
if [ "${HPCG_RUN}" != "0" ]; then
    case "${MPI_FAMILY}" in
        "openmpi"*) mpiexec_args="--map-by :OVERSUBSCRIBE" ;;
        "mpich"*)   export MPIR_CVAR_ENABLE_GPU=0; mpiexec_args="" ;;
        *)          mpiexec_args="" ;;
    esac

    smoke="${STAGE_DIR}/hpcg-smoke"
    rm -rf ${smoke} && mkdir -p ${smoke} && cd ${smoke}
    cat <<EOF > hpcg.dat
HPCG benchmark input file
smoke test -- NOT a valid HPCG result
32 32 32
5
EOF
    echo && echo "smoke run: ${NRANKS} rank(s), OMP_NUM_THREADS=${OMP_NUM_THREADS:-<unset>}"
    mpiexec -n ${NRANKS} ${mpiexec_args} ${HPCG_INSTALL_DIR}/bin/xhpcg || {
        echo "HPCG smoke run failed"; exit 1; }

    # HPCG writes HPCG-Benchmark_<ver>_<timestamp>.txt; surface the verdict.
    grep -hE "Final Summary::HPCG result is|GFLOP/s rating" HPCG-Benchmark*.txt 2>/dev/null \
        || echo "(no summary file found -- check the output above)"
fi

cd ${topdir}
exit 0
