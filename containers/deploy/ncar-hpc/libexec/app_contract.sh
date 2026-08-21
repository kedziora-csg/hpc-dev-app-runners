#!/bin/bash
#-------------------------------------------------------------------------------
# app_contract.sh -- drive an application without knowing which one it is.
#
# Sourced.  Provides:
#
#     app_resolve <app> <launcher> <outdir>   find the contract, read app.yaml
#     app_export_geometry <rundir> <placement> <nodes> <ranks> <ppn> <threads>
#     app_prepare  <rundir>                   0 = ready, non-zero = decline the cell
#     app_argv                                the argv to launch, one line
#     app_extract  <rundir> <outfile>         hook output as `key=value`
#
# After app_resolve: APP_NAME APP_VERSION APP_BINARY APP_DIR APP_DIR_OVERRIDE.
#
# THE POINT
#
# The runner used to carry HPCG: a knob for its problem size, a branch on its
# name, a heredoc for its input file, and a grep for its output format.  Adding
# a second application meant editing the runner, which does not scale and is the
# whole reason there is a contract instead of another `case` arm.
#
# The test of this file is scripts/app.d/osu/: a second application, unlike the
# first in every way that matters -- no input file, flags instead, results on
# stdout instead of in a report -- added without a line changing here.
#
# WHERE THE HOOKS RUN
#
# Inside the container, through the launcher, always.  They are part of the
# image and may use anything in it.  A BENCH_APP_DIR override must therefore sit
# under a path the launcher binds (on Derecho, /glade), or the container will not
# be able to see it.
#
# WHY ONLY THREE FIELDS ARE READ FROM app.yaml
#
# The job does not parse YAML.  It reads three top-level scalars -- app, version,
# binary -- with a small reader that handles exactly the flat `key: value` lines
# our own files use, and nothing else.  Everything nested (primary_fom's
# direction, units, requires, success_criteria) is for host-side tools, which
# have Python; app_resolve copies app.yaml into the results directory so
# bench/collect can read it there.
#
# If that reader is ever tempted to grow, the answer is to move the field to the
# host side, not to write more YAML parsing in shell.
#-------------------------------------------------------------------------------

APP_NAME="" APP_VERSION="" APP_BINARY="" APP_DIR="" APP_DIR_OVERRIDE=false
_APP_YAML="" _APP_LAUNCHER=""

# Top-level `key: value` only.  Strips an inline comment, then surrounding
# quotes, then trailing space.
_yaml_scalar () {
    sed -n "s/^$2:[[:space:]]*//p" "$1" 2>/dev/null | head -1 \
        | sed -e 's/[[:space:]]\{1,\}#.*$//' \
              -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/" \
              -e 's/[[:space:]]*$//'
}

