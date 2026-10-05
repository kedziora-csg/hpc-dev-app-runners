#!/usr/bin/env bash

set -e

#-------------------------------------------------------------------------bh-
# build_common.cfg is the base image's (INSTALL_ROOT, STAGE_DIR); nothing else
# of the base is relied on beyond its contract and the libraries named below.
SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
source /container/extras/build_common.cfg \
    || { echo "cannot locate the base image's build_common.cfg!!"; exit 1; }
#-------------------------------------------------------------------------eh-

#-------------------------------------------------------------------------------
# HeFFTe's speed3d benchmarks, built against the HeFFTe and FFTW IN THE BASE.
#
# Why this app.  It is the seam study's probe (BenchmarkRunnerPlan.md, §11 item
# 11): HPCG and OSU link only MPI and the compiler runtime, so a tuned base
# image cannot change them.  speed3d is the opposite -- a thin driver whose time
# is spent inside the base's libheffte (reshapes, packing, its own `stock` FFTs)
# and libfftw3 (the 1-D transforms).  Built on a portable base and on a tuned
# one with the same APP_MARCH_FLAGS, the difference between the two is the
# difference the base's tuning makes, and nothing else.
#
# So it deliberately does NOT build its own HeFFTe.  Only the driver is
# compiled here: benchmarks/speed3d_{r2c,c2c}.cpp from the HeFFTe release the
# base installed, linked against that install.
#-------------------------------------------------------------------------------

[ -n "${HEFFTE_ROOT:-}" ] && [ -n "${HEFFTE_VERSION:-}" ] && [ -n "${FFTW_ROOT:-}" ] \
    || { echo "the base image sets no HEFFTE_ROOT/HEFFTE_VERSION/FFTW_ROOT -- not an fftlibs image?"; exit 1; }

HEFFTE_URL="${HEFFTE_URL:-https://github.com/icl-utk-edu/heffte/archive/refs/tags/v${HEFFTE_VERSION}.tar.gz}"
SRC="${STAGE_DIR}/heffte-${HEFFTE_VERSION}"
BENCH_DIR="${INSTALL_ROOT}/heffte-bench/${HEFFTE_VERSION}"

MPICXX="${MPICXX:-mpicxx}"
command -v ${MPICXX} >/dev/null 2>&1 || { echo "no ${MPICXX} -- is this an MPI image?"; exit 1; }

# Same rule as apps/hpcg/build.sh: the app's own flags win, and nvhpc's spelling
# arrives already chosen (-tp=), so nothing here second-guesses it.
MARCH_FLAGS="${APP_MARCH_FLAGS:-${MARCH_FLAGS}}"
echo "HeFFTe      : ${HEFFTE_ROOT} (${HEFFTE_VERSION})"
echo "FFTW        : ${FFTW_ROOT}"
echo "MARCH_FLAGS : ${MARCH_FLAGS:-<unset, using compiler default>}"

rm -rf "${SRC}" && mkdir -p "${STAGE_DIR}" && cd "${STAGE_DIR}"
curl --retry 3 --retry-delay 5 -sSL "${HEFFTE_URL}" | tar xz
[ -f "${SRC}/benchmarks/speed3d.h" ] || { echo "unexpected tarball layout under ${STAGE_DIR}"; exit 1; }

# The benchmark's FFTW path calls fftw_init_threads(), so the threads library
# is linked as well as the plain one.  rpath, so the binary finds the base's
# libraries without LD_LIBRARY_PATH -- the launcher rewrites that variable.
heffte_lib="$(dirname "$(ls -d ${HEFFTE_ROOT}/lib*/libheffte.so | head -1)")"
fftw_lib="$(dirname "$(ls -d ${FFTW_ROOT}/lib*/libfftw3.so | head -1)")"
mkdir -p "${BENCH_DIR}/bin"
for b in speed3d_r2c speed3d_c2c; do
    ${MPICXX} -O3 ${MARCH_FLAGS} -std=c++14 \
        -I"${SRC}/benchmarks" -I"${SRC}/test" -I"${HEFFTE_ROOT}/include" \
        -o "${BENCH_DIR}/bin/${b}" "${SRC}/benchmarks/${b}.cpp" \
        -L"${heffte_lib}" -Wl,-rpath,"${heffte_lib}" -lheffte \
        -L"${fftw_lib}"   -Wl,-rpath,"${fftw_lib}"   -lfftw3_threads -lfftw3 -lfftw3f_threads -lfftw3f
    echo "built ${BENCH_DIR}/bin/${b}"
done

mkdir -p "${INSTALL_ROOT}/bin"
ln -sf "${BENCH_DIR}/bin/speed3d_r2c" "${INSTALL_ROOT}/bin/speed3d_r2c"
ln -sf "${BENCH_DIR}/bin/speed3d_c2c" "${INSTALL_ROOT}/bin/speed3d_c2c"

#-------------------------------------------------------------------------------
# The contract, from beside this script; see apps/hpcg/build.sh for why it
# travels in the image and why the build flags are stamped into it.
#-------------------------------------------------------------------------------
app_src="${SCRIPTDIR}/app.d"
[ -f "${app_src}/app.yaml" ] \
    || { echo "no app contract at ${app_src} -- refusing to build an undrivable image"; exit 1; }
app_dst="${INSTALL_ROOT}/app.d/heffte"
rm -rf "${app_dst}" && mkdir -p "${app_dst}"
cp -R "${app_src}/." "${app_dst}/"
sed -i "s/@HEFFTE_VERSION@/${HEFFTE_VERSION}/g" "${app_dst}/app.yaml"
chmod +x "${app_dst}/launch" "${app_dst}/extract"
printf 'built_with_march: "%s"\n' "${MARCH_FLAGS:-compiler default}" >> "${app_dst}/app.yaml"
echo "installed app contract: ${app_dst} (march: ${MARCH_FLAGS:-compiler default})"

ldd "${BENCH_DIR}/bin/speed3d_r2c" | grep -E 'heffte|fftw|mpi' || true
rm -rf "${SRC}"
exit 0
