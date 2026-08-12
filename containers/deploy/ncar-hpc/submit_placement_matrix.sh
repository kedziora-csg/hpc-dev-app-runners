#!/bin/bash
#-------------------------------------------------------------------------------
# submit_placement_matrix.sh -- run the Derecho benchmark sweep.
#
# Submits ONE PBS job per container image, so each writes its own output file.
# That is why report_placement's csv: rows carry no image column: the image is
# identified by the filename, and --collate reattaches it.
#
# The set is the blessed Derecho deployment matrix (see libexec/Makefile):
#     leap x {oneapi, gcc14, nvhpc} x {mpich, openmpi} = 6
#
# USAGE
#     ./submit_placement_matrix.sh --account <PROJECT> [options]
#
#     --account CODE     PBS project to charge.  REQUIRED, no default.
#     --app hpcg|none    what to benchmark after the placement check
#                        (default: hpcg;  none = verify placement only)
#                        hpcg selects the *-hpcg.sif matrix and requires
#                        /container/bin/xhpcg to be preinstalled
#     --images "a b"     override the image list (space separated .sif names)
#     --nodes N          nodes per job (default 2)
#     --walltime HH:MM:SS  (default 00:30:00)
#     --dry-run          print the qsub commands, submit nothing
#     --collate          do not submit; summarise results already on disk
#
# TYPICAL SEQUENCE
#     cd libexec && make derecho-hpcg && cd ..   # build the six app .sif images
#     ./submit_placement_matrix.sh --account SCSG0001
#     ...wait for the jobs...
#     ./submit_placement_matrix.sh --collate
#-------------------------------------------------------------------------------

set -u

HERE="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
PBS_SCRIPT="${HERE}/PBS/Placement_derecho_opt.pbs"
RESULTS_DIR="${RESULTS_DIR:-${HERE}/results}"

ACCOUNT=""
APP="hpcg"
NODES=2
WALLTIME="00:30:00"
DRY_RUN=0
COLLATE=0
IMAGES=""

#-------------------------------------------------------------------------------
# The default set comes from the Makefile so there is ONE definition of "the six"
# rather than a copy that silently drifts.
#-------------------------------------------------------------------------------
default_images () {
    local from_make target
    target="echo-derecho"
    [ "${APP}" = "hpcg" ] && target="echo-derecho-hpcg"
    from_make="$(cd "${HERE}/libexec" && make --no-print-directory "${target}" 2>/dev/null)"
    if [ -n "${from_make}" ]; then
        echo "${from_make}"
    else
        echo "libexec/Makefile did not yield a derecho image list for APP=${APP}" >&2
        return 1
    fi
}

usage () { sed -n '2,/^#---/p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --account)  ACCOUNT="$2"; shift 2 ;;
        --app)      APP="$2"; shift 2 ;;
        --images)   IMAGES="$2"; shift 2 ;;
        --nodes)    NODES="$2"; shift 2 ;;
        --walltime) WALLTIME="$2"; shift 2 ;;
        --dry-run)  DRY_RUN=1; shift ;;
        --collate)  COLLATE=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[ -n "${IMAGES}" ] || IMAGES="$(default_images)" || exit 1

