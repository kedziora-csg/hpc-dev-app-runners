#!/bin/bash
#-------------------------------------------------------------------------------
# probe_topology.sh -- discover the node's CPU topology, once per job, and read
# it back.  Sourced; provides two functions:
#
#     probe_topology [outfile]      write topology.json (default ./topology.json)
#     load_topology  [file|dir]     set TOPO_* variables from one, or fall back
#
# WHY PROBE RATHER THAN HARDCODE
#
# Topology must never be inferred from a placement REPORT: a run that does not
# fill a node touches only part of each CCD, so measuring cores-per-L3 from it
# under-counts and then declares the resulting placement optimal.
#
# That is not an argument against asking the MACHINE.  lscpu on a compute node is
# authoritative, costs nothing, is correct on Casper and on any future non-Milan
# node, and turns the topology into recorded provenance.
#
# The site profile's node: block survives only as a last-resort fallback, and is
# labelled as such in the output so a fallback is never mistaken for a
# measurement.  It is not stated here: sites/<site>.yaml is where a machine's
# geometry is decided, and this file has no business having an opinion about
# which machine it is running on.
#
# WHAT IT WRITES
#
# A flat, numbers-and-short-strings JSON object, so a shell can read it with sed
# and no jq dependency:
#
#     {
#       "source": "lscpu",
#       "host": "dec0153",
#       "cpus": 256, "cores_per_node": 128, "sockets": 2,
#       "smt": 2, "smt_stride": 128, "smt_layout": "block",
#       "cores_per_socket": 64, "cores_per_l3": 8,
#       "numa_domains": 8, "cores_per_numa": 16
#     }
#
# smt_layout names how the kernel enumerates SMT siblings, which is the one thing
# a mask check cannot guess:
#
#     block        all first siblings, then all seconds -- sibling of core c is
#                  CPU c+stride, stride == cores_per_node   (Derecho / Milan)
#     interleaved  siblings adjacent -- core c owns CPUs c*smt .. c*smt+smt-1
#     unknown      neither model reproduces lscpu's map; mask-shape rules are
#                  then skipped rather than guessed at
#
# The layout is not assumed: probe_topology checks each model against lscpu's
# actual cpu->core map and only names one that reproduces it exactly.
#-------------------------------------------------------------------------------

# Last-resort fallback, used only when lscpu is unavailable AND no topology.json
# was written.  The numbers come from the site profile -- the node: block of
# sites/<site>.yaml, generated into site.sh -- and not from this file, which used
# to state Derecho's geometry itself.  Three files saying 128 cores, with nothing
# comparing them, is how a fallback stops describing the machine it names.
#
# Nothing is invented here.  Without a profile the fallback reports a single
# core with no SMT, which is wrong in the direction that makes a caller notice:
# it refuses every multi-rank placement instead of accepting one the node cannot
# run.  TOPO_SOURCE says which of the two happened.
TOPO_FALLBACK_SOURCE="fallback:site-profile"
_topo_set_fallback () {
    TOPO_HOST=""
    TOPO_FILE=""
    TOPO_SMT_LAYOUT="block"

    if [ -n "${BENCH_CORES_PER_NODE:-}" ]; then
        TOPO_SOURCE="${TOPO_FALLBACK_SOURCE}:${BENCH_SITE:-unknown}"
        TOPO_CORES_PER_NODE="${BENCH_CORES_PER_NODE}"
        TOPO_SMT="${BENCH_SMT:-1}"
        TOPO_SOCKETS="${BENCH_SOCKETS:-1}"
        TOPO_SMT_STRIDE="${BENCH_SMT_STRIDE:-${BENCH_CORES_PER_NODE}}"
        TOPO_CORES_PER_L3="${BENCH_CORES_PER_L3:-${BENCH_CORES_PER_NODE}}"
        TOPO_CORES_PER_NUMA="${BENCH_CORES_PER_NUMA:-${BENCH_CORES_PER_NODE}}"
    else
        TOPO_SOURCE="fallback:none"
        TOPO_CORES_PER_NODE=1
        TOPO_SMT=1
        TOPO_SOCKETS=1
        TOPO_SMT_STRIDE=1
        TOPO_CORES_PER_L3=1
        TOPO_CORES_PER_NUMA=1
    fi

    TOPO_CPUS=$((TOPO_CORES_PER_NODE * TOPO_SMT))
    TOPO_CORES_PER_SOCKET=$((TOPO_CORES_PER_NODE / TOPO_SOCKETS))
    TOPO_NUMA_DOMAINS=$((TOPO_CORES_PER_NODE / TOPO_CORES_PER_NUMA))
}

