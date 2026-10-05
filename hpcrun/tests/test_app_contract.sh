#!/bin/bash
#-------------------------------------------------------------------------------
# test_app_contract.sh -- run every contract in the repository against a stub
# launcher, with no cluster, no container and no MPI.  They live in two places:
# scripts/app.d/ for what the base images carry (OSU), apps/<app>/app.d/ for
# the apps this repository builds on top of them (HPCG).
#
#     ./test_app_contract.sh
#
# The stub launcher just execs its arguments, so the hooks run as themselves on
# the host.  That is enough to check the things that actually break: that
# app.yaml declares what the runner reads, that prepare writes into the run
# directory and nowhere else, that extract turns a captured output file into
# `key=value`, and that a missing or unreadable output is a MISSING METRIC
# rather than a failure.
#
# Adding an app should add a case here and change nothing else.  If it forces an
# edit to app_contract.sh or to the PBS runner, the contract has failed.
#-------------------------------------------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${HERE}/../.."
. "${HERE}/../lib/probe_topology.sh"  || { echo "cannot source probe_topology.sh"; exit 1; }
. "${HERE}/../lib/app_contract.sh"    || { echo "cannot source app_contract.sh"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT

# One directory of every contract, as /container/app.d/ would hold them.
APPD="${TMP}/app.d"; mkdir -p "${APPD}"
for d in "${ROOT}"/scripts/app.d/*/ "${ROOT}"/apps/*/app.d/; do
    [ -f "${d}/app.yaml" ] || continue
    name="$(sed -n 's/^app:[[:space:]]*//p' "${d}/app.yaml" | head -1)"
    ln -s "$(cd "${d}" && pwd)" "${APPD}/${name}"
done
[ -n "$(ls "${APPD}")" ] || { echo "  SKIP  no app contracts under ${ROOT}"; exit 0; }
pass=0 fail=0

# A launcher that runs things on the host instead of inside a container.
LAUNCH="${TMP}/launch-stub"
cat > "${LAUNCH}" <<'STUB'
#!/bin/bash
exec "$@"
STUB
chmod +x "${LAUNCH}"

ok   () { echo "  ok    $1"; pass=$((pass + 1)); }
bad  () { echo "  FAIL  $1"; shift; [ $# -gt 0 ] && printf '        %s\n' "$@"; fail=$((fail + 1)); }
want () { # want <description> <expected> <actual>
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected: $2" "got:      $3"; fi
}
has  () { # has <description> <file> <key=value>
    if grep -qxF "$3" "$2" 2>/dev/null; then ok "$1"
    else bad "$1" "no '$3' in $2" "$(sed 's/^/          /' "$2" 2>/dev/null)"; fi
}

# Every app is resolved through HPCRUN_APP_DIR, which is also the development
# override the runner offers -- so this exercises that path too.
export HPCRUN_APP_DIR="${APPD}"
load_topology ""            # built-in fallback: Derecho geometry

echo "app contract"
echo

#-- every contract declares what the runner reads ------------------------------
for d in "${APPD}"/*/; do
    app="$(basename "${d}")"
    [ -f "${d}/app.yaml" ] || continue
    out="${TMP}/${app}"; mkdir -p "${out}"
    if app_resolve "${app}" "${LAUNCH}" "${out}" 2>"${TMP}/err"; then
        if [ -n "${APP_NAME}" ] && [ -n "${APP_BINARY}" ]; then
            ok "${app}: app.yaml declares name and binary (${APP_NAME}, ${APP_VERSION:-no version})"
        else
            bad "${app}: app.yaml is missing name or binary"
        fi
        [ -f "${out}/app.yaml" ] && ok "${app}: app.yaml copied into the results directory" \
                                 || bad "${app}: app.yaml was not copied for provenance"
        [ "${APP_DIR_OVERRIDE}" = true ] && ok "${app}: HPCRUN_APP_DIR is recorded as an override" \
                                         || bad "${app}: override not flagged"
    else
        bad "${app}: app_resolve failed" "$(cat "${TMP}/err")"
    fi
done

#-- hpcg: prepare writes an input file, extract reads a report -----------------
echo
app_resolve hpcg "${LAUNCH}" "${TMP}/hpcg" >/dev/null 2>&1
run="${TMP}/hpcg/run"; mkdir -p "${run}"
app_export_geometry "${run}" ccd 2 32 16 8

if app_prepare "${run}"; then
    ok "hpcg: prepare accepted the cell"
    if [ -f "${run}/hpcg.dat" ]; then
        want "hpcg: prepare sized the local problem from HPCRUN_TARGET_SECONDS" \
             "60" "$(sed -n 4p "${run}/hpcg.dat")"
        nx="$(awk 'NR==3{print $1}' "${run}/hpcg.dat")"
        [ $(( nx % 8 )) -eq 0 ] && ok "hpcg: nx=${nx} is a multiple of 8, as HPCG requires" \
                                || bad "hpcg: nx=${nx} is not a multiple of 8"
    else
        bad "hpcg: prepare wrote no hpcg.dat"
    fi
    # nothing outside the run directory
    [ -z "$(find "${TMP}/hpcg" -maxdepth 1 -newer "${LAUNCH}" -name 'hpcg.dat')" ] \
        && ok "hpcg: prepare wrote only inside HPCRUN_RUNDIR" \
        || bad "hpcg: prepare wrote outside HPCRUN_RUNDIR"
else
    bad "hpcg: prepare declined a cell it should accept"
fi

# A smoke-scale cell must be seconds, not a minute -- this is what keeps CI cheap.
HPCRUN_SCALE=smoke app_export_geometry "${run}" ccd 2 32 16 8
rm -f "${run}/hpcg.dat"; app_prepare "${run}" >/dev/null 2>&1
want "hpcg: HPCRUN_SCALE=smoke shortens the run" "5" "$(sed -n 4p "${run}/hpcg.dat")"

# extract against a real captured report
cat > "${run}/HPCG-Benchmark_3.1_test.txt" <<'REPORT'
HPCG-Benchmark
version=3.1
Benchmark Time Summary::Total=60.0429
Final Summary::Reference version of ComputeMG used and number of threads greater than 1=Performance results are severely suboptimal
Final Summary::HPCG result is VALID with a GFLOP/s rating of=77.0017
REPORT
app_extract "${run}" "${TMP}/hpcg.kv"
has "hpcg: extract reports the figure of merit"   "${TMP}/hpcg.kv" "gflops=77.0017"
has "hpcg: extract reports HPCG's own verdict"    "${TMP}/hpcg.kv" "valid=true"
has "hpcg: extract reports the app's own timer"   "${TMP}/hpcg.kv" "app_time_s=60.0429"
has "hpcg: extract flags the unoptimised threaded kernels" \
                                                  "${TMP}/hpcg.kv" "reference_kernels=threaded"

# 'is VALID' must not match 'is INVALID' -- the space is load bearing
sed -i.bak 's/result is VALID/result is INVALID/' "${run}/HPCG-Benchmark_3.1_test.txt"
app_extract "${run}" "${TMP}/hpcg-invalid.kv"
has "hpcg: an INVALID result is not read as VALID" "${TMP}/hpcg-invalid.kv" "valid=false"

# no report at all: a missing metric, not a failure
rm -f "${run}"/HPCG-Benchmark*.txt "${run}"/*.bak
if app_extract "${run}" "${TMP}/hpcg-empty.kv" && [ ! -s "${TMP}/hpcg-empty.kv" ]; then
    ok "hpcg: no output is a missing metric, not a failed run"
else
    bad "hpcg: a missing report should succeed with no metrics"
fi

#-- osu: no prepare hook, a launch hook, output on stdout ----------------------
echo
app_resolve osu "${LAUNCH}" "${TMP}/osu" >/dev/null 2>&1
run="${TMP}/osu/run"; mkdir -p "${run}"
app_export_geometry "${run}" pureMPI 2 256 128 1

app_prepare "${run}" && ok "osu: no prepare hook is legal and accepts the cell" \
                     || bad "osu: a missing prepare hook must not decline"

# With no OSU tree present the launch hook declines, and app_argv falls back to
# `binary` from app.yaml rather than launching an empty command line.
want "osu: app_argv falls back to app.yaml when launch finds nothing" \
     "${APP_BINARY}" "$(app_argv)"

# With a tree, the hook builds the real command line.  OSU_ROOT is the knob that
# makes this checkable without a container.
fake="${TMP}/osu-tree/libexec/osu-micro-benchmarks/mpi/collective"
mkdir -p "${fake}" && : > "${fake}/osu_allreduce" && chmod +x "${fake}/osu_allreduce"
argv="$(OSU_ROOT="${TMP}/osu-tree" OSU_BENCHMARK=osu_allreduce OSU_MSG_RANGE=8:4096 app_argv)"
want "osu: launch names the requested benchmark and message range" \
     "${fake}/osu_allreduce -m 8:4096" "${argv}"

cat > "${run}/app.out" <<'OSUOUT'
# OSU MPI Alltoall Latency Test v7.5
# Size       Avg Latency(us)
4                      15.23
1048576              5023.11
OSUOUT
app_extract "${run}" "${TMP}/osu.kv"
has "osu: extract reads the largest message size"  "${TMP}/osu.kv" "msg_bytes=1048576"
has "osu: extract reports the latency there"       "${TMP}/osu.kv" "latency_us=5023.11"
has "osu: extract names the benchmark that ran"    "${TMP}/osu.kv" "benchmark=Alltoall_Latency"

: > "${run}/app.out"
app_extract "${run}" "${TMP}/osu-empty.kv"
[ ! -s "${TMP}/osu-empty.kv" ] && ok "osu: an empty table is a missing metric, not a failure" \
                               || bad "osu: empty output produced metrics"

#-- heffte: launch sizes the cube, extract judges the error against tolerance ---
echo
app_resolve heffte "${LAUNCH}" "${TMP}/heffte" >/dev/null 2>&1
run="${TMP}/heffte/run"; mkdir -p "${run}"
app_export_geometry "${run}" pureMPI 1 128 128 1
want "heffte: launch defaults to fftw at 512^3" \
     "/container/bin/speed3d_r2c fftw double 512 512 512 -n10" "$(HPCRUN_SCALE=node app_argv)"
want "heffte: a smoke cell gets a tiny cube, and the backend is a knob" \
     "/container/bin/speed3d_r2c stock double 32 32 32 -n10" \
     "$(HPCRUN_SCALE=smoke HEFFTE_BACKEND=stock app_argv)"

cat > "${run}/app.out" <<'HEFFTEOUT'
-----------------------------------------------------------------------------
heFFTe performance test
-----------------------------------------------------------------------------
Backend:   fftw
Size:      512x512x512
MPI ranks:  128
Time per run: 0.0839 (s)
Performance:  120.5 GFlops/s
Memory usage: 31MB/rank
Tolerance:    1e-11
Max error:    2.3e-15
HEFFTEOUT
app_extract "${run}" "${TMP}/heffte.kv"
has "heffte: extract reads the time per transform" "${TMP}/heffte.kv" "fft_time_s=0.0839"
has "heffte: extract reads speed3d's GFlops"      "${TMP}/heffte.kv" "gflops=120.5"
has "heffte: an error within tolerance is valid"  "${TMP}/heffte.kv" "valid=true"
sed -i 's/^Max error:.*/Max error:    3.0e-9/' "${run}/app.out"
app_extract "${run}" "${TMP}/heffte-bad.kv"
has "heffte: an error past tolerance is invalid"  "${TMP}/heffte-bad.kv" "valid=false"

want "heffte: HEFFTE_FFTW picks the FFTW build behind the driver" \
     "/container/bin/speed3d_r2c_avx512 fftw double 512 512 512 -n10" \
     "$(HPCRUN_SCALE=node HEFFTE_FFTW=avx512 app_argv)"
has "heffte: extract records which FFTW ran" "${TMP}/heffte.kv" "fftw_build=base"

#-- blas: DGEMM and DGEMV, and which kernel set actually ran ---------------------
echo
app_resolve blas "${LAUNCH}" "${TMP}/blas" >/dev/null 2>&1
run="${TMP}/blas/run"; mkdir -p "${run}"
app_export_geometry "${run}" pureMPI 1 128 128 1
want "blas: launch sizes DGEMM and DGEMV" "/container/bin/blas_probe 2048 8192 5" \
     "$(HPCRUN_SCALE=node app_argv)"
cat > "${run}/app.out" <<'BLASOUT'
blas_probe: ranks 128, dgemm order 2048, dgemv order 8192, best of 5
Core: SkylakeX
Config: OpenBLAS 0.3.30 NO_LAPACK DYNAMIC_ARCH NO_AFFINITY SkylakeX MAX_THREADS=1
DGEMM GFLOPS per rank (median): 51.200
DGEMM GFLOPS per rank (min): 49.000
DGEMM GFLOPS total: 6553.600
DGEMV GB/s per rank (median): 2.100
DGEMV GB/s total: 268.800
Valid: true
BLASOUT
OPENBLAS_CORETYPE=SkylakeX app_extract "${run}" "${TMP}/blas.kv"
has "blas: extract reads the DGEMM rate"          "${TMP}/blas.kv" "dgemm_gflops_rank=51.200"
has "blas: extract reads the DGEMV bandwidth"     "${TMP}/blas.kv" "dgemv_gbs_rank=2.100"
has "blas: extract records the core that ran"     "${TMP}/blas.kv" "core=SkylakeX"
has "blas: extract records the core asked for"    "${TMP}/blas.kv" "coretype_forced=SkylakeX"
has "blas: the probe's own check is the verdict"  "${TMP}/blas.kv" "valid=true"

#-- a bare executable is a legal, hook-free app --------------------------------
echo
unset HPCRUN_APP_DIR
if app_resolve /usr/bin/true "${LAUNCH}" "${TMP}" >/dev/null 2>&1; then
    want "a bare path needs no contract at all" "/usr/bin/true" "${APP_BINARY}"
    want "  ...and is named after its binary"   "true"          "${APP_NAME}"
    app_prepare "${TMP}" && ok "  ...and declines nothing" || bad "  ...but declined the cell"
    want "  ...and launches itself"             "/usr/bin/true" "$(app_argv)"
else
    bad "a bare executable path was rejected"
fi

echo
# Hooks inside images built before the HPCRUN_ rename read BENCH_*.
old="$( app_export_geometry /tmp/rundir ccd 2 32 16 8
        echo "${BENCH_RUNDIR}|${BENCH_RANKS}|${BENCH_THREADS}|${BENCH_PLACEMENT}" )"
want "hooks in older images still get their geometry under BENCH_ names" \
     "/tmp/rundir|32|8|ccd" "${old}"

echo "  ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
