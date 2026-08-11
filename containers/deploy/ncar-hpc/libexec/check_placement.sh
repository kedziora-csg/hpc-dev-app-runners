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
# It answers four questions, and all four are needed:
#
#   1. Is every thread pinned to exactly one CORE?   (nallowed == 2, see SMT)
#   2. Is that mask really one core's two siblings?  (affinity == c,c+128)
#   3. Does any core carry more than one thread?     (oversubscription)
#   4. How many L3 groups does each rank span?       (chiplet straddling)
#
# Why all four: the classic Derecho trap -- omitting --cpu-bind entirely -- pins
# each RANK to one core, so all its OpenMP threads pile onto that single core.
# Checks (1) and (2) can still pass there; only (3) catches it, via
# doubled-cores.  Conversely a rank spread across chiplets passes (1)-(3)
# and is only visible to (4).
#
#-------------------------------------------------------------------------------
# SMT ON DERECHO -- why "pinned" means nallowed == 2, not 1
#-------------------------------------------------------------------------------
# Derecho's Milan nodes run with SMT enabled: 128 physical cores presented as 256
# CPUs, enumerated as all 128 first siblings (0-127) then all 128 second siblings
# (128-255), so the sibling of core c is CPU c+128.
#
# With OMP_PLACES=cores, a correctly-pinned thread therefore has TWO allowed
# CPUs -- both siblings of its own core -- and nallowed is 2.  Demanding
# nallowed == 1 (a single hardware thread) would fail every correct run.
#
# Both launch dialects now request core granularity and agree exactly:
#     Cray PALS  -ppn 8 --cpu-bind core -d 16
#     Open MPI   --map-by ppr:8:node:pe=16 --bind-to core
# nallowed == 2 alone is necessary but not sufficient -- two allowed CPUs on two
# DIFFERENT cores would also score 2 -- hence check (2) against the affinity
# list, which pins down that the pair is one core's own siblings.
#
#-------------------------------------------------------------------------------
# Why oversubscription is keyed on the CORE column, not the CPU column
#-------------------------------------------------------------------------------
# report_placement's `cpu` field is a sched_getcpu() SAMPLE: the CPU the thread
# happened to occupy at the instant it printed.  Under SMT that is either sibling
# of its core, and it genuinely varies run to run -- the same rank-0/thread-0,
# under the same binding, reported `cpu 128` in one image's run and `cpu 0` in
# another's.  Keying oversubscription on `cpu` therefore both misses real
# contention (two threads on one core sampled as 0 and 128 look like two distinct
# CPUs) and reports a count that changes between identical runs.  The `core`
# column is the stable physical identity, so that is what we count.
#
# Expected L3 groups per rank depends on the layout, and a value > 1 is not
# automatically wrong:
#   16 ranks x  8 threads -> 1   (a rank fits one CCD; Milan has 8 cores per L3)
#    8 ranks x 16 threads -> 2   (a rank necessarily straddles two CCDs)
#  128 ranks x  1 thread  -> 1
#-------------------------------------------------------------------------------

# Derecho constants (see the SMT block above).  Deliberately fixed rather than
# probed: this harness only ever runs on Derecho, where SMT is always on.
SMT_SIBLING_STRIDE=128   # sibling of core c is CPU c+SMT_SIBLING_STRIDE
SMT_CPUS_PER_CORE=2      # ...so a core-pinned thread has this many allowed CPUs

_check_placement_awk () {
    local f="$1" want_l3="$2" quiet="$3"
    grep '^MPI rank' "$f" 2>/dev/null | awk -v want="${want_l3}" -v quiet="${quiet}" \
        -v stride="${SMT_SIBLING_STRIDE}" -v percore="${SMT_CPUS_PER_CORE}" '
    {
        split($3, r, "/"); rank = r[1]
        for (i = 1; i <= NF; i++) {
            if ($i == "host")     h  = $(i+1)
            if ($i == "core")     c  = $(i+1)
            if ($i == "l3")       l3 = $(i+1)
            if ($i == "nallowed") n  = $(i+1)
            if ($i == "affinity") aff = $(i+1)
        }
        rows++
        if (n+0 != percore+0) unpinned++
        if (aff != c "," (c + stride)) strays++
        key = h "_" c; seen[key]++; if (seen[key] == 2) doubled++
        grp[rank "|" l3] = 1
    }
    END {
        for (k in grp) { split(k, a, "|"); per[a[1]]++ }
        worst = 0; for (k in per) if (per[k] > worst) worst = per[k]
        bad = (rows == 0) || (unpinned+0 > 0) || (strays+0 > 0) \
              || (doubled+0 > 0) || (worst != want+0)
        if (quiet != "1") {
            if (rows == 0) {
                printf "    no MPI rank rows found -- did the run produce output?\n"
            } else {
                printf "    rows=%d  unpinned=%d  stray-mask=%d  doubled-cores=%d  max L3/rank=%d (want %s)\n",
                       rows, unpinned+0, strays+0, doubled+0, worst, want
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
