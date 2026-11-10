#!/bin/bash
#-------------------------------------------------------------------------------
# apps/smoke.sh <app> [ranks] [threads] -- one tiny run of <app>, through its
# contract, inside the image that carries it.
#
#     docker run --rm -v "$PWD:/src:ro" <app image> /src/apps/smoke.sh hpcg
#     apptainer exec --cleanenv --bind "$PWD:/src" <image.sif> bash -lc '/src/apps/smoke.sh osu'
#
# The same hooks a cluster job calls, driven by the same library: hpcrun's
# app_contract.sh resolves /container/app.d/<app>, runs prepare, asks launch for
# the argv, runs it under the image's own mpiexec, and hands the output to
# extract.  So a broken extractor fails in CI, in seconds, rather than three
# hours into a queued job.  HPCRUN_SCALE=smoke is the contract's way of asking
# for a problem that small.
#
# Passes when the run exits 0, extract prints the app's primary_fom, and the app
# does not judge its own result invalid.  Nothing here names an app.  Three
# things a host may lack are its limit and not the image's fault, so the run is
# skipped, said so, and exits 0, after the contract is resolved and its prepare
# and launch hooks have run:
#     run skipped: host has no GPU                 requires.gpu, and no GPU here
#     run skipped: host software ... not here      requires.host_software
#     run skipped: host lacks the target's ISA     an AVX-512 build, say
#-------------------------------------------------------------------------------
set -u
app="${1:?usage: smoke.sh <app> [ranks] [threads]}"
ranks="${2:-2}"
threads="${3:-1}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="${here}/../hpcrun/lib"
. "${lib}/probe_topology.sh" || { echo "smoke: cannot source probe_topology.sh"; exit 1; }
. "${lib}/app_contract.sh"   || { echo "smoke: cannot source app_contract.sh"; exit 1; }

fail () { echo "smoke: ${app}: $*"; exit 1; }

out="$(mktemp -d)"
run="${out}/run"
mkdir -p "${run}"

# `command` is the launcher: the hooks already run inside the image, so there is
# no container to enter, and `command cat ...` is exactly `cat ...`.
app_resolve "${app}" command "${out}" || fail "no usable contract"
echo "contract  ${APP_DIR} (${APP_NAME} ${APP_VERSION:-unversioned})"

probe_topology "${out}/topology.json" >/dev/null 2>&1 || true
load_topology "${out}/topology.json"

export HPCRUN_SCALE=smoke HPCRUN_TARGET_SECONDS=5 OMP_NUM_THREADS="${threads}"
app_export_geometry "${run}" smoke 1 "${ranks}" "${ranks}" "${threads}"

