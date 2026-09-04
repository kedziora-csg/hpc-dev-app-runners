#!/bin/bash
#===============================================================================
# bench/env.sh -- put the benchmark tools on your PATH.  SOURCE it, do not run it.
#
#     . /path/to/containers/deploy/bench/env.sh
#
# or add that line to ~/.bashrc.  After it, these work from any directory:
#
#     validate derecho-hpcg
#     submit   derecho-hpcg --account $PBS_ACCOUNT --results-dir $(pwd)
#     collect  ./derecho-hpcg --best
#     sitegen  --check
#
# so the usual shape of a run becomes: make a directory wherever you want the
# output, cd into it, and submit.  Results default to the directory you are
# standing in, which is what makes that work without --results-dir.
#
# Bash only, because it locates itself through $BASH_SOURCE.  That is the same
# mechanism sites/<site>/site.sh uses, and bash is the default shell on both
# machines.
#
# WHAT IT DELIBERATELY DOES NOT DO
#
# It sets PATH and nothing else.  Exporting NCAR_HPC_ROOT or BENCH_ROOT would
# look helpful and would be a trap: sites/<site>/site.sh honours both if they
# are already set, so a line in ~/.bashrc naming one clone would silently drive
# every other clone's jobs at the first clone's libexec/ and images.  Two
# checkouts on one filesystem is not a hypothetical here -- this project has
# had one in ~ and one in scratch at the same time.  So each tool works out its
# own checkout from its own location, and this file only decides which tool you
# reach by typing its name.
#
# It also does not set BENCH_SITE_CONF.  Derecho and Casper share a home
# directory, so one ~/.bashrc runs on both, and pinning a site there would point
# Casper's jobs at Derecho's profile.  Nothing needs it: an experiment names its
# site, and the search finds that site's profile in the checkout the tool came
# from.  Set it by hand for the session when you want to override that.
#
# CROSSED CLONES ARE VISIBLE, NOT PREVENTED
#
# PATH is PATH: if this file was sourced from clone A, typing `submit` in clone
# B still runs A's copy.  That is why `submit` prints the absolute path of the
# experiment and of the site profile it resolved -- read those two lines if
# anything looks surprising, or run `bench_env_show`.
#===============================================================================

# ${BASH_SOURCE[0]} rather than $0, because when a file is sourced $0 is still
# the calling shell.  Empty means one of two things, and the message names both
# rather than guessing: the file was executed instead of sourced, or the shell
# is not bash and does not define BASH_SOURCE at all.
_bench_env_self="${BASH_SOURCE[0]:-}"
if [ -z "${_bench_env_self}" ]; then
    echo "bench/env.sh: cannot work out where I am." >&2
    echo "  Either source it rather than running it:" >&2
    echo "      . ${0}" >&2
    echo "  or your shell is not bash and has no \$BASH_SOURCE.  Bash is the" >&2
    echo "  default on both machines; if you have changed yours, everything" >&2
    echo "  this file does is one line you can type instead:" >&2
    echo "      export PATH=/path/to/containers/deploy/bench:\$PATH" >&2
    return 1 2>/dev/null || exit 1
fi

BENCH_ENV_ROOT="$(cd "$(dirname "${_bench_env_self}")" && pwd)"
unset _bench_env_self

# Prepended, so this checkout's tools win over any other copy already on the
# path; and only once, so sourcing twice -- or a ~/.bashrc read again by a
# subshell -- does not grow PATH without bound.
case ":${PATH}:" in
    *":${BENCH_ENV_ROOT}:"*) ;;
    *) PATH="${BENCH_ENV_ROOT}:${PATH}" ;;
esac
export PATH

# Deliberately NOT exported: nothing else reads this name, so it cannot cross
# two checkouts the way NCAR_HPC_ROOT or BENCH_ROOT would.  It exists so
# bench_env_show can answer "which clone am I typing at?", which is a real
# question the moment there are two.
export BENCH_ENV_ROOT

#-------------------------------------------------------------------------------
# bench_env_show -- what is in force, when the answer is not obvious.
#-------------------------------------------------------------------------------
bench_env_show () {
    local tool
    printf 'bench tools : %s\n' "${BENCH_ENV_ROOT}"

    tool="$(command -v submit 2>/dev/null)"
    if [ -z "${tool}" ]; then
        printf 'submit      : not on PATH\n'
    elif [ "${tool}" = "${BENCH_ENV_ROOT}/submit" ]; then
        printf 'submit      : this checkout\n'
    else
        printf 'submit      : %s\n' "${tool}"
        printf '              ^ a DIFFERENT checkout is first on PATH\n'
    fi

    printf 'site profile: %s\n' "${BENCH_SITE_CONF:-<searched per experiment>}"
    printf 'results root: %s\n' "${BENCH_RESULTS_ROOT:-<the directory you submit from>}"
    [ -n "${BENCH_QUEUE:-}" ] && \
        printf 'queue       : %s   (overriding the site file)\n' "${BENCH_QUEUE}"
    [ -n "${BENCH_PLACE+set}" ] && \
        printf 'place       : %s   (overriding the site file)\n' "${BENCH_PLACE:-<off>}"
    return 0
}
