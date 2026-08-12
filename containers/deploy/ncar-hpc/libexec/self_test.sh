#!/bin/bash
#-------------------------------------------------------------------------------
# self_test.sh -- check that the placement checker still detects bad placement.
#
# Runs check_placement.sh against frozen report_placement output in fixtures/,
# where the right answer is known.  Costs no node hours and needs no container,
# so run it after any edit to check_placement.sh:
#
#     ./self_test.sh
#
# The point is the NEGATIVE cases.  A checker that has quietly degraded into
# "always OK" -- easy to do, e.g. by writing the SMT nallowed rule as a
# tautology -- still looks perfect on a good run.  Only a known-bad input
# catches it, which is why fixtures/trap_*.out exist.  See fixtures/README.md.
#-------------------------------------------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/check_placement.sh" || { echo "cannot source check_placement.sh"; exit 1; }

pass=0 fail=0

# expect <want:clean|bad> <fixture> <description>
expect () {
    local want="$1" fx="${HERE}/fixtures/$2" desc="$3" got rc

    if [ ! -f "${fx}" ]; then
        echo "  FAIL  ${desc}"
        echo "        missing fixture: ${fx}"
        fail=$((fail + 1))
        return
    fi

    placement_summary_rc "${fx}" && rc=0 || rc=1
    [ "${rc}" -eq 0 ] && got=clean || got=bad

    if [ "${got}" = "${want}" ]; then
        echo "  ok    ${desc}  (${got})"
        pass=$((pass + 1))
    else
        echo "  FAIL  ${desc}"
        echo "        expected ${want}, got ${got}:"
        placement_summary "${fx}" | sed 's/^/        /'
        fail=$((fail + 1))
    fi
}

echo "placement checker self-test"
echo

expect clean bound_mpich.out  "good binding is accepted"
expect bad   trap_mpich.out   "PALS pile-up detected (16 threads on one core)"
expect bad   trap_openmpi.out "Open MPI rank overlap detected (8 threads/core)"

# The two traps must be distinguishable, not merely both "bad": the whole value
# of the summary is naming WHICH pathology, so assert on the text as well.
echo
if placement_summary "${HERE}/fixtures/trap_mpich.out" \
     | grep -q "single SMT sibling"; then
    echo "  ok    PALS trap is reported as single-sibling pinning"
    pass=$((pass + 1))
else
    echo "  FAIL  PALS trap lost its single-sibling diagnosis"
    fail=$((fail + 1))
fi

if placement_summary "${HERE}/fixtures/trap_openmpi.out" \
     | grep -q "oversubscription"; then
    echo "  ok    Open MPI trap is reported as oversubscription"
    pass=$((pass + 1))
else
    echo "  FAIL  Open MPI trap lost its oversubscription diagnosis"
    fail=$((fail + 1))
fi

echo
echo "  ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
