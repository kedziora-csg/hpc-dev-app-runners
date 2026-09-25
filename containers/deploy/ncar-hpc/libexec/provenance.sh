#!/bin/bash
#-------------------------------------------------------------------------------
# provenance.sh -- make a results directory self-contained.
#
# Sourced.  Provides:
#
#     emit_provenance <file> [key value ...]   the `# key value` header block
#     capture_run_context <dir> [launcher]     modules.txt, env.txt, launcher.sh
#     sif_digest <sif>                         the image digest the SIF was built from
#     sif_label  <sif> <key>                   any label out of a SIF
#     harness_sha                              git SHA of this checkout
#     wall_now / wall_elapsed <t0>             sub-second wall clock
#     vecho / vshow                            verbose-only output (see below)
#
# THE RULE
#
# Reading a results directory must never require the config file, the workflow
# log, or knowing which script ran.  Everything needed to interpret a number
# lands beside it, unconditionally.
#
# OUTPUT, AND WHY THERE IS NO --quiet
#
# Diagnostics are RELOCATED, not suppressed.  modules.txt, env.txt and
# launcher.sh are always written; stdout carries only what a person reads while
# a job is queued or after it fails -- the geometry of each cell, its placement
# verdict, the figure of merit, and anything that made a cell abort.
#
# BENCH_VERBOSE=1 means "also echo those files to stdout as they are written",
# for watching a live job or bringing up a new site.  It changes what is
# DISPLAYED, never what is RECORDED, so no run is ever missing information
# because nobody set it.  That is the whole point: porting to a new machine is
# exactly when the detail is wanted and exactly when re-queueing to get it back
# costs hours.
#
# THE `# key value` SHAPE
#
# Deliberately not JSON: `grep '^#' file` hands a human the header of any
# artifact, and awk still parses it.  The machine-readable record is
# results.jsonl (results.sh) -- these two are not competing, they are the same
# facts for two different readers.
#-------------------------------------------------------------------------------

_PROV_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

#-------------------------------------------------------------------------------
# Verbosity
#-------------------------------------------------------------------------------
bench_verbose () { [ "${BENCH_VERBOSE:-0}" != "0" ]; }

# Echo only when verbose.
vecho () { bench_verbose && echo "$@"; return 0; }

# Show a file that has just been written, only when verbose.  Always announces
# nothing when quiet -- the file is there either way.
vshow () {
    local f="$1" title="${2:-$1}"
    bench_verbose || return 0
    [ -f "${f}" ] || return 0
    echo
    echo "--- ${title} ---"
    sed 's/^/  /' "${f}"
    return 0
}

#-------------------------------------------------------------------------------
# Sub-second wall clock.
#
# ${SECONDS} has 1-second granularity, which is too coarse for short cells and
# quantises every comparison between them.  GNU date does nanoseconds; BSD date
# does not and leaves a literal "N", which is what the guard below detects.
# (SLES 15 ships bash 4.4, so EPOCHREALTIME is not available either.)
#-------------------------------------------------------------------------------
wall_now () {
    local t
    t="$(date +%s.%N 2>/dev/null)"
    case "${t}" in
        *N*|"") date +%s ;;
        *)      printf '%s' "${t}" ;;
    esac
}

wall_elapsed () {
    awk -v t0="$1" -v t1="$(wall_now)" 'BEGIN { printf "%.2f", t1 - t0 }'
}

#-------------------------------------------------------------------------------
# Identity of the harness itself.  A result that cannot name the code that
# produced it cannot be reproduced, and this repo changes faster than the images.
#-------------------------------------------------------------------------------
harness_sha () {
    git -C "${_PROV_HERE}" rev-parse --short HEAD 2>/dev/null || echo unknown
}

harness_dirty () {
    if git -C "${_PROV_HERE}" diff --quiet HEAD -- 2>/dev/null; then
        echo false
    else
        echo true          # uncommitted changes: the SHA alone does not identify it
    fi
}

#-------------------------------------------------------------------------------
# Image identity.
#
# A .sif is a flattened SquashFS: the OCI layer identity is gone, so the only
# way a finished image can name the build it came from is a label stamped in at
# build time.  libexec/Makefile resolves the mutable `-latest` tag to a digest
# and stamps it; see resolve_image_digest.sh.
#
# Empty output means the SIF predates that stamping -- which is a real answer,
# not an error, and is recorded as such rather than guessed at.
#-------------------------------------------------------------------------------
sif_label () {
    local sif="$1" key="$2" out
    [ -f "${sif}" ] || return 1
    command -v apptainer >/dev/null 2>&1 || return 1

    out="$(apptainer inspect "${sif}" 2>/dev/null)"
    # Plain form is "KEY: value" per line; the JSON form nests it.  One regex
    # over whichever came out beats guessing at the apptainer version.
    printf '%s\n' "${out}" \
        | sed -n "s/.*${key}\"*[[:space:]]*:[[:space:]]*\"*\([^\",]*\).*/\1/p" \
        | head -1 | sed 's/[[:space:]]*$//'
}