#-------------------------------------------------------------------------------
# probe_topology [outfile]
#
# Returns 0 and writes JSON on success; returns 1 and writes nothing if lscpu is
# missing or unparseable, so the caller can decide whether that is fatal.
#-------------------------------------------------------------------------------
probe_topology () {
    local out="${1:-topology.json}" raw

    command -v lscpu >/dev/null 2>&1 || {
        echo "probe_topology: lscpu not found; no topology.json written" >&2
        return 1
    }

    # -p is the stable, parseable form.  CACHE is a colon-separated list of cache
    # ids, innermost first (L1d:L1i:L2:L3); the LAST entry is the last-level
    # cache, which on Milan is the per-CCD L3 we care about.
    raw="$(lscpu -p=CPU,CORE,SOCKET,NODE,CACHE 2>/dev/null | grep -v '^#')"
    [ -n "${raw}" ] || {
        echo "probe_topology: lscpu -p produced nothing; no topology.json written" >&2
        return 1
    }

    printf '%s\n' "${raw}" | awk -F, -v host="$(hostname -s 2>/dev/null)" '
    function ceil (a, b) { return int((a + b - 1) / b) }
    {
        cpu = $1 + 0; core = $2 + 0; sock = $3 + 0; node = $4 + 0
        # last colon-field of the CACHE column == last-level (L3) cache id
        nl = split($5, cc, ":"); l3 = (nl > 0) ? cc[nl] : "?"

        ncpu++
        core_of[cpu] = core
        cores[core] = 1; socks[sock] = 1; nodes[node] = 1; l3s[l3] = 1
        if (!(core in first_cpu)) first_cpu[core] = cpu
        else if (!(core in second_cpu)) second_cpu[core] = cpu
        if (nmin == 0 || core < min_core) { min_core = core; nmin = 1 }
        if (cpu > max_cpu) max_cpu = cpu
    }
    END {
        for (k in cores) ncores++
        for (k in socks) nsock++
        for (k in nodes) nnuma++
        for (k in l3s)   nl3++
        if (ncores == 0 || ncpu == 0) exit 1

        smt = int(ncpu / ncores)

        # Stride between a core.s first and second sibling.  Meaningless (and
        # reported as 0) when SMT is off.
        stride = 0
        if (smt > 1 && (min_core in second_cpu))
            stride = second_cpu[min_core] - first_cpu[min_core]

        # Name the enumeration model only if it reproduces lscpu exactly.
        block = 1; inter = 1
        for (c in core_of) {
            ci = c + 0
            if (core_of[c] != (ci % ncores))  block = 0
            if (core_of[c] != int(ci / smt))  inter = 0
        }
        layout = block ? "block" : (inter ? "interleaved" : "unknown")
        if (smt == 1) { layout = "block"; stride = ncores }

        printf "{\n"
        printf "  \"source\": \"lscpu\",\n"
        printf "  \"host\": \"%s\",\n", host
        printf "  \"cpus\": %d,\n",             ncpu
        printf "  \"cores_per_node\": %d,\n",   ncores
        printf "  \"sockets\": %d,\n",          nsock
        printf "  \"smt\": %d,\n",              smt
        printf "  \"smt_stride\": %d,\n",       stride
        printf "  \"smt_layout\": \"%s\",\n",   layout
        printf "  \"cores_per_socket\": %d,\n", ceil(ncores, nsock)
        printf "  \"cores_per_l3\": %d,\n",     ceil(ncores, nl3)
        printf "  \"numa_domains\": %d,\n",     nnuma
        printf "  \"cores_per_numa\": %d\n",    ceil(ncores, nnuma)
        printf "}\n"
    }' > "${out}" || { rm -f "${out}"; return 1; }

    [ -s "${out}" ] || { rm -f "${out}"; return 1; }
    return 0
}

