#!/usr/bin/env bash

set -e

#-------------------------------------------------------------------------bh-
SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
source /container/extras/build_common.cfg \
    || { echo "cannot locate the base image's build_common.cfg!!"; exit 1; }
#-------------------------------------------------------------------------eh-

#-------------------------------------------------------------------------------
# blas -- a DGEMM/DGEMV probe on OpenBLAS built with DYNAMIC_ARCH.
#
# Test 2 of the seam study (BenchmarkRunnerPlan.md, section 11 item 11): what
# AVX-512 is worth to arithmetic-bound code (BLAS3) and to bandwidth-bound code
# (BLAS2), on each node type, from ONE portable build.
#
# DYNAMIC_ARCH=1 compiles OpenBLAS's kernels for every x86-64 generation it
# knows and picks one from CPUID when the library loads -- the run-time
# dispatch the seam study proposes for libraries in a portable image.
# OPENBLAS_CORETYPE overrides the pick, so one image can run, on the same
# node, its AVX2 kernels (Haswell, Zen) and its AVX-512 ones (SkylakeX,
# Cooperlake), which is the comparison.  The probe prints which core ran.
#
# OpenBLAS is built with the system gcc and no -march, whatever the image's
# compiler: the library is the portable artifact.  BLAS only (no LAPACK, no
# Fortran), single-threaded: one rank per core supplies the parallelism.
#-------------------------------------------------------------------------------
OPENBLAS_VERSION="${OPENBLAS_VERSION:-0.3.30}"
OPENBLAS_URL="${OPENBLAS_URL:-https://github.com/OpenMathLib/OpenBLAS/releases/download/v${OPENBLAS_VERSION}/OpenBLAS-${OPENBLAS_VERSION}.tar.gz}"
OPENBLAS_CC="${OPENBLAS_CC:-/usr/bin/gcc}"
command -v "${OPENBLAS_CC}" >/dev/null 2>&1 || OPENBLAS_CC="gcc"
# Named even with NOFORTRAN=1: OpenBLAS still probes FC for its link flags,
# and the image's FC -- nvfortran, ifx -- draws ifort-style options it rejects.
OPENBLAS_FC="${OPENBLAS_FC:-/usr/bin/gfortran}"
command -v "${OPENBLAS_FC}" >/dev/null 2>&1 || OPENBLAS_FC="gfortran"
PREFIX="${INSTALL_ROOT}/openblas/${OPENBLAS_VERSION}-dynamic"
PROBE_DIR="${INSTALL_ROOT}/blas-probe"

MPICC="${MPICC:-mpicc}"
command -v ${MPICC} >/dev/null 2>&1 || { echo "no ${MPICC} -- is this an MPI image?"; exit 1; }
MARCH_FLAGS="${APP_MARCH_FLAGS:-${MARCH_FLAGS}}"
echo "OpenBLAS    : ${OPENBLAS_VERSION}, DYNAMIC_ARCH, built with ${OPENBLAS_CC}"
echo "MARCH_FLAGS : ${MARCH_FLAGS:-<unset>} (the probe driver only)"

mkdir -p "${STAGE_DIR}" && cd "${STAGE_DIR}"
rm -rf "OpenBLAS-${OPENBLAS_VERSION}"
curl --retry 3 --retry-delay 5 -sSL "${OPENBLAS_URL}" | tar xz
cd "OpenBLAS-${OPENBLAS_VERSION}"

# CFLAGS/FFLAGS from the image environment carry MARCH_FLAGS and the image
# compiler's options; OpenBLAS must not see them, or its "portable" generic
# code would be built for one target.
obflags="DYNAMIC_ARCH=1 TARGET=GENERIC USE_THREAD=0 USE_OPENMP=0 NO_LAPACK=1 NOFORTRAN=1 NUM_THREADS=1"
env -u CFLAGS -u CXXFLAGS -u FFLAGS -u FCFLAGS -u LDFLAGS -u FC -u F77 -u F90 \
    make --no-print-directory -j "${MAKE_J_PROCS:-$(nproc)}" \
        CC="${OPENBLAS_CC}" FC="${OPENBLAS_FC}" ${obflags} libs shared >/dev/null
env -u CFLAGS -u CXXFLAGS -u FFLAGS -u FCFLAGS -u LDFLAGS -u FC -u F77 -u F90 \
    make --no-print-directory CC="${OPENBLAS_CC}" FC="${OPENBLAS_FC}" ${obflags} \
        PREFIX="${PREFIX}" install >/dev/null
rm -f "${PREFIX}"/lib/*.a
lib="$(dirname "$(ls -d ${PREFIX}/lib*/libopenblas.so | head -1)")"

mkdir -p "${PROBE_DIR}/bin"
${MPICC} -O2 ${MARCH_FLAGS} -I"${PREFIX}/include" -o "${PROBE_DIR}/bin/blas_probe" \
    "${SCRIPTDIR}/blas_probe.c" -L"${lib}" -Wl,-rpath,"${lib}" -lopenblas -lm
mkdir -p "${INSTALL_ROOT}/bin"
ln -sf "${PROBE_DIR}/bin/blas_probe" "${INSTALL_ROOT}/bin/blas_probe"
echo "built ${PROBE_DIR}/bin/blas_probe"

app_src="${SCRIPTDIR}/app.d"
[ -f "${app_src}/app.yaml" ] \
    || { echo "no app contract at ${app_src} -- refusing to build an undrivable image"; exit 1; }
app_dst="${INSTALL_ROOT}/app.d/blas"
rm -rf "${app_dst}" && mkdir -p "${app_dst}"
cp -R "${app_src}/." "${app_dst}/"
sed -i "s/@OPENBLAS_VERSION@/${OPENBLAS_VERSION}/g" "${app_dst}/app.yaml"
chmod +x "${app_dst}/launch" "${app_dst}/extract"
printf 'built_with_march: "%s"\n' "${MARCH_FLAGS:-compiler default}" >> "${app_dst}/app.yaml"
echo "installed app contract: ${app_dst}"

cd "${STAGE_DIR}" && rm -rf "OpenBLAS-${OPENBLAS_VERSION}"
exit 0
