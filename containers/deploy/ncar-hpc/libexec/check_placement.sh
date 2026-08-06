#!/bin/bash
#-------------------------------------------------------------------------------
# check_placement.sh -- validate a report_placement run against what was asked
# for, so that a benchmark timing is never silently measuring a bad binding.
#
# USAGE
#     source check_placement.sh
#     check_placement <report_file> <expected_L3_groups_per_rank>
#
#     check_placement_rc <report_file> <expected_L3_groups_per_rank>
#         same checks, silent, returns 0 (OK) or 1 (not as intended) so callers
#         can build a PASS/FAIL matrix.
#
# It answers three questions, and all three are needed:
#
#   1. Is every thread pinned to exactly one core?   (nallowed == 1)
#   2. Does any core carry more than one thread?     (oversubscription)
#   3. How many L3 groups does each rank span?       (chiplet straddling)
#
# Why all three: the classic Derecho trap -- omitting --cpu-bind entirely -- pins
# each RANK to one core, so all its OpenMP threads pile onto that single core.
# There, nallowed IS 1, so check (1) passes; only check (2) catches it, via
# doubled-cores.  Conversely a rank spread across chiplets passes (1) and (2)
# and is only visible to (3).
#
# Expected L3 groups per rank depends on the layout, and a value > 1 is not
# automatically wrong:
#   16 ranks x  8 threads -> 1   (a rank fits one CCD; Milan has 8 cores per L3)
#    8 ranks x 16 threads -> 2   (a rank necessarily straddles two CCDs)
#  128 ranks x  1 thread  -> 1
#-------------------------------------------------------------------------------

_check_placement_awk () {
    local f="$1" want_l3="$2" quiet="$3"
    grep '^MPI rank' "$f" 2>/dev/null | awk -v want="${want_l3}" -v quiet="${quiet}" '
    {
        split($3, r, "/"); rank = r[1]
        for (i = 1; i <= NF; i++) {
            if ($i == "host")     h  = $(i+1)
            if ($i == "cpu")      c  = $(i+1)
            if ($i == "l3")       l3 = $(i+1)
            if ($i == "nallowed") n  = $(i+1)
        }
        rows++
        if (n != 1) unpinned++
        key = h "_" c; seen[key]++; if (seen[key] == 2) doubled++
        grp[rank "|" l3] = 1
    }
    END {
        for (k in grp) { split(k, a, "|"); per[a[1]]++ }
        worst = 0; for (k in per) if (per[k] > worst) worst = per[k]
        bad = (rows == 0) || (unpinned+0 > 0) || (doubled+0 > 0) || (worst != want+0)
        if (quiet != "1") {
            if (rows == 0) {
                printf "    no MPI rank rows found -- did the run produce output?\n"
            } else {
                printf "    rows=%d  unpinned=%d  doubled-cores=%d  max L3/rank=%d (want %s)\n",
                       rows, unpinned+0, doubled+0, worst, want
                printf "    %s\n", bad ? "*** PLACEMENT NOT AS INTENDED ***" : "placement OK"
            }
        }
        exit bad ? 1 : 0
    }'
}

check_placement () {
    _check_placement_awk "$1" "$2" 0
}

check_placement_rc () {
    _check_placement_awk "$1" "$2" 1 >/dev/null 2>&1
}