sif_digest () { sif_label "$1" 'org.opencontainers.image.base.digest'; }

#-------------------------------------------------------------------------------
# Scheduler facts worth recording.  An unshared node is a precondition for
# comparing anything, and `qstat -f` is the only place PBS states it.
#-------------------------------------------------------------------------------
pbs_resource () {
    local key="$1"
    [ -n "${PBS_JOBID:-}" ] || return 0
    command -v qstat >/dev/null 2>&1 || return 0
    qstat -f "${PBS_JOBID}" 2>/dev/null \
        | tr -d '\n' | tr '\t' ' ' \
        | sed -n "s/.*Resource_List\.${key} = \([^ ]*\).*/\1/p" | head -1
}

#-------------------------------------------------------------------------------
# emit_provenance <outfile> [key value ...]
#
# Writes the `# key value` block, then anything the caller adds.  The universal
# keys are added here so every artifact carries them whether or not the caller
# remembered; the caller supplies only what it alone knows (image, geometry,
# the exact mpiexec line).
#
# Overwrites the file: run_placement then appends the run's own output after
# this header, which is what makes each .out readable on its own.
#-------------------------------------------------------------------------------
emit_provenance () {
    local out="$1"; shift
    local k v

    {
        printf '# %-16s %s\n' schema        1
        printf '# %-16s %s\n' date          "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        # Two names, because there are two levels: the site is the
        # organisation whose module names and filesystems these are, the
        # cluster is the machine.  A reader can group by either without having
        # to know that `derecho` implies NCAR.
        printf '# %-16s %s\n' site          "${BENCH_SITE:-unknown}"
        printf '# %-16s %s\n' cluster       "${BENCH_CLUSTER:-${NCAR_HOST:-unknown}}"
        printf '# %-16s %s\n' host          "$(hostname -s 2>/dev/null)"
        printf '# %-16s %s\n' job_id        "${PBS_JOBID:-${SLURM_JOB_ID:-none}}"
        printf '# %-16s %s\n' harness_sha   "$(harness_sha)"
        printf '# %-16s %s\n' harness_dirty "$(harness_dirty)"

        # Sharing matters: an unshared node is a precondition for comparing any
        # two rows, so record it rather than assume it.
        v="$(pbs_resource place)";  [ -n "${v}" ] && printf '# %-16s %s\n' pbs_place  "${v}"
        v="$(pbs_resource select)"; [ -n "${v}" ] && printf '# %-16s %s\n' pbs_select "${v}"

        while [ $# -ge 2 ]; do
            k="$1"; v="$2"; shift 2
            # Trim: `wc -l` and friends pad, and a padded header value reads as
            # a mistake even where it parses.
            v="$(printf '%s' "${v}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            printf '# %-16s %s\n' "${k}" "${v}"
        done
        [ $# -eq 1 ] && printf '# %-16s %s\n' "$1" '(no value)'
    } > "${out}"
    return 0
}

#-------------------------------------------------------------------------------
# capture_run_context <dir> [launcher-path]
#
# The sibling files that make the directory readable a year from now: what
# modules were loaded, what the environment actually was, and the generated
# launcher verbatim.  Called once per job, not once per cell -- none of it
# changes between cells.
#
# env.txt is the run's full environment: bulky, occasionally decisive, and the
# reason relocating beats suppressing -- it is always captured and never in the
# way.
#-------------------------------------------------------------------------------
capture_run_context () {
    local dir="$1" launcher="${2:-}"

    mkdir -p "${dir}" || return 1

    { module list; } > "${dir}/modules.txt" 2>&1 || true
    env | sort > "${dir}/env.txt" 2>/dev/null || true
    [ -n "${launcher}" ] && [ -f "${launcher}" ] && \
        cp "${launcher}" "${dir}/launcher.sh"

    vshow "${dir}/modules.txt" "modules"
    vshow "${dir}/env.txt"     "environment"
    vshow "${dir}/launcher.sh" "generated launcher"
    return 0
}
