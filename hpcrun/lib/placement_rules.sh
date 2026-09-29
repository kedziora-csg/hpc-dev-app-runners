#!/bin/bash
#-------------------------------------------------------------------------------
# placement_rules.sh -- the pathology rule table.
#
# Separated from check_placement.sh on purpose: that file MEASURES (an awk pass
# that emits facts and decides nothing), this one JUDGES.  Adding a pathology is
# a single line here plus a fixture expectation -- keep it that way.
#
# DECLARING A RULE
#
#     rule <name> <severity> '<condition>' '<printf format>' [fact ...]
#
#     name        stable identifier; it is what fixtures/expected/*.rules assert
#                 on and what a results record will carry, so do not rename one
#                 casually
#     severity    warn | fail
#     condition   a bash arithmetic expression over the facts, e.g.
#                 '(( max_l3 > min_l3 ))'.  Evaluated only after the facts exist.
#     format      printf format for the human message
#     fact...     names of facts substituted into the format, in order
#
# WHAT THE SEVERITIES MEAN TO A CALLER
#
#     (none fires)  compare this run against the others
#     warn          print it, record it, still compare -- the placement is
#                   suboptimal but it is the placement that was measured
#     fail          print it, record it, and NEVER let this row win a
#                   comparison: a mis-bound run measures the binding, not the
#                   code
#
# EVERY THRESHOLD IS DERIVED, NONE IS A CONSTANT
#
# want_occ, want_smt, min_l3, min_numa and min_sock all come from the probed
# topology (probe_topology.sh) crossed with what the run actually asked for
# (OMP_PLACES, the rank/thread geometry).  A new rule must derive its threshold
# the same way: a constant here is a claim about hardware and about an intent,
# and it will be wrong about the first configuration nobody anticipated.
#-------------------------------------------------------------------------------

placement_rules () {

    #     name             sev   condition                        message
    rule oversubscription  fail  '(( worst_occ > want_occ ))' \
        '%d core(s) carry more threads than the geometry needs (worst %d on one core, %d intended)' \
        oversub_cores worst_occ want_occ

    rule unpinned          fail  '(( roam > 0 ))' \
        '%d thread(s) not pinned -- free to migrate across cores' \
        roam

    rule split_mask        fail  '(( splitcore > 0 ))' \
        '%d thread(s) masked across two or more different cores' \
        splitcore

    rule partial_core      warn  '(( single > 0 ))' \
        '%d thread(s) pinned to a single SMT sibling, not a whole core (OMP_PLACES=%s asked for %d CPU(s)/thread)' \
        single places want_smt

    rule wide_mask         warn  '(( wide > 0 ))' \
        '%d thread(s) hold a whole core where OMP_PLACES=%s asked for %d CPU(s)' \
        wide places want_smt

    rule l3_straddle       warn  '(( max_l3 > min_l3 ))' \
        'chiplet straddling: a rank spans %d L3 group(s); %d would do for %d core(s)' \
        max_l3 min_l3 max_core

    rule numa_straddle     warn  '(( max_numa > min_numa ))' \
        'a rank spans %d NUMA domain(s); %d would do for %d core(s)' \
        max_numa min_numa max_core

    rule socket_straddle   fail  '(( max_sock > min_sock ))' \
        'a rank spans %d socket(s); %d would do for %d core(s)' \
        max_sock min_sock max_core
}
