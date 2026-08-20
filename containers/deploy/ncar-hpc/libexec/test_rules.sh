#!/bin/bash
#-------------------------------------------------------------------------------
# test_rules.sh -- assert exactly which pathology rules fire on each fixture.
#
#     ./test_rules.sh
#
# self_test.sh checks the VERDICT (clean vs bad).  This checks the DIAGNOSIS:
# for every fixture, the set of rule names that fired must equal
# fixtures/expected/<fixture>.rules, exactly.  Both directions matter --
#
#   * a missing rule is a checker that stopped detecting something;
#   * an extra rule is a false positive, which is worse, because a checker that
#     cries wolf on good runs gets ignored and then detects nothing at all.
#
# ADDING A PATHOLOGY IS THREE LINES
#
#   1. capture the bad run into fixtures/  (or derive it, see fixtures/derived/)
#   2. add one `rule` line to placement_rules.sh
#   3. add the rule's name to fixtures/expected/<fixture>.rules
#
# Every fixture must have an expectation file; a fixture without one fails,
# rather than being silently skipped.
#-------------------------------------------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/check_placement.sh" || { echo "cannot source check_placement.sh"; exit 1; }

pass=0 fail=0

check_fixture () {
    local fx="$1" name exp got
    name="$(basename "${fx}" .out)"
    exp="${HERE}/fixtures/expected/${name}.rules"

    if [ ! -f "${exp}" ]; then
        echo "  FAIL  ${name}: no expectation file (${exp#${HERE}/})"
        echo "        every fixture must declare which rules it provokes"
        fail=$((fail + 1)); return
    fi

    got="$(placement_rules_fired "${fx}" | sort)"
    want="$(grep -v '^[[:space:]]*#' "${exp}" | grep -v '^[[:space:]]*$' \
            | tr -d '[:blank:]' | sort)"

    if [ "${got}" = "${want}" ]; then
        echo "  ok    ${name}: {${got//$'\n'/, }}"
        pass=$((pass + 1))
    else
        echo "  FAIL  ${name}"
        echo "        expected: {${want//$'\n'/, }}"
        echo "        got:      {${got//$'\n'/, }}"
        placement_summary "${fx}" | sed 's/^/        /'
        fail=$((fail + 1))
    fi
}

echo "placement rule expectations"
echo
shopt -s nullglob
for fx in "${HERE}"/fixtures/*.out "${HERE}"/fixtures/derived/*.out; do
    check_fixture "${fx}"
done

echo
echo "  ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
