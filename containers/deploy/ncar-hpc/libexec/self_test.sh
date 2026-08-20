#!/bin/bash
#-------------------------------------------------------------------------------
# self_test.sh -- check that the placement checker still detects bad placement.
#
#     ./self_test.sh
#
# Runs check_placement.sh against frozen report_placement output in fixtures/,
# where the right answer is known.  Costs no node hours and needs no container,
# so run it after any edit to check_placement.sh or placement_rules.sh.
#
# The point is the NEGATIVE cases.  A checker that has quietly degraded into
# "always OK" -- easy to do, e.g. by writing the SMT rule as a tautology -- still
# looks perfect on a good run.  Only a known-bad input catches it, which is why
# fixtures/trap_*.out exist.  See fixtures/README.md.
#
# The opposite failure is just as real: a checker that reports a pathology on a
# GOOD run gets ignored, and an ignored checker detects nothing either.  The
# fixtures under derived/ that must come out clean are the guard for that.
#
# This file asserts the VERDICT.  test_rules.sh, which it runs at the end,
# asserts the DIAGNOSIS -- exactly which rules fire on each fixture.
#-------------------------------------------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/check_placement.sh" || { echo "cannot source check_placement.sh"; exit 1; }

pass=0 fail=0

# expect <ok|warn|fail> <fixture-path-relative-to-fixtures> <description>
expect () {
    local want="$1" fx="${HERE}/fixtures/$2" desc="$3" got

    if [ ! -f "${fx}" ]; then
        echo "  FAIL  ${desc}"
        echo "        missing fixture: ${fx}"
        fail=$((fail + 1))
        return
    fi

    got="$(placement_verdict "${fx}")"

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

# says <fixture> <text> <description> -- the summary must name the pathology,
# not merely report that there was one.
says () {
    if placement_summary "${HERE}/fixtures/$1" | grep -q "$2"; then
        echo "  ok    $3"
        pass=$((pass + 1))
    else
        echo "  FAIL  $3"
        fail=$((fail + 1))
    fi
}

echo "placement checker self-test"
echo

expect ok   bound_mpich.out           "good binding is accepted"
expect fail trap_mpich.out            "PALS pile-up detected (16 threads on one core)"
expect fail trap_openmpi.out          "Open MPI rank overlap detected (8 threads/core)"
expect ok   derived/perthread_mpich.out \
                                      "OMP_PLACES=threads run is NOT flagged (the intent is an input)"
expect ok   derived/smt256_mpich.out  "256 threads on 128 cores is not oversubscription (it was asked for)"

# The two traps must be distinguishable, not merely both "fail": the whole value
# of the summary is naming WHICH pathology.
echo
says trap_mpich.out   "single SMT sibling" "PALS trap is reported as single-sibling pinning"
says trap_openmpi.out "oversubscription"   "Open MPI trap is reported as oversubscription"

echo
echo "  ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ] || exit 1

echo
exec "${HERE}/test_rules.sh"
