#!/bin/bash
#-------------------------------------------------------------------------------
# results.sh -- one JSON object per measured cell, appended to results.jsonl.
#
# Sourced.  Provides:
#
#     result_reset                        start a new record
#     result_set    <field> <value>       scalar, type inferred
#     result_str    <field> <value>       force a string (an empty one stays "")
#     result_metric <name>  <value>       one figure of merit
#     result_metrics_from_file <file>     `key=value` lines -> metrics
#     result_rule   <name>                append to placement.rules[]
#     result_emit   <results.jsonl>       append the record, one line
#
# JSONL, NOT CSV
#
# Metric sets differ per app, so a CSV would need a union header decided up
# front and rewritten whenever an app is added.  Appending a line is also
# crash-safe: a job killed at walltime leaves every completed cell intact and
# loses only the one that was running.  bench/collect flattens to a table or CSV
# at READ time, where the set of columns is known because the rows are in hand.
#
# FIELDS
#
#     top level     site cluster job_id nodes repeat wall_s exit valid warm
#     image.        sif digest os compiler mpi
#     app.          name version scale app_dir_override
#     placement.    name ranks_per_node threads mpiexec_flags verdict
#     placement.omp.<VAR>
#     metrics.<name>          -- via result_metric / result_metrics_from_file
#     placement.rules[]       -- via result_rule
#
# `schema` and `timestamp` are added by result_emit; nothing else is implicit.
#
# TYPING
#
# result_set infers: a bare number stays a number, true/false/null stay
# literals, an EMPTY value becomes `null`.  That last one is deliberate --
# `"digest": null` says "this SIF predates the label stamp", which is a fact,
# where `"digest": ""` would read like a digest that happens to be blank.  When
# empty genuinely means the empty string (no mpiexec flags, say), use result_str.
#
# `result_metrics_from_file` takes exactly the `key=value` stream that an app's
# `extract` hook prints (plan section 3), so phase 2 wires an app in without
# touching this file.  It takes a PATH rather than stdin on purpose: a shell
# function on the right of a pipe runs in a subshell, so `extract | result_...`
# would accumulate every metric and then discard them, silently and with a
# zero exit status.  Phase 2 wants extract's output on disk beside the run
# anyway, so there is nothing to trade away.
#-------------------------------------------------------------------------------

_RES_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# vecho lives there, and a results file without its sibling provenance files is
# only half a record anyway.
. "${_RES_HERE}/provenance.sh" || return 1 2>/dev/null || exit 1

_R_TOP="" _R_IMAGE="" _R_APP="" _R_PLACE="" _R_OMP="" _R_METRICS="" _R_RULES=""

result_reset () {
    _R_TOP="" _R_IMAGE="" _R_APP="" _R_PLACE="" _R_OMP="" _R_METRICS="" _R_RULES=""
}

_json_escape () {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '[:cntrl:]'
}

# Render a value with its type inferred.  See TYPING above.
#
# Surrounding whitespace is stripped first: `wc -l` pads its output on some
# platforms, and an unnoticed space would silently turn a count into the STRING
# " 2" -- which parses, tabulates and sorts wrongly rather than failing.
_json_value () {
    set -- "$(printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    case "$1" in
        "")               printf 'null'; return ;;
        true|false|null)  printf '%s' "$1"; return ;;
    esac
    if printf '%s' "$1" | grep -Eq '^-?[0-9]+(\.[0-9]+)?$'; then
        printf '%s' "$1"
    else
        printf '"%s"' "$(_json_escape "$1")"
    fi
}

# Append `"key": value` to the accumulator its dotted path names.
_result_add () {
    local field="$1" rendered="$2" key sect

    case "${field}" in
        image.*)         sect=IMAGE;   key="${field#image.}" ;;
        app.*)           sect=APP;     key="${field#app.}" ;;
        placement.omp.*) sect=OMP;     key="${field#placement.omp.}" ;;
        placement.*)     sect=PLACE;   key="${field#placement.}" ;;
        metrics.*)       sect=METRICS; key="${field#metrics.}" ;;
        *)               sect=TOP;     key="${field}" ;;
    esac

    case "${sect}" in
        TOP)     _R_TOP="${_R_TOP:+${_R_TOP},}\"${key}\":${rendered}" ;;
        IMAGE)   _R_IMAGE="${_R_IMAGE:+${_R_IMAGE},}\"${key}\":${rendered}" ;;
        APP)     _R_APP="${_R_APP:+${_R_APP},}\"${key}\":${rendered}" ;;
        PLACE)   _R_PLACE="${_R_PLACE:+${_R_PLACE},}\"${key}\":${rendered}" ;;
        OMP)     _R_OMP="${_R_OMP:+${_R_OMP},}\"${key}\":${rendered}" ;;
        METRICS) _R_METRICS="${_R_METRICS:+${_R_METRICS},}\"${key}\":${rendered}" ;;
    esac
}

result_set    () { _result_add "$1" "$(_json_value "$2")"; }
result_str    () { _result_add "$1" "\"$(_json_escape "$2")\""; }
result_metric () { _result_add "metrics.$1" "$(_json_value "$2")"; }

result_rule () {
    [ -n "$1" ] || return 0
    _R_RULES="${_R_RULES:+${_R_RULES},}\"$(_json_escape "$1")\""
}

# <file>: `key=value` lines.  Anything unparseable is skipped rather than
# recorded as a broken metric -- an app's extract hook is allowed to print
# nothing at all, and a missing metric is not a failed run.
result_metrics_from_file () {
    local f="$1" line k v
    [ -f "${f}" ] || return 0
    while IFS= read -r line; do
        case "${line}" in
            *=*) k="${line%%=*}"; v="${line#*=}" ;;
            *)   continue ;;
        esac
        case "${k}" in
            ''|*[!A-Za-z0-9_]*) continue ;;
        esac
        # An app self-reporting validity is a top-level fact about the run, not
        # one of its figures of merit.
        if [ "${k}" = valid ]; then result_set valid "${v}"; else result_metric "${k}" "${v}"; fi
    done < "${f}"
}

#-------------------------------------------------------------------------------
# result_emit <results.jsonl>
#
# One object, one line, appended.  Empty sections are omitted rather than
# emitted as `{}`: a reader can then tell "no metrics were extracted" from "the
# app reported an empty metric set", and the row stays short.
#-------------------------------------------------------------------------------
result_emit () {
    local out="$1" rec place

    # 2 since phase 4.5: `site` used to hold the CLUSTER name.  A reader that
    # sees schema 1 should treat that row's `site` as its cluster and its site
    # as unknown, which is what bench/collect does.
    rec="{\"schema\":2"
    rec="${rec},\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
    [ -n "${_R_TOP}"   ] && rec="${rec},${_R_TOP}"
    [ -n "${_R_IMAGE}" ] && rec="${rec},\"image\":{${_R_IMAGE}}"
    [ -n "${_R_APP}"   ] && rec="${rec},\"app\":{${_R_APP}}"

    if [ -n "${_R_PLACE}${_R_OMP}${_R_RULES}" ]; then
        place="${_R_PLACE}"
        [ -n "${_R_OMP}" ] && place="${place:+${place},}\"omp\":{${_R_OMP}}"
        place="${place:+${place},}\"rules\":[${_R_RULES}]"
        rec="${rec},\"placement\":{${place}}"
    fi

    [ -n "${_R_METRICS}" ] && rec="${rec},\"metrics\":{${_R_METRICS}}"
    rec="${rec}}"

    printf '%s\n' "${rec}" >> "${out}" || return 1
    vecho "  recorded: ${rec}"
    return 0
}
