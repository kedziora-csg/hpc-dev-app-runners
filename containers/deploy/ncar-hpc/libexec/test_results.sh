#!/bin/bash
#-------------------------------------------------------------------------------
# test_results.sh -- assert that results.sh emits valid, correctly-typed JSON.
#
#     ./test_results.sh
#
# Worth testing because the failure mode is silent.  A record assembled by
# string concatenation can lose a brace, double a comma, or quote a number, and
# nothing notices until bench/collect is pointed at three hours of node time and
# refuses to parse it.  Every case here is one line of shell and one assertion.
#
# Needs python3 only as a JSON parser -- the library under test is pure shell.
#-------------------------------------------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/results.sh" || { echo "cannot source results.sh"; exit 1; }

command -v python3 >/dev/null 2>&1 \
    || { echo "  SKIP  python3 not available to validate JSON"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
pass=0 fail=0

# assert_json <description> <python expression over `r`>
#   `r` is the single record most recently emitted.
assert_json () {
    local desc="$1" expr="$2" out
    out="$(python3 -c '
import json, sys
r = json.load(open(sys.argv[1]))
expr = sys.argv[2]
print("PASS" if eval(expr) else "FAIL: " + expr + "  in  " + json.dumps(r))
' "${TMP}/one.json" "${expr}" 2>&1)"
    if [ "${out}" = PASS ]; then
        echo "  ok    ${desc}"; pass=$((pass + 1))
    else
        echo "  FAIL  ${desc}"; echo "        ${out}"; fail=$((fail + 1))
    fi
}

# emit the current record, parse it, leave it in ${TMP}/one.json
emit () {
    rm -f "${TMP}/r.jsonl"
    result_emit "${TMP}/r.jsonl" >/dev/null
    if [ "$(wc -l < "${TMP}/r.jsonl")" -ne 1 ]; then
        echo "  FAIL  record is not exactly one line"; fail=$((fail + 1)); return 1
    fi
    if ! python3 -c 'import json,sys; json.dump(json.loads(open(sys.argv[1]).read()), open(sys.argv[2],"w"))' \
            "${TMP}/r.jsonl" "${TMP}/one.json" 2>/dev/null; then
        echo "  FAIL  record is not valid JSON:"; sed 's/^/        /' "${TMP}/r.jsonl"
        fail=$((fail + 1)); return 1
    fi
    return 0
}

echo "results record"
echo

#-- a full record, the shape plan section 7 specifies --------------------------
result_reset
result_set site derecho
result_set job_id 7024910.desched1
result_set nodes "   2   "
result_str image.sif leap-oneapi-mpich-hpcg.sif
result_set image.digest "sha256:829ae6105951451d1fbac8bcfec993c94c35855f4b79cfea287513a51d54e604"
result_set image.compiler oneapi
result_set image.mpi mpich
result_set app.name hpcg
result_str app.version 3.1
result_set placement.name ccd
result_set placement.ranks_per_node 16
result_set placement.threads 8
result_str placement.mpiexec_flags "-ppn 16 --cpu-bind core -d 8"
result_set placement.verdict ok
result_set placement.omp.OMP_PROC_BIND close
result_set placement.omp.OMP_PLACES cores
result_set repeat 1
result_set wall_s 71.42
result_set exit 0
result_set valid true
result_set warm true
result_metric gflops 12.83
emit && {
    assert_json "schema and timestamp are added"      'r["schema"] == 1 and "timestamp" in r'
    assert_json "a padded count is still a number, not a string" \
                'r["nodes"] == 2 and not isinstance(r["nodes"], str)'
    assert_json "wall_s keeps its fraction"           'abs(r["wall_s"] - 71.42) < 1e-9'
    assert_json "exit 0 stays a number"               'r["exit"] == 0 and not isinstance(r["exit"], bool)'
    assert_json "valid is a bool, not the string"     'r["valid"] is True'
    assert_json "a digest is a string, not a number"  'r["image"]["digest"].startswith("sha256:")'
    assert_json "a version stays a string, so 3.1 and 3.1.0 type alike" \
                'r["app"]["version"] == "3.1"'
    assert_json "mpiexec flags survive verbatim"      'r["placement"]["mpiexec_flags"] == "-ppn 16 --cpu-bind core -d 8"'
    assert_json "omp settings nest under placement"   'r["placement"]["omp"]["OMP_PLACES"] == "cores"'
    assert_json "rules is an array even when empty"   'r["placement"]["rules"] == []'
    assert_json "metrics carry the figure of merit"   'r["metrics"]["gflops"] == 12.83'
}

#-- an unknown digest is null, not an empty string ----------------------------
result_reset
result_set image.sif old.sif
result_set image.digest ""
emit && assert_json "an unstamped SIF records digest null" 'r["image"]["digest"] is None'

#-- fired rules ---------------------------------------------------------------
result_reset
result_set placement.verdict fail
result_rule oversubscription
result_rule partial_core
emit && assert_json "fired rules land in the array" \
    'r["placement"]["rules"] == ["oversubscription", "partial_core"]'

#-- the app-contract stream (phase 2 feeds extract's output straight into this)-
result_reset
printf 'gflops=12.83\nvalid=false\niterations=51\nnot a kv line\nbad key!=1\n' \
    > "${TMP}/extract.out"
result_metrics_from_file "${TMP}/extract.out"
emit && {
    assert_json "extract key=value becomes metrics"   'r["metrics"]["gflops"] == 12.83'
    assert_json "extract iterations stays an int"     'r["metrics"]["iterations"] == 51'
    assert_json "valid is lifted out of metrics"      'r["valid"] is False and "valid" not in r.get("metrics", {})'
    assert_json "unparseable extract lines are dropped, not recorded broken" \
                'set(r["metrics"]) == {"gflops", "iterations"}'
}

#-- quoting hostile input ------------------------------------------------------
result_reset
result_str placement.mpiexec_flags '--opt "quoted" and \back\slash'
emit && assert_json "quotes and backslashes survive a round trip" \
    'r["placement"]["mpiexec_flags"] == "--opt \"quoted\" and \\back\\slash"'

#-- an empty record is still valid JSON ---------------------------------------
result_reset
emit && assert_json "an empty record is still a valid object" 'set(r) == {"schema", "timestamp"}'

#-- the writer and the reader must agree ---------------------------------------
# The one seam nothing else covers: results.sh is shell, bench/collect is
# Python, and they only meet on disk.  Emit a small matrix and require collect
# to read every row, pick the right winner, and exclude the right rows.
COLLECT="${HERE}/../../bench/collect"
if [ -x "${COLLECT}" ]; then
    mkdir -p "${TMP}/results/leap-oneapi-mpich" "${TMP}/results/leap-gcc14-openmpi"

    row () {   # row <dir> <placement> <ppn> <thr> <wall> <exit> <gflops> <verdict> [valid]
        result_reset
        result_set site derecho
        result_set nodes 2
        result_str image.sif "$(basename "$1").sif"
        result_set app.name hpcg
        result_str placement.name "$2"
        result_set placement.ranks_per_node "$3"
        result_set placement.threads "$4"
        result_set placement.verdict "$8"
        [ "$8" = fail ] && result_rule oversubscription
        result_set wall_s "$5"
        result_set exit "$6"
        result_set warm true
        result_set valid "${9:-true}"
        result_metric gflops "$7"
        result_emit "${TMP}/results/$1/results.jsonl" >/dev/null
    }

    row leap-oneapi-mpich   ccd     16 8  71.40 0 12.83 ok
    row leap-oneapi-mpich   numa     8 16 88.10 0 11.02 warn
    row leap-oneapi-mpich   pureMPI 128 1 240.0 0 99.99 fail        # fastest, must not win
    row leap-gcc14-openmpi  ccd     16 8  74.20 0 12.40 ok
    row leap-gcc14-openmpi  numa     8 16 60.00 0 50.00 ok false    # invalid, must not win

    out="$(python3 "${COLLECT}" "${TMP}/results" --best 2>&1)"
    check () {
        if printf '%s' "${out}" | grep -q "$1"; then
            echo "  ok    $2"; pass=$((pass + 1))
        else
            echo "  FAIL  $2"; printf '%s\n' "${out}" | sed 's/^/        /'; fail=$((fail + 1))
        fi
    }
    check '12.83'                      "collect reads rows written by results.sh"
    check 'best *gflops *ccd'          "best gflops is the ccd cell, not the mis-bound 99.99"
    check 'placement fail'             "the mis-bound row is excluded, with its rule named"
    check 'app reported invalid'       "the app's own valid=false excludes its row"

    if printf '%s' "${out}" | grep -q 'best *wall_s *numa *leap-gcc14'; then
        echo "  FAIL  an invalid row won on wall time"; fail=$((fail + 1))
    else
        echo "  ok    an invalid row cannot win on wall time either"; pass=$((pass + 1))
    fi

    if python3 "${COLLECT}" "${TMP}/results" --format csv >/dev/null 2>&1; then
        echo "  ok    csv output renders"; pass=$((pass + 1))
    else
        echo "  FAIL  csv output failed"; fail=$((fail + 1))
    fi

    # A job killed at walltime leaves a partial final line.  That is one lost
    # cell, not a lost file.
    printf '{"schema":1,"wall_s":1' >> "${TMP}/results/leap-oneapi-mpich/results.jsonl"
    if python3 "${COLLECT}" "${TMP}/results" >/dev/null 2>"${TMP}/err"; then
        echo "  ok    a truncated final row is skipped, not fatal"; pass=$((pass + 1))
    else
        echo "  FAIL  a truncated final row broke collect"; fail=$((fail + 1))
    fi
else
    echo "  SKIP  bench/collect not found at ${COLLECT}"
fi

echo
echo "  ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
