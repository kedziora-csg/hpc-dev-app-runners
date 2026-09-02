#!/bin/bash
#-------------------------------------------------------------------------------
# check_arch.sh -- does this image's binary fit the CPU that will run it?
#
# Sourced; provides one function:
#
#     arch_check <launcher> <binary> [outfile]
#
# WHAT IT IS FOR
#
# A binary built for a newer microarchitecture than the host dies with a bare
# `Illegal instruction` -- SIGILL, exit 132, on every rank, with no output and no
# hint of the cause.  It happens three hours into a queue, and it looks like an
# operating-system problem rather than what it is.  The plan's section 4 asks the
# site to declare what it can run precisely so that becomes one line before the
# first cell instead.
#
# It is deliberately a CHECK and not an input.  The image was built in CI long
# before any site profile was read, so a site cannot influence what it contains
# -- only refuse to measure it.
#
# WHAT IT CAN AND CANNOT SEE
#
# report_cpu_features, which already ships in every image, reports the host's ISA
# flags and, for a given executable, whether it uses AVX-512 (x86) or SVE
# (aarch64) registers.  That is one class of over-building, not all of them: a
# binary compiled -march=x86-64-v3 and run on a v2 host would use AVX2 without
# ever touching a zmm register, and nothing here would catch it.
#
# That is the honest limit and it is worth stating, because the alternative --
# claiming a general guarantee -- would be worse than the narrow one. The class
# it does catch is the class that has actually bitten this project: an nvhpc
# binary that took `-tp znver4` from the build runner and met an AVX2-only node.
#
# WHAT IT DOES WITH BENCH_TARGET_ARCH
#
# Two different comparisons, and they answer different questions:
#
#   binary vs HOST     a measurement against a measurement.  This is the one
#                      that decides whether to run: it is what SIGILLs.
#   host vs SITE FILE  a measurement against a claim.  A disagreement means
#                      sites/<site>.yaml is wrong, which is worth saying out
#                      loud but is not a reason to refuse this job.
#-------------------------------------------------------------------------------

command -v vecho >/dev/null 2>&1 \
    || vecho () { [ "${BENCH_VERBOSE:-0}" != "0" ] && echo "$@"; return 0; }

# The x86-64 psABI levels, as far as ISA flags can tell them apart.  Ordered, so
# they can be compared as numbers.
_arch_level_x86 () {
    local flags="$1"
    case "${flags}" in
        *avx512*)                                    echo 4; return ;;
    esac
    case "${flags}" in
        *avx2*) case "${flags}" in *fma*) echo 3; return ;; esac ;;
    esac
    case "${flags}" in
        *sse4_2*) echo 2; return ;;
    esac
    echo 1
}

_arch_level_name () {
    case "$1" in
        4) echo "x86-64-v4" ;;
        3) echo "x86-64-v3" ;;
        2) echo "x86-64-v2" ;;
        *) echo "x86-64"    ;;
    esac
}

_arch_declared_level () {
    case "$1" in
        x86-64-v4)          echo 4 ;;
        x86-64-v3|znver[34]|zen[34]|skylake*|haswell|broadwell) echo 3 ;;
        x86-64-v2)          echo 2 ;;
        x86-64)             echo 1 ;;
        *)                  echo 0 ;;      # not an x86 level we can order
    esac
}

#-------------------------------------------------------------------------------
# arch_check <launcher> <binary> [outfile]
#
# Writes the full report to <outfile> (default cpu_features.txt) and one or two
# lines to stdout.  Sets ARCH_VERDICT to ok | over-built | site-mismatch |
# unknown.  Returns 1 only for over-built, and only when the operator has not
# said to proceed anyway with BENCH_ALLOW_ARCH_MISMATCH=1.
#-------------------------------------------------------------------------------
arch_check () {
    local launcher="$1" binary="$2" out="${3:-cpu_features.txt}"
    local tool="${BENCH_CPU_FEATURES:-/container/bin/report_cpu_features}"
    local flags host_level want_level needs_wide

    ARCH_VERDICT="unknown"

    if ! ${launcher} test -x "${tool}" 2>/dev/null; then
        echo "cpu       ${tool} not in this image; instruction set unchecked"
        return 0
    fi

    ${launcher} "${tool}" "${binary}" > "${out}" 2>&1 || true
    vshow "${out}" "cpu features" 2>/dev/null || true

    flags="$(sed -n 's/^ *ISA flags: *//p' "${out}" | head -1)"
    if [ -z "${flags}" ]; then
        # aarch64, or a host whose /proc/cpuinfo does not carry a flags line.
        flags="$(sed -n 's/^ *SIMD: *//p' "${out}" | head -1)"
        [ -n "${flags}" ] || { echo "cpu       could not read the host ISA from ${out}"
                               return 0; }
    fi

    # Does the binary need something wide?  These are report_cpu_features' own
    # two answers; anything else means it could not tell, which is not the same
    # as no.
    needs_wide=""
    grep -q 'AVX-512 (zmm) used by binary: YES' "${out}" && needs_wide="AVX-512"
    grep -q 'SVE (z-regs) used by binary: YES'  "${out}" && needs_wide="SVE"

    host_level="$(_arch_level_x86 "${flags}")"
    echo "cpu       host $(_arch_level_name "${host_level}") [${flags% }]${needs_wide:+; binary uses ${needs_wide}}"

    # 1. The measurement that decides whether to run.
    if [ -n "${needs_wide}" ]; then
        local host_has=no
        case "${needs_wide}:${flags}" in
            AVX-512:*avx512*) host_has=yes ;;
            SVE:*sve*)        host_has=yes ;;
        esac
        if [ "${host_has}" = no ]; then
            ARCH_VERDICT="over-built"
            echo "*** this binary requires ${needs_wide} and this host does not have it."
            echo "    Every rank would die with SIGILL (exit 132) and no output."
            echo "    ${binary}"
            echo "    see ${out}"
            echo "    The image was built for a different machine.  Rebuild it with"
            echo "    MARCH_FLAGS matching this site (${BENCH_TARGET_ARCH:-unset}), or"
            echo "    set BENCH_ALLOW_ARCH_MISMATCH=1 to run it anyway and watch it fail."
            [ "${BENCH_ALLOW_ARCH_MISMATCH:-0}" = 1 ] || return 1
            echo "    BENCH_ALLOW_ARCH_MISMATCH=1: continuing."
            return 0
        fi
    fi

    # 2. The claim, checked against the measurement.  Never fatal: the job can
    #    run perfectly well while the site file is out of date, and finding out
    #    the file is wrong is worth more than refusing.
    want_level="$(_arch_declared_level "${BENCH_TARGET_ARCH:-}")"
    if [ -n "${BENCH_TARGET_ARCH:-}" ] && [ "${want_level}" -gt 0 ] 2>/dev/null; then
        if [ "${host_level}" -ne "${want_level}" ]; then
            ARCH_VERDICT="site-mismatch"
            echo "note      sites/${BENCH_SITE}.yaml says node.target_arch: ${BENCH_TARGET_ARCH},"
            echo "          but this node reports $(_arch_level_name "${host_level}")."
            echo "          The job is fine; the site description is not.  Results built"
            echo "          on the declared value -- an app's microarchitecture override"
            echo "          -- would be aimed at the wrong CPU."
            return 0
        fi
    fi

    ARCH_VERDICT="ok"
    return 0
}