#-------------------------------------------------------------------------------
# load_topology [file-or-directory]
#
# Sets TOPO_* from the first topology.json found, searching in this order:
#
#     1. $PLACEMENT_TOPOLOGY                (explicit override)
#     2. the argument, as a file or as <dir>/topology.json
#     3. ./topology.json
#     4. the built-in Derecho fallback
#
# Rule 2 is what makes a results directory self-describing: hand the checker a
# report file and it picks up the topology.json written beside it, so a report
# captured on Derecho is judged with Derecho.s topology no matter where the
# checker runs.  That is also what makes libexec/fixtures/ testable on a laptop.
#-------------------------------------------------------------------------------
load_topology () {
    local hint="${1:-}" f=""

    if   [ -n "${PLACEMENT_TOPOLOGY:-}" ] && [ -f "${PLACEMENT_TOPOLOGY}" ]; then
        f="${PLACEMENT_TOPOLOGY}"
    elif [ -n "${hint}" ] && [ -f "${hint}" ] && \
         [ "$(basename "${hint}")" = "topology.json" ]; then
        f="${hint}"
    elif [ -n "${hint}" ] && [ -d "${hint}" ] && [ -f "${hint}/topology.json" ]; then
        f="${hint}/topology.json"
    elif [ -n "${hint}" ] && [ -f "$(dirname "${hint}")/topology.json" ]; then
        f="$(dirname "${hint}")/topology.json"
    elif [ -f "./topology.json" ]; then
        f="./topology.json"
    fi

    _topo_set_fallback
    [ -n "${f}" ] || return 0

    TOPO_FILE="${f}"
    TOPO_SOURCE="$(_topo_str  "${f}" source)"
    TOPO_HOST="$(_topo_str    "${f}" host)"
    TOPO_SMT_LAYOUT="$(_topo_str "${f}" smt_layout)"
    TOPO_CPUS="$(_topo_num           "${f}" cpus)"
    TOPO_CORES_PER_NODE="$(_topo_num "${f}" cores_per_node)"
    TOPO_SOCKETS="$(_topo_num        "${f}" sockets)"
    TOPO_SMT="$(_topo_num            "${f}" smt)"
    TOPO_SMT_STRIDE="$(_topo_num     "${f}" smt_stride)"
    TOPO_CORES_PER_SOCKET="$(_topo_num "${f}" cores_per_socket)"
    TOPO_CORES_PER_L3="$(_topo_num   "${f}" cores_per_l3)"
    TOPO_NUMA_DOMAINS="$(_topo_num   "${f}" numa_domains)"
    TOPO_CORES_PER_NUMA="$(_topo_num "${f}" cores_per_numa)"
    return 0
}

# Flat-JSON readers.  The file is written by probe_topology above -- one key per
# line, no nesting -- so sed is sufficient and jq is not a dependency.
_topo_num () {
    sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$1" | head -1
}
_topo_str () {
    sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -1
}

# One line naming the topology in force, for run headers and summaries.
topology_line () {
    printf '%s cores/node, SMT %s (stride %s, %s), %s cores/L3, %s cores/NUMA, %s socket(s) [%s]' \
        "${TOPO_CORES_PER_NODE}" "${TOPO_SMT}" "${TOPO_SMT_STRIDE}" \
        "${TOPO_SMT_LAYOUT}" "${TOPO_CORES_PER_L3}" "${TOPO_CORES_PER_NUMA}" \
        "${TOPO_SOCKETS}" "${TOPO_FILE:-${TOPO_SOURCE}}"
}

_topo_set_fallback