# What the contract requires of the host.  The requires: block is nested, which
# the job never reads (app_contract.sh); this is a test tool, and the two keys
# it needs are a scalar and a list of names, in block style or flow style
# (`requires: {gpu: cuda, host_software: [bench]}`).
requires () {
    awk -v key="$1" '
        function emit(v) { gsub(/[][,"\047]/, " ", v); printf "%s ", v }
        # Flow style: split the braces at top-level commas, and take key: value.
        /^requires:[[:space:]]*\{/ {
            body = $0; sub(/^requires:[[:space:]]*\{/, "", body)
            sub(/[[:space:]]+#.*/, "", body); sub(/\}[[:space:]]*$/, "", body)
            depth = 0; item = ""
            for (i = 1; i <= length(body) + 1; i++) {
                c = (i <= length(body)) ? substr(body, i, 1) : ","
                if (c == "[") depth++
                if (c == "]") depth--
                if (c == "," && depth == 0) {
                    k = item; sub(/:.*/, "", k); gsub(/[[:space:]]/, "", k)
                    if (k == key) { v = item; sub(/^[^:]*:/, "", v); emit(v) }
                    item = ""
                } else item = item c
            }
            exit
        }
        /^requires:/ { inside = 1; next }
        inside && /^[^[:space:]#]/ { inside = 0 }
        !inside { next }
        list && /^[[:space:]]+-[[:space:]]/ { sub(/^[[:space:]]+-[[:space:]]*/, ""); sub(/[[:space:]]+#.*/, ""); printf "%s ", $0; next }
        { list = 0 }
        $1 == key ":" {
            sub(/^[^:]*:[[:space:]]*/, ""); sub(/[[:space:]]+#.*/, "")
            if ($0 == "") { list = 1; next }
            emit($0)
        }' "${out}/app.yaml" | tr -s ' ' | sed 's/^ //; s/ $//'
}

# Whether this host has what the contract needs, found out BEFORE the hooks
# run: a prepare hook may decline without a GPU's memory to size from, or a
# launch hook find no binary, and either would otherwise fail the image where
# the honest answer is that this host cannot run it.  The hooks still run; it
# is their failure that becomes a skip.
need_gpu="$(requires gpu)"
need_sw="$(requires host_software)"
missing=""
if [ -n "${need_gpu}" ]; then
    if [ -x /container/bin/report_gpus ] && /container/bin/report_gpus > "${out}/gpus.txt" 2>&1; then
        grep -m1 -i 'device\|gpu' "${out}/gpus.txt" | sed 's/^/gpu       /'
    else
        missing="host has no GPU (requires.gpu: ${need_gpu})"
    fi
fi
if [ -z "${missing}" ] && [ -n "${need_sw}" ] && [ -n "${APP_BINARY:-}" ] && [ ! -x "${APP_BINARY}" ]; then
    missing="host software ${need_sw} is not here (${APP_BINARY} comes from the site's install, never the image)"
fi
skip () {
    echo "smoke: ${app}: run skipped: ${missing}${1:+ -- $1}"
    rm -rf "${out}"
    exit 0
}

if ! app_prepare "${run}"; then
    cat "${run}/prepare.log" 2>/dev/null
    [ -z "${missing}" ] || skip "prepare declined, as it may without it"
    fail "prepare declined a ${ranks}x${threads} smoke cell"
fi

argv="$(app_argv)"
if [ -z "${argv}" ]; then
    [ -z "${missing}" ] || skip "launch gave no argv, as it may without it"
    fail "neither launch nor binary gave an argv"
fi
[ -z "${missing}" ] || skip

# An image built for a node type's target (znver4, cascadelake) can need AVX-512
# that the host running this -- a CI runner, often a Zen 3 -- lacks.  The run
# would die with SIGILL, which says nothing about the image, so the run is
# skipped and said so; the contract above has still been resolved and its
# prepare and launch hooks run.  The cluster job's own arch_check is the same
# test, on the node the image was built for.
if [ -n "${APP_BINARY:-}" ]; then
    . "${lib}/check_arch.sh" || fail "cannot source check_arch.sh"
    if ! HPCRUN_ALLOW_ARCH_MISMATCH=0 HPCRUN_TARGET_ARCH= \
            arch_check command "${APP_BINARY}" "${out}/cpu_features.txt" > "${out}/arch.txt"; then
        grep '^cpu ' "${out}/arch.txt"
        echo "smoke: ${app}: run skipped: host lacks the target's ISA" \
             "(${APP_BINARY} requires what this CPU does not have)"
        rm -rf "${out}"
        exit 0
    fi
    grep -E '^(cpu|note) ' "${out}/arch.txt"
fi

# A CI runner has fewer cores than ranks sometimes; Open MPI refuses that unless
# told, MPICH does not care.
case "${MPI_FAMILY:-}" in
    openmpi*) mpiflags="--map-by :OVERSUBSCRIBE" ;;
    mpich*)   export MPIR_CVAR_ENABLE_GPU=0; mpiflags="" ;;
    *)        mpiflags="" ;;
esac

echo "run       mpiexec -n ${ranks} ${mpiflags} ${argv}   (OMP_NUM_THREADS=${threads})"
( cd "${run}" && mpiexec -n "${ranks}" ${mpiflags} ${argv} > app.out 2>&1 ) \
    || { tail -40 "${run}/app.out"; fail "the run exited non-zero"; }

app_extract "${run}" "${run}/metrics.kv"
echo "extract:"
sed 's/^/    /' "${run}/metrics.kv"

fom="$(_yaml_scalar "${out}/app.yaml" primary_fom)"
if [ -n "${fom}" ]; then
    grep -q "^${fom}=" "${run}/metrics.kv" \
        || { tail -40 "${run}/app.out"; fail "extract printed no ${fom}, the primary figure of merit"; }
fi
grep -q '^valid=false$' "${run}/metrics.kv" && fail "the app judged its own result invalid"

echo "smoke: ${app}: ok"
rm -rf "${out}"
exit 0