#-------------------------------------------------------------------------------
# app_resolve <app> <launcher> <outdir>
#
# <app> is a NAME resolved under /container/app.d/, or a PATH to an executable.
# The path form is not a special case in the runner: it synthesises the minimal
# legal contract -- a binary and no hooks -- which is exactly what the contract
# says an app may provide.  Running a one-off executable and onboarding an
# application properly are then the same code path, differing only in how much
# the app chose to declare.
#-------------------------------------------------------------------------------
app_resolve () {
    local app="$1" launcher="$2" outdir="$3"
    _APP_LAUNCHER="${launcher}"
    APP_DIR_OVERRIDE=false

    case "${app}" in
        */*)
            APP_NAME="$(basename "${app}")"
            APP_VERSION=""
            APP_BINARY="${app}"
            APP_DIR=""
            _APP_YAML=""
            return 0
            ;;
    esac

    if [ -n "${BENCH_APP_DIR:-}" ]; then
        # A development override: the extractor can be fixed without rebuilding
        # an image.  Recorded in every row so such results are never mistaken
        # for reproducible ones.
        if   [ -f "${BENCH_APP_DIR}/${app}/app.yaml" ]; then APP_DIR="${BENCH_APP_DIR}/${app}"
        elif [ -f "${BENCH_APP_DIR}/app.yaml" ];       then APP_DIR="${BENCH_APP_DIR}"
        else
            echo "BENCH_APP_DIR=${BENCH_APP_DIR} has no ${app}/app.yaml" >&2
            return 1
        fi
        APP_DIR_OVERRIDE=true
    else
        APP_DIR="/container/app.d/${app}"
    fi

    # Read app.yaml out of the container and keep the copy: a results directory
    # that records a metric should also record what declared it.
    _APP_YAML="${outdir}/app.yaml"
    if ! ${launcher} cat "${APP_DIR}/app.yaml" > "${_APP_YAML}" 2>/dev/null \
         || [ ! -s "${_APP_YAML}" ]; then
        rm -f "${_APP_YAML}"
        echo "no app contract at ${APP_DIR}/app.yaml" >&2
        echo "  the image predates it, or the app name is wrong;" >&2
        echo "  BENCH_APP_DIR=<host path> overrides it for development" >&2
        return 1
    fi

    APP_NAME="$(_yaml_scalar "${_APP_YAML}" app)"
    APP_VERSION="$(_yaml_scalar "${_APP_YAML}" version)"
    APP_BINARY="$(_yaml_scalar "${_APP_YAML}" binary)"
    [ -n "${APP_NAME}" ] || APP_NAME="${app}"

    if [ -z "${APP_BINARY}" ] && ! ${launcher} test -x "${APP_DIR}/launch" 2>/dev/null; then
        echo "${APP_DIR}/app.yaml declares no binary and there is no launch hook" >&2
        return 1
    fi
    return 0
}

#-------------------------------------------------------------------------------
# app_export_geometry <rundir> <placement> <nodes> <ranks> <ranks_per_node> <threads>
#
# The same variables for every app, so a hook is a small shell script and not an
# argument-parsing exercise.  Topology comes from the probe (topology.json), so
# an app that sizes its problem from cache or memory gets the real machine
# rather than a constant someone typed.
#-------------------------------------------------------------------------------
app_export_geometry () {
    export BENCH_APP="${APP_NAME}"
    export BENCH_RUNDIR="$1"
    export BENCH_PLACEMENT="$2"
    export BENCH_NODES="$3"
    export BENCH_RANKS="$4"
    export BENCH_RANKS_PER_NODE="$5"
    export BENCH_THREADS="$6"
    export BENCH_SCALE="${BENCH_SCALE:-node}"
    export BENCH_TARGET_SECONDS="${BENCH_TARGET_SECONDS:-60}"
    export BENCH_CORES_PER_NODE="${TOPO_CORES_PER_NODE}"
    export BENCH_CORES_PER_L3="${TOPO_CORES_PER_L3}"
    export BENCH_CORES_PER_NUMA="${TOPO_CORES_PER_NUMA}"
    export BENCH_SCRATCH="${BENCH_SCRATCH:-}"
}

_app_has_hook () {
    [ -n "${APP_DIR}" ] || return 1
    ${_APP_LAUNCHER} test -x "${APP_DIR}/$1" 2>/dev/null
}

#-------------------------------------------------------------------------------
# app_prepare <rundir>
#
# 0 when the cell is ready to run.  Non-zero means the app DECLINED this
# geometry -- the runner records it as skipped with the reason, rather than
# failing the whole job.  An app that cannot run 8 ranks should say so once, not
# crash three hours into a queue.
#-------------------------------------------------------------------------------
app_prepare () {
    _app_has_hook prepare || return 0
    ${_APP_LAUNCHER} "${APP_DIR}/prepare" "$1" > "$1/prepare.log" 2>&1
}

#-------------------------------------------------------------------------------
# app_argv -- the command line, one line.
#
# The launch hook wins if there is one; otherwise `binary` from app.yaml.  A
# launch hook that fails falls back to the binary rather than launching nothing.
#-------------------------------------------------------------------------------
app_argv () {
    local argv=""
    if _app_has_hook launch; then
        argv="$(${_APP_LAUNCHER} "${APP_DIR}/launch" 2>/dev/null)"
    fi
    [ -n "${argv}" ] || argv="${APP_BINARY}"
    printf '%s' "${argv}"
}

#-------------------------------------------------------------------------------
# app_extract <rundir> <outfile>
#
# Always succeeds, and may legitimately write nothing: unparseable output is a
# missing metric, not a failed run.  A cell that produced no number is still a
# cell that ran, and forcing it to fail would discard the placement verdict and
# the wall time that came with it.
#-------------------------------------------------------------------------------
app_extract () {
    : > "$2"
    _app_has_hook extract || return 0
    ${_APP_LAUNCHER} "${APP_DIR}/extract" "$1" > "$2" 2>/dev/null
    return 0
}