#-------------------------------------------------------------------------------
# Collate mode: summarise what is already on disk.  Runs anywhere, no PBS needed.
#-------------------------------------------------------------------------------
if [ "${COLLATE}" = "1" ]; then
    . "${HERE}/libexec/check_placement.sh"

    shopt -s nullglob
    reports=( "${RESULTS_DIR}"/*/placement_*.out )
    if [ ${#reports[@]} -eq 0 ]; then
        echo "no results under ${RESULTS_DIR}"
        echo "  (jobs write there; have they finished?)"
        exit 1
    fi

    printf "%-26s %-9s %-9s %8s %10s\n" IMAGE CONFIG PLACEMENT WALL_S GFLOPS
    printf "%-26s %-9s %-9s %8s %10s\n" \
        -------------------------- --------- --------- -------- ----------
    for r in "${reports[@]}"; do
        img="$(basename "$(dirname "${r}")")"
        cfg="$(basename "${r}" .out)"; cfg="${cfg#placement_}"
        # Expected L3 groups per rank: 1 unless the rank spans two chiplets.
        # 8 ranks x 16 threads takes 16 cores, and Milan puts 8 cores per L3.
        case "${cfg}" in
            numa) want=2 ;;
            *)    want=1 ;;
        esac
        check_placement_rc "${r}" "${want}" && verdict=PASS || verdict=FAIL
        t="$(dirname "${r}")/timings.txt"
        wall="$(awk -v c="${cfg}" '$1==c {print $2}' "${t}" 2>/dev/null | tail -1)"
        gf="$(awk -v c="${cfg}" '$1==c {print $4}' "${t}" 2>/dev/null | tail -1)"
        printf "%-26s %-9s %-9s %8s %10s\n" \
            "${img}" "${cfg}" "${verdict}" "${wall:--}" "${gf:--}"
    done
    echo
    echo "PLACEMENT=FAIL means the binding was not what the configuration asked"
    echo "for -- do not compare that row's numbers against the others."
    echo "GFLOPS is HPCG's own rating; blank for non-HPCG workloads."
    exit 0
fi

#-------------------------------------------------------------------------------
# Submit mode
#-------------------------------------------------------------------------------
if [ -z "${ACCOUNT}" ]; then
    echo "ERROR: --account is required (no default; this is a billable allocation)." >&2
    exit 2
fi
[ -f "${PBS_SCRIPT}" ] || { echo "missing ${PBS_SCRIPT}" >&2; exit 1; }

# Check every image up front rather than queueing jobs that cannot run.
missing=""
for img in ${IMAGES}; do
    [ -f "${HERE}/libexec/${img}" ] || missing="${missing} ${img}"
done
if [ -n "${missing}" ]; then
    echo "ERROR: these .sif images do not exist under libexec/:" >&2
    for m in ${missing}; do echo "    ${m}" >&2; done
    echo >&2
    if [ "${APP}" = "hpcg" ]; then
        echo "  build them with:  cd libexec && make derecho-hpcg" >&2
    else
        echo "  build them with:  cd libexec && make derecho" >&2
    fi
    exit 1
fi

echo "account  : ${ACCOUNT}"
echo "app      : ${APP}"
echo "nodes    : ${NODES}    walltime: ${WALLTIME}"
echo "results  : ${RESULTS_DIR}"
echo "images   :"; for img in ${IMAGES}; do echo "    ${img}"; done
echo

for img in ${IMAGES}; do
    tag="${img%.sif}"
    outdir="${RESULTS_DIR}/${tag}"

    # NCAR_HPC_ROOT tells the job where libexec/ and the images are; RESULTS_DIR
    # gives it a private directory to write into, so sibling jobs cannot collide
    # over report files, timings.txt or the generated launcher.  We deliberately
    # qsub from HERE (not from outdir) so PBS_O_WORKDIR stays meaningful.
    vars="NCAR_HPC_ROOT=${HERE}"
    vars="${vars},container_img=${HERE}/libexec/${img}"
    vars="${vars},RESULTS_DIR=${outdir}"
    [ "${APP}" = "none" ] || vars="${vars},APP=${APP}"

    cmd=(qsub
         -N "place_${tag}"
         -A "${ACCOUNT}"
         -l "select=${NODES}:ncpus=128:mpiprocs=128:ompthreads=1"
         -l "walltime=${WALLTIME}"
         -v "${vars}"
         "${PBS_SCRIPT}")

    if [ "${DRY_RUN}" = "1" ]; then
        echo "  qsub -N place_${tag} -A ${ACCOUNT} \\"
        echo "       -l select=${NODES}:ncpus=128:mpiprocs=128:ompthreads=1 \\"
        echo "       -l walltime=${WALLTIME} \\"
        echo "       -v '${vars}' \\"
        echo "       ${PBS_SCRIPT}"
    else
        mkdir -p "${outdir}"
        ( cd "${HERE}" && "${cmd[@]}" ) \
            && echo "  submitted: ${tag}" \
            || echo "  FAILED to submit: ${tag}"
    fi
done

echo
if [ "${DRY_RUN}" = "1" ]; then
    echo "(dry run -- nothing submitted)"
else
    echo "when the jobs finish:  $0 --collate"
fi
