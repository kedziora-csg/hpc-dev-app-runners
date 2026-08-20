#!/bin/bash
#-------------------------------------------------------------------------------
# check_placement.sh -- decide whether a report_placement run is measuring the
# code or measuring a bad binding.
#
# USAGE
#     . check_placement.sh
#
#     placement_summary    <report>   print the verdict; 0 clean, 1 warn, 2 fail,
#                                     3 unusable input
#     placement_summary_rc <report>   silent; 0 unless a `fail` rule fired, i.e.
#                                     "is this row comparable against the others?"
#     placement_verdict    <report>   print one of: ok | warn | fail | nodata
#     placement_facts      <report>   print the raw `key=value` fact block
#     placement_rules_fired <report>  print the names of the rules that fired
#
# HOW IT IS PUT TOGETHER
#
#     probe_topology.sh   what the machine is        (probed, not hardcoded)
#     check_placement.sh  what the run got           (awk: facts, no judgment)
#     placement_rules.sh  what counts as pathology   (one line per rule)
#
# Keep the split: awk emits a flat `key=value` block and decides nothing, bash
# evaluates a rule table over it.  Adding a pathology is then one line in
# placement_rules.sh and one line in a fixture expectation, not surgery on awk.
#
#-------------------------------------------------------------------------------
# THE RULES ARE TOLD THE INTENT
#-------------------------------------------------------------------------------
# Toggling OMP_PLACES between `cores` and `threads` is a deliberate experiment:
# it asks whether SMT siblings should take part in the threaded computation.  The
# mask a CORRECT run produces differs between the two, so a checker that assumes
# one of them can only ever check that one, and reports every run under the other
# as broken.
#
# The intent is therefore an input, and it comes from the report itself: the
# `# env` line report_placement writes records the OMP_PLACES the process
# actually had.  Each .out is self-judging, so a report captured on Derecho is
# judged the same way wherever the checker runs.
#
#     OMP_PLACES=cores     -> a thread should own a whole core   (smt CPUs)
#     OMP_PLACES=threads   -> a thread should own one logical CPU (1 CPU)
#     anything else        -> mask SHAPE is not judged; occupancy and straddling
#                             still are
#
#-------------------------------------------------------------------------------
# WHY OVERSUBSCRIPTION IS KEYED ON THE CORE COLUMN, NOT THE CPU COLUMN
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
# How many threads per core is intended is likewise derived, not assumed: it is
# ceil(threads-on-this-node / cores-on-this-node).  128 threads on 128 cores
# means 1; a deliberate 256-thread run that engages both SMT siblings means 2,
# and does not get flagged for it.
#
#-------------------------------------------------------------------------------
# WHY THE `csv:` ROWS AND NOT THE HUMAN LINES
#-------------------------------------------------------------------------------
# report_placement emits both.  The `csv:` rows are the stable machine interface
# it advertises; the prose `MPI rank ...` lines are for people, and parsing them
# positionally makes any change to the human format a silent break.  Parse the
# csv rows.
#
# The affinity column is a sysfs-style RANGE LIST -- `0-3,64`, not just `0,128`
# -- so expand it before judging it.  Comparing the string against a literal
# "c,c+stride" recognises exactly one mask shape and catches everything else, if
# at all, by accident.
#-------------------------------------------------------------------------------

_CHKPL_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${_CHKPL_HERE}/probe_topology.sh"  || return 1 2>/dev/null || exit 1
. "${_CHKPL_HERE}/placement_rules.sh" || return 1 2>/dev/null || exit 1

#-------------------------------------------------------------------------------
# What OMP_PLACES the run actually had.  `# env` is report_placement's own record
# of the process environment; `# omp` is the header run_placement writes ahead of
# the launch.  Prefer the observed one.
#-------------------------------------------------------------------------------
_placement_places () {
    local f="$1" p=""
    p="$(grep -m1 '^# env '  "${f}" 2>/dev/null | sed -n 's/.*OMP_PLACES=\([^ ]*\).*/\1/p')"
    [ -n "${p}" ] || \
    p="$(grep -m1 '^# omp '  "${f}" 2>/dev/null | sed -n 's/.*OMP_PLACES=\([^ ]*\).*/\1/p')"
    [ -n "${p}" ] || p="${OMP_PLACES:-}"
    [ -n "${p}" ] || p="cores"
    printf '%s' "${p}"
}

