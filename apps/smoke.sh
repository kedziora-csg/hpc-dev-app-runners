#!/bin/bash
#-------------------------------------------------------------------------------
# apps/smoke.sh <app> [ranks] [threads] -- one tiny run of <app>, through its
# contract, inside the image that carries it.
#
#     docker run --rm -v "$PWD:/src:ro" <app image> bash -lc '/src/apps/smoke.sh hpcg'
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
# does not judge its own result invalid.  Nothing here names an app.
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

app_prepare "${run}" || { cat "${run}/prepare.log" 2>/dev/null; fail "prepare declined a ${ranks}x${threads} smoke cell"; }

argv="$(app_argv)"
[ -n "${argv}" ] || fail "neither launch nor binary gave an argv"

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
