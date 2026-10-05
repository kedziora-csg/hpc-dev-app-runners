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
#
# THREE FFTWs, ONE IMAGE
#
# The base's FFTW is configured with no SIMD codelets at all.  FFTW's codelets
# for SSE2, AVX, AVX2 and AVX-512 are chosen at RUN time from CPUID, so they
# are safe in a portable library -- the question test 1 of the seam study asks
# is what they are worth, and what AVX-512 adds over AVX2, on each node type.
# So two more FFTWs are built here, from the base's FFTW version:
#
#     speed3d_r2c          the base's libfftw3          (scalar codelets)
#     speed3d_r2c_avx2     --enable-sse2/avx/avx2       (dispatched, up to AVX2)
#     speed3d_r2c_avx512   ... and --enable-avx512      (dispatched, up to AVX-512)
#
# Each binary finds its own libfftw3 first (RPATH, and linked before
# libheffte), so the base's libheffte, which needs libfftw3.so.3, shares the
# copy already loaded.  The launch hook picks one with HEFFTE_FFTW.  The FFTWs
# are built portably, with the system gcc and no -march: run-time dispatch is
# the point, and it must stay correct on every node the image may meet.
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

# speed3d <source> <output> <libfftw3 dir> -- one driver against one FFTW.
# --disable-new-dtags writes DT_RPATH rather than DT_RUNPATH: RPATH also
# governs the libraries' own dependencies, so libheffte resolves libfftw3 to
# this copy even before the soname match makes it share the loaded one.
speed3d () {
    ${MPICXX} -O3 ${MARCH_FLAGS} -std=c++14 \
        -I"${SRC}/benchmarks" -I"${SRC}/test" -I"${HEFFTE_ROOT}/include" \
        -o "$2" "${SRC}/benchmarks/$1.cpp" \
        -Wl,--disable-new-dtags -Wl,--no-as-needed \
        -L"$3" -Wl,-rpath,"$3" -lfftw3_threads -lfftw3 \
        -L"${fftw_lib}" -Wl,-rpath,"${fftw_lib}" -lfftw3f_threads -lfftw3f \
        -L"${heffte_lib}" -Wl,-rpath,"${heffte_lib}" -lheffte
    echo "built $2 (libfftw3 from $3)"
}
for b in speed3d_r2c speed3d_c2c; do
    speed3d "${b}" "${BENCH_DIR}/bin/${b}" "${fftw_lib}"
done

# The two dispatching FFTWs: double precision and its threads library, which
# is all speed3d's double path reaches.  The same version as the base's.
FFTW_VERSION="${FFTW_VERSION:-3.3.10}"
FFTW_CC="${FFTW_CC:-/usr/bin/gcc}"
command -v "${FFTW_CC}" >/dev/null 2>&1 || FFTW_CC="gcc"
cd "${STAGE_DIR}"
curl --retry 3 --retry-delay 5 -sSL "https://fftw.org/pub/fftw/fftw-${FFTW_VERSION}.tar.gz" | tar xz
for v in avx2 avx512; do
    simd="--enable-sse2 --enable-avx --enable-avx2"
    [ "${v}" = avx512 ] && simd="${simd} --enable-avx512"
    prefix="${BENCH_DIR}/fftw-${v}"
    ( cd "${STAGE_DIR}/fftw-${FFTW_VERSION}" \
      && make distclean >/dev/null 2>&1 || true
      cd "${STAGE_DIR}/fftw-${FFTW_VERSION}" \
      && ./configure CC="${FFTW_CC}" CFLAGS="-O3" --prefix="${prefix}" \
             --enable-shared --disable-static --enable-threads ${simd} \
             --disable-fortran --disable-doc --disable-dependency-tracking >/dev/null \
      && make --no-print-directory --jobs "${MAKE_J_PROCS:-$(nproc)}" >/dev/null \
      && make --no-print-directory install-strip >/dev/null ) \
        || { echo "FFTW ${FFTW_VERSION} (${v}) failed to build"; exit 1; }
    grep -q "HAVE_AVX2 1" "${STAGE_DIR}/fftw-${FFTW_VERSION}/config.h" \
        || { echo "FFTW (${v}) configured without AVX2 codelets"; exit 1; }
    if [ "${v}" = avx512 ]; then
        grep -q "HAVE_AVX512 1" "${STAGE_DIR}/fftw-${FFTW_VERSION}/config.h" \
            || { echo "FFTW (${v}) configured without AVX-512 codelets"; exit 1; }
    fi
    speed3d speed3d_r2c "${BENCH_DIR}/bin/speed3d_r2c_${v}" "$(dirname "$(ls -d ${prefix}/lib*/libfftw3.so | head -1)")"
done
rm -rf "${STAGE_DIR}/fftw-${FFTW_VERSION}"

mkdir -p "${INSTALL_ROOT}/bin"
for b in speed3d_r2c speed3d_c2c speed3d_r2c_avx2 speed3d_r2c_avx512; do
    ln -sf "${BENCH_DIR}/bin/${b}" "${INSTALL_ROOT}/bin/${b}"
done

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

for b in speed3d_r2c speed3d_r2c_avx2 speed3d_r2c_avx512; do
    echo "${b}:"; ldd "${BENCH_DIR}/bin/${b}" | grep -E 'libfftw3\.|heffte' || true
done
rm -rf "${SRC}"
exit 0