# CPUs a single thread is supposed to own, given the intent and the hardware.
# 0 means "not expressible" -- judge occupancy and straddling, leave mask shape
# alone rather than invent an expectation.
_placement_want_smt () {
    case "${1%%(*}" in                 # OMP_PLACES=cores(16) -> cores
        cores|"")  printf '%s' "${TOPO_SMT}" ;;
        threads)   printf '1' ;;
        *)         printf '0' ;;
    esac
}

#-------------------------------------------------------------------------------
# placement_facts <report>
#
# The measurement half: one `key=value` per line, no judgment.  Also the input
# phase 1 needs to put a placement block into results.jsonl.
#-------------------------------------------------------------------------------
placement_facts () {
    local f="$1" places want_smt
    [ -f "${f}" ] || return 1

    load_topology "${f}"
    places="$(_placement_places "${f}")"
    want_smt="$(_placement_want_smt "${places}")"
    [ "${TOPO_SMT_LAYOUT}" = "unknown" ] && want_smt=0

    grep '^csv: ' "${f}" 2>/dev/null | awk \
        -v smt="${TOPO_SMT}" \
        -v layout="${TOPO_SMT_LAYOUT}" \
        -v cores_per_node="${TOPO_CORES_PER_NODE}" \
        -v cores_per_l3="${TOPO_CORES_PER_L3}" \
        -v cores_per_numa="${TOPO_CORES_PER_NUMA}" \
        -v cores_per_socket="${TOPO_CORES_PER_SOCKET}" \
        -v want_smt="${want_smt}" \
        -v places="${places}" '
    function ceil (a, b) { return (b > 0) ? int((a + b - 1) / b) : 0 }

    # Which physical core a logical CPU belongs to.  The model is named by the
    # probe, which verified it against lscpu -- never guessed at here.
    function core_of (cpu) {
        if (layout == "block")        return cpu % cores_per_node
        if (layout == "interleaved")  return int(cpu / smt)
        return -1
    }

    # "0-3,64" -> out[1..n].  report_placement range-compresses the mask, so an
    # unbound thread is "0-255" and not 256 comma-separated fields.
    function expand (s, out,   n, i, parts, lohi, a, b, v, cnt) {
        cnt = 0
        n = split(s, parts, ",")
        for (i = 1; i <= n; i++) {
            if (parts[i] == "") continue
            if (split(parts[i], lohi, "-") == 2) {
                a = lohi[1] + 0; b = lohi[2] + 0
                for (v = a; v <= b; v++) out[++cnt] = v
            } else out[++cnt] = parts[i] + 0
        }
        return cnt
    }

    {
        line = substr($0, 6)
        q = index(line, "\"")
        if (q == 0) next                       # the csv header row
        head = substr(line, 1, q - 1)
        aff  = substr(line, q + 1); sub(/".*$/, "", aff)
        if (split(head, fld, ",") < 11) next

        rank = fld[1] + 0; nthr = fld[3] + 0; host = fld[4]
        core = fld[6]; sock = fld[7]; nu = fld[8]; l3 = fld[9]
        if (core == "") { no_topo++; next }    # report could not resolve topology

        rows++
        hosts[host] = 1; ranks[rank] = 1
        if (nthr > threads) threads = nthr

        # Threads per PHYSICAL core -- the oversubscription signal.
        occ[host "|" core]++

        rcore[rank "|" core] = 1; rl3[rank "|" l3] = 1
        rnuma[rank "|" nu]   = 1; rsock[rank "|" sock] = 1

        if (want_smt <= 0) next                # intent not expressible; skip shape
        mask_checked = 1

        nm = expand(aff, m)
        if (nm == 0) { no_mask++; next }

        split("", mc); in_mask = 0
        for (i = 1; i <= nm; i++) {
            co = core_of(m[i])
            if (!(co in mc)) { mc[co] = 1; in_mask++ }
        }

        if (in_mask > 1) {
            strays++
            if (nm > smt) roam++               # wider than any one core: unpinned
            else          splitcore++          # small mask, wrong cores
        } else if (!((core + 0) in mc)) {
            strays++; splitcore++              # one core, but not the one it ran on
        } else if (nm < want_smt) {
            strays++; single++                 # narrower than asked for
        } else if (nm > want_smt) {
            strays++; wide++                   # wider than asked for
        }
    }

    END {
        if (rows == 0) exit 1

        for (k in ranks) nranks++
        for (k in hosts) nnodes++
        for (k in rcore) { split(k, a, "|"); ncore[a[1]]++ }
        for (k in rl3)   { split(k, a, "|"); nl3[a[1]]++   }
        for (k in rnuma) { split(k, a, "|"); nnuma[a[1]]++ }
        for (k in rsock) { split(k, a, "|"); nsock[a[1]]++ }
        for (k in ncore) if (ncore[k] > max_core) max_core = ncore[k]
        for (k in nl3)   if (nl3[k]   > max_l3)   max_l3   = nl3[k]
        for (k in nnuma) if (nnuma[k] > max_numa) max_numa = nnuma[k]
        for (k in nsock) if (nsock[k] > max_sock) max_sock = nsock[k]
        for (k in occ)   if (occ[k] > worst_occ)  worst_occ = occ[k]

        threads_per_node = rows / nnodes

        # Intended threads per core, from the geometry alone: 128 threads on 128
        # cores means 1, and a deliberate 256-thread SMT run means 2.
        want_occ = ceil(threads_per_node, cores_per_node)
        for (k in occ) if (occ[k] > want_occ) oversub_cores++

        # The floor for straddling, derived the same way for all three levels:
        # how many groups a rank of this many CORES cannot avoid touching.  The
        # group SIZES come from the probe, never from the run -- a run that does
        # not fill a node touches only part of each group and measuring the size
        # from it would under-count, then call the result optimal.
        min_l3   = ceil(max_core, cores_per_l3)
        min_numa = ceil(max_core, cores_per_numa)
        min_sock = ceil(max_core, cores_per_socket)

        printf "rows=%d\n",             rows
        printf "ranks=%d\n",            nranks
        printf "nodes=%d\n",            nnodes
        printf "threads=%d\n",          threads
        printf "ranks_per_node=%g\n",   (nnodes > 0) ? nranks / nnodes : nranks
        printf "threads_per_node=%g\n", threads_per_node
        printf "worst_occ=%d\n",        worst_occ
        printf "want_occ=%d\n",         want_occ
        printf "oversub_cores=%d\n",    oversub_cores + 0
        printf "max_core=%d\n",         max_core
        printf "max_l3=%d\n",           max_l3
        printf "min_l3=%d\n",           min_l3
        printf "max_numa=%d\n",         max_numa
        printf "min_numa=%d\n",         min_numa
        printf "max_sock=%d\n",         max_sock
        printf "min_sock=%d\n",         min_sock
        printf "strays=%d\n",           strays + 0
        printf "single=%d\n",           single + 0
        printf "wide=%d\n",             wide + 0
        printf "splitcore=%d\n",        splitcore + 0
        printf "roam=%d\n",             roam + 0
        printf "no_mask=%d\n",          no_mask + 0
        printf "no_topo=%d\n",          no_topo + 0
        printf "mask_checked=%d\n",     mask_checked + 0
        printf "want_smt=%d\n",         want_smt
        printf "places=%s\n",           places
        printf "smt=%d\n",              smt
        printf "smt_layout=%s\n",       layout
        printf "cores_per_node=%d\n",   cores_per_node
        printf "cores_per_l3=%d\n",     cores_per_l3
        printf "cores_per_numa=%d\n",   cores_per_numa
        printf "cores_per_socket=%d\n", cores_per_socket
    }'
}

#-------------------------------------------------------------------------------
# The rule engine.  `rule` is called by placement_rules.sh once the facts are in
# scope as shell variables; it evaluates the condition and, if it holds, records
# the name, severity and formatted message.
#-------------------------------------------------------------------------------
_placement_reset () {
    _fired_name=(); _fired_sev=(); _fired_msg=()
    _n_fail=0; _n_warn=0
}

rule () {
    local name="$1" sev="$2" cond="$3" fmt="$4"; shift 4
    local a v args=""

    eval "${cond}" || return 0

    for a in "$@"; do
        v="${!a:-0}"
        args="${args} ${v}"
    done

    _fired_name[${#_fired_name[@]}]="${name}"
    _fired_sev[${#_fired_sev[@]}]="${sev}"
    # shellcheck disable=SC2059,SC2086
    _fired_msg[${#_fired_msg[@]}]="$(printf "${fmt}" ${args})"

    if [ "${sev}" = fail ]; then _n_fail=$(( _n_fail + 1 ))
    else                         _n_warn=$(( _n_warn + 1 )); fi
}

# Run the facts pass and the rule table.  Returns 1 if the report is unusable.
_placement_evaluate () {
    local f="$1" k v facts

    _placement_reset

    # Load the topology in THIS shell too: placement_facts runs inside a command
    # substitution, so the TOPO_* it sets would not survive into the summary.
    load_topology "${f}"

    facts="$(placement_facts "${f}")" || return 1
    [ -n "${facts}" ] || return 1

    while IFS='=' read -r k v; do
        case "${k}" in
            [a-z]*[!a-z0-9_]*|"") continue ;;    # only our own generated keys
        esac
        printf -v "${k}" '%s' "${v}"
    done <<< "${facts}"

    placement_rules
    return 0
}

#-------------------------------------------------------------------------------
# placement_summary <report>
#
#   exit 0  nothing fired -- comparable
#   exit 1  only `warn` rules fired -- suboptimal, still comparable
#   exit 2  a `fail` rule fired -- the run measured its binding, not the code
#   exit 3  no usable rows in the report
#
# When nothing fires this prints two lines and stops: the geometry, and "placement
# OK".  Pathologies are the only thing that produces more output.
#-------------------------------------------------------------------------------
placement_summary () {
    local f="$1" i n

    if ! _placement_evaluate "${f}"; then
        printf '    no csv: rows found in %s -- did the run produce output?\n' "${f}"
        return 3
    fi

    printf '    %d ranks x %d threads on %d node(s) -- %g ranks/node, %d core(s)/rank, %d thread(s)/core\n' \
        "${ranks}" "${threads}" "${nodes}" "${ranks_per_node}" "${max_core}" "${worst_occ}"

    n=${#_fired_name[@]}
    if [ "${n}" -eq 0 ]; then
        printf '    placement OK  (OMP_PLACES=%s; %s)\n' "${places}" "$(topology_line)"
        return 0
    fi

    printf '    %d patholog%s (%d fail, %d warn)  (OMP_PLACES=%s; %s)\n' \
        "${n}" "$([ "${n}" -eq 1 ] && echo y || echo ies)" \
        "${_n_fail}" "${_n_warn}" "${places}" "$(topology_line)"
    for (( i = 0; i < n; i++ )); do
        printf '       * [%s] %s: %s\n' \
            "${_fired_sev[i]}" "${_fired_name[i]}" "${_fired_msg[i]}"
    done

    [ "${_n_fail}" -gt 0 ] && return 2
    return 1
}

# Silent.  0 means "this row may be compared against the others"; a `warn` still
# counts as comparable, a `fail` never does.
placement_summary_rc () {
    _placement_evaluate "$1" >/dev/null 2>&1 || return 1
    [ "${_n_fail}" -eq 0 ]
}

# One word, for tables and for the results record in phase 1.
placement_verdict () {
    if ! _placement_evaluate "$1" >/dev/null 2>&1; then echo nodata; return 3; fi
    if [ "${_n_fail}" -gt 0 ]; then echo fail; return 2; fi
    if [ "${_n_warn}" -gt 0 ]; then echo warn; return 1; fi
    echo ok
}

# The names of the rules that fired, one per line.  This is what
# fixtures/expected/*.rules asserts against and what phase 1 records.
placement_rules_fired () {
    local i
    _placement_evaluate "$1" >/dev/null 2>&1 || return 1
    for (( i = 0; i < ${#_fired_name[@]}; i++ )); do
        printf '%s\n' "${_fired_name[i]}"
    done
}
