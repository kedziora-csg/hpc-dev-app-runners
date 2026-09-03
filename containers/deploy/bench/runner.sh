#!/bin/bash
#-------------------------------------------------------------------------------
# runner.sh -- the sweep, with no site and no application in it.
#
# Sourced by nothing; RUN, either by a generated job script (bench/submit) or by
# the hand-qsub entry point (ncar-hpc/PBS/App_benchmarker_derecho.pbs).  Both do
# the same three things first -- source the site profile, bring up the modules,
# hand over -- so both get the same sweep.
#
# WHAT IT EXPECTS TO ALREADY BE TRUE
#
#   the site profile is sourced       NCAR_HPC_ROOT, BENCH_IMAGE_DIR,
#                                     BENCH_RESULTS_ROOT, BENCH_SITE are set
#   the module environment is up      bench_site_modules has run
#
# WHERE THE SWEEP COMES FROM
#
#   $BENCH_JOB_ENV, or $RESULTS_DIR/job.env    the expanded configuration
#                                              bench/submit wrote
#   nothing                                    a default three-cell sweep,
#                                              DERIVED from the probed topology
#
# The job never parses YAML.  job.env is flat `KEY='value'` lines because the
# expansion happened on the host, where there is a Python and a schema; here
# there is bash, and the only sane thing for bash to read is what it can source.
#
# THE CELLS
#
#   BENCH_CELL_COUNT                   how many
#   BENCH_CELL_<i>_NAME                the label its artifacts are named with
#   BENCH_CELL_<i>_RANKS_PER_NODE      the decomposition
#   BENCH_CELL_<i>_THREADS
#   BENCH_CELL_<i>_OMP                 the OMP variant's name
#   BENCH_CELL_<i>_OMP_PROC_BIND       and its settings
#   BENCH_CELL_<i>_OMP_PLACES
#
# A cell states only what it ASKS for.  What it should GET -- L3, NUMA and
# socket footprint, threads per core -- follows from the topology probed at the
# top of this job, so there is no expectation field for the checker to assert
# against.  That is what makes the verdict derived rather than declared, and it
# is why adding a cell needs no matching edit anywhere else.
#
# WHAT IT LEAVES BEHIND
#
# RESULTS_DIR is self-contained: reading it never requires this script, the
# experiment file, the job log, or knowing what was submitted.
#
#     results.jsonl            one JSON object per measured run
#     run.meta                 the job-level `# key value` header
#     job.env / job.json       what this job was asked to do (generated jobs)
#     topology.json            the node topology this job probed
#     modules.txt env.txt      the environment the run actually had
#     launcher.sh              the generated Apptainer launcher, verbatim
#     ldd_*_host.txt           linkage through the launcher, after the host
#                              libraries displace the container's
#     placement_<cell>.out     report_placement output, provenance header first
#     run_<cell>[_r<n>]/       the app's own cwd: inputs, app.out, metrics.kv
#
# Stdout carries only the narrative: each cell's geometry and placement verdict,
# its figure of merit, and anything that aborted it.  BENCH_VERBOSE=1 also echoes
# the captured files as they are written -- for bringing up a new site or a new
# app, where you are watching the job rather than reading it afterwards.  It
# changes what is displayed, never what is recorded.
#-------------------------------------------------------------------------------

#-------------------------------------------------------------------------------
# 1. The site profile must already be sourced.  This script does not look for
#    one: which profile is in force is a decision that belongs to whoever
#    submitted the job, and a runner that quietly found a different one would
#    produce results in a directory nobody is watching.
#-------------------------------------------------------------------------------
[ -d "${NCAR_HPC_ROOT:-}/libexec" ] || {
    echo "runner.sh: no site profile has been sourced." >&2
    echo "  NCAR_HPC_ROOT=${NCAR_HPC_ROOT:-<unset>}" >&2
    echo "  Run this through a generated job script (bench/submit) or through" >&2
    echo "  ncar-hpc/PBS/App_benchmarker_derecho.pbs; both source sites/<site>/site.sh" >&2
    echo "  first.  It is not meant to be qsub'd directly." >&2
    exit 1
}

# The profile again, because its FUNCTIONS did not survive getting here.
#
# job.tmpl and the hand-qsub script both source the profile and then `exec` this
# script.  Exported VARIABLES cross an exec; shell FUNCTIONS do not.  So
# NCAR_HPC_ROOT arrives and bench_site_mpi_overlay does not, and the first thing
# to notice is make_apptainer_launcher.sh refusing to load with "no site profile
# has been sourced" -- after the queue wait, in a job that had already printed
# its node list.  That is what the first Casper submission hit.
#
# Re-sourcing rather than `export -f` in the generated block: exported functions
# travel as environment entries with mangled names, are not portable across
# shells, and would make the profile's contents depend on how a job was started.
# Sourcing the file again is idempotent -- every assignment in it honours a value
# already set -- and it costs one read of a small file.
#
# Which file: BENCH_SITE_CONF when the caller exported it, which both entry
# points now do, so the job is driven by the same profile it was submitted with.
# Otherwise derived from the two variables that DID survive, which keeps
# runner.sh runnable by hand for debugging.
if ! command -v bench_site_mpi_overlay >/dev/null 2>&1; then
    _conf="${BENCH_SITE_CONF:-}"
    [ -n "${_conf}" ] || _conf="${NCAR_HPC_ROOT}/../sites/${BENCH_SITE:-}/site.sh"
    if [ -f "${_conf}" ]; then
        . "${_conf}" || { echo "runner.sh: cannot source ${_conf}" >&2; exit 1; }
    fi
    command -v bench_site_mpi_overlay >/dev/null 2>&1 || {
        echo "runner.sh: the site profile defines no bench_site_* functions." >&2
        echo "  tried: ${_conf}" >&2
        echo "  That block is generated -- run: bench/sitegen ${BENCH_SITE:-<site>} --write" >&2
        exit 1
    }
fi

#-------------------------------------------------------------------------------
# 2. This job's expanded configuration.
#-------------------------------------------------------------------------------
job_env="${BENCH_JOB_ENV:-}"
[ -n "${job_env}" ] || [ -z "${RESULTS_DIR:-}" ] || job_env="${RESULTS_DIR}/job.env"
if [ -n "${job_env}" ] && [ -f "${job_env}" ]; then
    . "${job_env}" || { echo "cannot source ${job_env}" >&2; exit 1; }
fi

APP="${APP:-}"
APP_ARGS="${APP_ARGS:-}"
BENCH_SCALE="${BENCH_SCALE:-node}"
BENCH_TARGET_SECONDS="${BENCH_TARGET_SECONDS:-60}"
BENCH_REPEATS="${BENCH_REPEATS:-1}"
RESULTS_DIR="${RESULTS_DIR:-${BENCH_RESULTS_ROOT}}"

# The nodefile is the authority on what the scheduler actually gave us, which is
# not necessarily what was asked for.
if [ -n "${PBS_NODEFILE:-}" ] && [ -f "${PBS_NODEFILE}" ]; then
    NNODES="$(sort -u "${PBS_NODEFILE}" | wc -l | tr -d '[:space:]')"
    nodes_list="$(sort -u "${PBS_NODEFILE}" | tr '\n' ' ' | sed 's/ *$//')"
else
    NNODES="${BENCH_NODES:-1}"
    nodes_list="$(hostname -s 2>/dev/null)"
fi

echo
[ -n "${APP}" ] || echo "app       <none: placement verification only>"
echo "nodes     ${NNODES}  (${nodes_list//.hpc.ucar.edu/})"
echo "results   ${RESULTS_DIR}"
[ -n "${BENCH_EXPERIMENT:-}" ] && \
    echo "job       ${BENCH_EXPERIMENT} / ${BENCH_JOB_KEY:-?}${BENCH_PROFILE:+ (profile ${BENCH_PROFILE})}"

# Create the output directory before generating helper scripts: the launcher
# lives there too, and this script later cd's into it.
mkdir -p "${RESULTS_DIR}" \
    || { echo "cannot create RESULTS_DIR=${RESULTS_DIR}"; exit 1; }

#-------------------------------------------------------------------------------
# 3. Libraries, all up front, before anything calls into them.
#
#   make_apptainer_launcher.sh  the host-MPI launcher and the mpiexec dialects
#   check_placement.sh          placement_summary / _verdict / _rules_fired
#   check_arch.sh               arch_check: the app binary against this CPU
#   results.sh                  the results.jsonl record; pulls in provenance.sh
#                               for emit_provenance, capture_run_context, the
#                               sub-second clock and the BENCH_VERBOSE helpers
#   app_contract.sh             app.yaml + the prepare/launch/extract hooks
#-------------------------------------------------------------------------------
for lib in make_apptainer_launcher.sh check_placement.sh check_arch.sh results.sh app_contract.sh; do
    . "${NCAR_HPC_ROOT}/libexec/${lib}" \
        || { echo "cannot source ${NCAR_HPC_ROOT}/libexec/${lib}" >&2; exit 1; }
done

# leap because openSUSE Leap 15 is built from the same SLE 15 SP6 sources as
# Derecho's host OS; oneapi because intel is the site default compiler family.
export container_img="${container_img:-${BENCH_IMAGE_DIR}/leap-oneapi-mpich.sif}"

comp_family="$(_launcher_sniff_compiler "${container_img}")"
mpi_family="${container_mpi:-$(_launcher_sniff_family "${container_img}")}"
img_tag="$(basename "${container_img}" .sif)"
img_os="${img_tag%%-*}"
echo "image     ${img_tag}.sif  (os=${img_os} compiler=${comp_family} mpi=${mpi_family})"
load_host_modules "${comp_family}" "${mpi_family}" || exit 1

launcher="${RESULTS_DIR}/apptainer-launch-${NCAR_HOST:-${BENCH_SITE}}-${mpi_family}.sh"
make_apptainer_launcher "${launcher}" "${container_img}" "${mpi_family}" || exit 1

REPORT_EXE="${REPORT_EXE:-/container/bin/report_placement}"

cd "${RESULTS_DIR}" || { echo "cannot use RESULTS_DIR=${RESULTS_DIR}"; exit 1; }

#-------------------------------------------------------------------------------
# 4. Topology.  Every threshold the placement rules use -- threads per core, the
#    minimum L3 / NUMA / socket groups a rank of N cores can occupy -- is derived
#    from this file, and the checker picks it up from the directory each report
#    lives in.  It is also the only record of what the run actually ran on.
#-------------------------------------------------------------------------------
probe_topology "${RESULTS_DIR}/topology.json" \
    || echo "topology probe failed; falling back to built-in Derecho constants"
# Explicitly, here, rather than as a side effect of the first placement check.
# check_placement.sh calls load_topology itself when it reads a report, so the
# TOPO_* variables used to appear only once the first cell had run -- and
# app_export_geometry, which hands an app its cache and NUMA geometry, is
# downstream of that.  Loading it up front removes the ordering dependency.
load_topology "${RESULTS_DIR}/topology.json"
[ "${TOPO_CORES_PER_NODE:-0}" -ge 1 ] 2>/dev/null || TOPO_CORES_PER_NODE=1
[ "${TOPO_SMT:-0}" -ge 1 ]            2>/dev/null || TOPO_SMT=1
vshow "${RESULTS_DIR}/topology.json" "node topology"
echo "topology  $(topology_line)"

capture_run_context "${RESULTS_DIR}" "${launcher}"

# Full linkage on disk; one line on stdout.  `_host` because this is the linkage
# seen THROUGH the launcher, after the host libraries displace the container's.
# If libmpi still resolves inside /container, every rank singleton-initialises
# and the job is N serial programs that look like a running job.
${launcher} ldd "${REPORT_EXE}" > ldd_report_placement_host.txt 2>&1
if grep -i 'libmpi' ldd_report_placement_host.txt | grep -qv '/container/'; then
    echo "host MPI  $(grep -i 'libmpi' ldd_report_placement_host.txt | head -1 | sed 's/^[[:space:]]*//')"
else
    echo "*** still linking the container's MPI -- see ldd_report_placement_host.txt ***"
    sed 's/^/    /' ldd_report_placement_host.txt
    exit 1
fi
vshow ldd_report_placement_host.txt "ldd ${REPORT_EXE}"

# The digest the .sif was built from.  Empty for an image built before
# libexec/Makefile started stamping it, which is recorded as null rather than
# guessed at.
img_digest="$(sif_digest "${container_img}")"
[ -n "${img_digest}" ] && echo "digest    ${img_digest}"

#-------------------------------------------------------------------------------
# 5. The cells.
#
# From job.env when there is one.  Otherwise a default sweep DERIVED from the
# topology just probed rather than hardcoded: one rank per core, one rank per
# L3, one rank per NUMA domain.  On Derecho that is exactly 128x1, 16x8 and
# 8x16; on any other node it is the same three ideas, correctly sized.
#-------------------------------------------------------------------------------
cell_name=() cell_ppn=() cell_threads=() cell_omp=() cell_bind=() cell_places=()

if [ "${BENCH_CELL_COUNT:-0}" -gt 0 ] 2>/dev/null; then
    i=0
    while [ "${i}" -lt "${BENCH_CELL_COUNT}" ]; do
        eval "cell_name+=(\"\${BENCH_CELL_${i}_NAME}\")"
        eval "cell_ppn+=(\"\${BENCH_CELL_${i}_RANKS_PER_NODE}\")"
        eval "cell_threads+=(\"\${BENCH_CELL_${i}_THREADS}\")"
        eval "cell_omp+=(\"\${BENCH_CELL_${i}_OMP:-}\")"
        eval "cell_bind+=(\"\${BENCH_CELL_${i}_OMP_PROC_BIND:-}\")"
        eval "cell_places+=(\"\${BENCH_CELL_${i}_OMP_PLACES:-}\")"
        i=$(( i + 1 ))
    done
else
    for spec in "pureMPI:1" "ccd:${TOPO_CORES_PER_L3}" "numa:${TOPO_CORES_PER_NUMA}"; do
        nm="${spec%%:*}" depth="${spec##*:}"
        [ "${depth:-0}" -ge 1 ] 2>/dev/null || continue
        cell_name+=("${nm}")
        cell_ppn+=($(( TOPO_CORES_PER_NODE / depth )))
        cell_threads+=("${depth}")
        cell_omp+=("${OMP_VARIANT:-default}")
        cell_bind+=("${OMP_PROC_BIND:-close}")
        cell_places+=("${OMP_PLACES:-cores}")
    done
fi
[ "${#cell_name[@]}" -gt 0 ] || { echo "no cells to run"; exit 1; }

#-------------------------------------------------------------------------------
# 6. The application's contract.  Everything this script knows about the app
#    comes from here; there is no branch on its name anywhere below.
#-------------------------------------------------------------------------------
app_name="" app_version="" app_override=false
if [ -n "${APP}" ]; then
    app_resolve "${APP}" "${launcher}" "${RESULTS_DIR}" || exit 1
    app_name="${APP_NAME}" app_version="${APP_VERSION}" app_override="${APP_DIR_OVERRIDE}"

    if ! ${launcher} test -x "${APP_BINARY}" 2>/dev/null; then
        echo "app       ${app_name}: ${APP_BINARY} is not executable in this image"
        echo "          build or pull an image that carries it (cd libexec && make derecho-<app>),"
        echo "          or point BENCH_APP_DIR at a contract on a bound filesystem"
        exit 1
    fi

    # The contract's declared binary.  What actually runs may differ -- a launch
    # hook can pick a different executable and add flags -- so this is labelled
    # as the contract rather than the command, and each cell records its real
    # argv in its provenance header.
    echo "app       ${app_name}${app_version:+ ${app_version}}  (contract: ${APP_BINARY})"
    [ "${app_override}" = true ] && \
        echo "          contract from ${APP_DIR} (override -- results are marked as such)"
    vshow "${RESULTS_DIR}/app.yaml" "app.yaml"

    # The app's own linkage, once per job rather than once per cell -- it cannot
    # change between cells, and the full ldd is a file, not forty lines of log.
    ${launcher} ldd "${APP_BINARY}" > "ldd_$(basename ${APP_BINARY})_host.txt" 2>&1 \
        || echo "note: cannot ldd ${APP_BINARY} (static, or not present)"
    vshow "ldd_$(basename ${APP_BINARY})_host.txt" "ldd ${APP_BINARY}"

    # Does this binary fit this CPU?  Once, here, before any node hours are
    # spent: an over-built binary otherwise reaches the first cell and dies with
    # SIGILL on every rank, which looks like an operating-system fault rather
    # than a build that targeted the wrong machine.  See libexec/check_arch.sh
    # for what this can and cannot see.
    arch_check "${launcher}" "${APP_BINARY}" "${RESULTS_DIR}/cpu_features.txt" || exit 1
fi

# Job-level provenance.  Per-cell facts go into each placement_<cell>.out header.
emit_provenance run.meta \
    experiment   "${BENCH_EXPERIMENT:-none}" \
    job_key      "${BENCH_JOB_KEY:-none}" \
    nodes        "${NNODES}" \
    image        "${container_img}" \
    image_digest "${img_digest:-unknown}" \
    image_os     "${img_os}" \
    compiler     "${comp_family}" \
    mpi_family   "${mpi_family}" \
    topology     "$(topology_line)" \
    app          "${app_name:-none}" \
    app_path     "${APP:-none}" \
    app_args     "${APP_ARGS:-none}" \
    app_scale    "${BENCH_SCALE}" \
    target_arch  "${BENCH_TARGET_ARCH:-unset}" \
    arch_verdict "${ARCH_VERDICT:-unchecked}" \
    repeats      "${BENCH_REPEATS}" \
    launcher     "${launcher}" \
    report_exe   "${REPORT_EXE}"
vshow run.meta "run.meta"

#-------------------------------------------------------------------------------
# 7. The sweep.
#
# The first run of a job pays the cold read of the .sif off GPFS and the first
# per-rank Apptainer startup.  That cost lands on whichever run happens to go
# first, so record it rather than let it silently penalise one configuration.
#-------------------------------------------------------------------------------
warm=false
summary=()

# The primary figure of merit, from the copy of app.yaml app_resolve left here.
# Nothing in this script knows what it means; it decides only which number goes
# on the summary line.
fom="$(sed -n 's/^primary_fom:[[:space:]]*//p' app.yaml 2>/dev/null | head -1)"

# min and median of a list of numbers.  Median, not mean: one cell that hit a
# noisy neighbour should not move the number the comparison is made on.
stats () {
    printf '%s\n' "$@" | sort -g | awk '
        { v[NR] = $1 }
        END {
            if (NR == 0) { print "- -"; exit }
            m = (NR % 2) ? v[(NR+1)/2] : (v[NR/2] + v[NR/2+1]) / 2
            printf "%s %g\n", v[1], m
        }'
}

# A record's fields that do not change between runs.  Written once here rather
# than repeated at both the skip and the measured path, where they would drift.
record_common () {
    result_reset
    result_set  site           "${BENCH_SITE}"
    result_set  job_id         "${PBS_JOBID:-none}"
    result_set  nodes          "${NNODES}"
    result_str  experiment     "${BENCH_EXPERIMENT:-}"
    result_str  job_key        "${BENCH_JOB_KEY:-}"
    result_str  image.sif      "${img_tag}.sif"
    result_set  image.digest   "${img_digest}"
    result_str  image.os       "${img_os}"
    result_set  image.compiler "${comp_family}"
    result_set  image.mpi      "${mpi_family}"
    result_set  app.name       "${app_name}"
    result_str  app.version    "${app_version}"
    result_str  app.scale      "${BENCH_SCALE}"
    result_set  app.app_dir_override "${app_override}"
    result_str  placement.name           "$1"
    result_set  placement.ranks_per_node "$2"
    result_set  placement.threads        "$3"
    result_str  placement.omp_variant    "$4"
}

idx=0
while [ "${idx}" -lt "${#cell_name[@]}" ]; do
    name="${cell_name[$idx]}"
    ppn="${cell_ppn[$idx]}"
    nthreads="${cell_threads[$idx]}"
    omp_name="${cell_omp[$idx]}"
    omp_bind="${cell_bind[$idx]}"
    omp_places="${cell_places[$idx]}"
    idx=$(( idx + 1 ))
    nranks=$(( NNODES * ppn ))

    # Set or UNSET, never inherited: a variant that leaves one of these blank
    # means "the implementation default", and silently carrying the previous
    # cell's value would label the row with a setting it did not run under.
    export OMP_NUM_THREADS="${nthreads}"
    if [ -n "${omp_bind}" ];   then export OMP_PROC_BIND="${omp_bind}"; else unset OMP_PROC_BIND; fi
    if [ -n "${omp_places}" ]; then export OMP_PLACES="${omp_places}";  else unset OMP_PLACES;  fi

    echo
    echo "=== ${name}: ${ppn} ranks/node x ${nthreads} threads (${nranks} ranks)${omp_name:+, omp=${omp_name}} ==="

    #---------------------------------------------------------------------------
    # Geometry, against the topology this node actually has.  bench/submit
    # already refused an illegal product on the host, using the site's declared
    # node -- but a job can also arrive here by hand, or land on a node unlike
    # the one the profile describes, and --cpu-bind depth packing from core 0
    # makes a wrong product look like a valid data point rather than an error.
    #---------------------------------------------------------------------------
    product=$(( ppn * nthreads ))
    legal_smt=$(( TOPO_CORES_PER_NODE * TOPO_SMT ))
    if [ "${product}" -ne "${TOPO_CORES_PER_NODE}" ] && \
       [ "${product}" -ne "${legal_smt}" ] && \
       [ "${BENCH_ALLOW_UNDERSUBSCRIBED:-false}" != true ]; then
        echo "    skipped: ${ppn} x ${nthreads} = ${product} on a ${TOPO_CORES_PER_NODE}-core node"
        echo "             (legal products: ${TOPO_CORES_PER_NODE}, or ${legal_smt} with SMT)"
        record_common "${name}" "${ppn}" "${nthreads}" "${omp_name}"
        result_set  skipped true
        result_str  skip_reason "ranks x threads = ${product}, not ${TOPO_CORES_PER_NODE} or ${legal_smt}"
        result_emit results.jsonl
        continue
    fi

    # Translate ranks/node + depth into this run's MPI dialect: Cray PALS
    # (mpich/mpich3) spells it -ppn N --cpu-bind core -d D; Open MPI has no
    # -ppn at all and spells the same request --map-by ppr:N:node:pe=D
    # --bind-to core.  See mpi_launch_flags in libexec/make_apptainer_launcher.sh.
    bound_flags="$(mpi_launch_flags "${mpi_family}" ${ppn} ${nthreads} bound)"

    #---------------------------------------------------------------------------
    # Placement first, always, and once per cell: it cannot change between
    # repeats of the same cell.  emit_provenance writes the header; the run
    # appends to it, so the .out explains itself without this script.
    #---------------------------------------------------------------------------
    out="placement_${name}.out"
    emit_provenance "${out}" \
        nodes          "${NNODES}" \
        image          "${container_img}" \
        image_digest   "${img_digest:-unknown}" \
        compiler       "${comp_family}" \
        mpi_family     "${mpi_family}" \
        config         "${name}" \
        omp_variant    "${omp_name:-none}" \
        ranks          "${nranks}" \
        ranks_per_node "${ppn}" \
        threads        "${nthreads}" \
        omp            "OMP_PROC_BIND=${OMP_PROC_BIND:-unset} OMP_PLACES=${OMP_PLACES:-unset}" \
        launcher       "${launcher}" \
        mpiexec        "mpiexec -n ${nranks} ${bound_flags} ${launcher} ${REPORT_EXE}"

    mpiexec -n ${nranks} ${bound_flags} \
        ${launcher} ${REPORT_EXE} >> "${out}" 2>&1

    placement_summary "${out}"
    place="$(placement_verdict "${out}")"

    [ -n "${APP}" ] || { warm=true; continue; }

    #---------------------------------------------------------------------------
    # The timed runs.  repeats:, because a single sample of a shared machine is
    # not a measurement.  Each gets its own private, empty directory: an app may
    # read and write relative to the cwd, so sharing one across runs would have
    # them overwrite each other.  That directory is $BENCH_RUNDIR, and it is the
    # only place a hook may write.
    #---------------------------------------------------------------------------
    scores=() walls=()
    repeat=1
    while [ "${repeat}" -le "${BENCH_REPEATS}" ]; do
        if [ "${BENCH_REPEATS}" -gt 1 ]; then rundir="run_${name}_r${repeat}"
        else                                  rundir="run_${name}"; fi
        rm -rf "${rundir}" && mkdir -p "${rundir}" || exit 1

        app_export_geometry "$(cd "${rundir}" && pwd)" \
            "${name}" "${NNODES}" "${nranks}" "${ppn}" "${nthreads}"

        # The app may DECLINE a geometry it cannot run -- eight ranks when it
        # needs a square number, say.  That is recorded and skipped, not fatal:
        # one refused cell must not cost the other cells their node hours.
        if ! app_prepare "${BENCH_RUNDIR}"; then
            skip="$(tail -3 "${rundir}/prepare.log" 2>/dev/null | tr '\n' ' ')"
            echo "    skipped: ${app_name} declined this geometry${skip:+ -- ${skip}}"
            record_common "${name}" "${ppn}" "${nthreads}" "${omp_name}"
            result_set  placement.verdict "${place}"
            result_set  repeat "${repeat}"
            result_set  skipped true
            result_str  skip_reason "${skip:-prepare declined this geometry}"
            result_emit results.jsonl
            break
        fi

        argv="$(app_argv)"
        # Append the resolved command to this cell's placement report, so the
        # .out says what ran rather than what the contract defaults to.
        [ "${repeat}" -eq 1 ] && \
            printf '# %-16s %s\n' app_argv "${argv} ${APP_ARGS}" >> "${out}"

        cd "${rundir}" || exit 1

        # date +%s.%N, not ${SECONDS}: one-second granularity quantises every
        # comparison between short cells.  wall_s is launch-to-exit and INCLUDES
        # per-rank Apptainer startup and the app's own setup phase, which for
        # some apps dwarfs the measured part -- prefer a figure of merit the app
        # reports itself, and treat this as the fallback.
        t0="$(wall_now)"
        mpiexec -n ${nranks} ${bound_flags} \
            ${launcher} ${argv} ${APP_ARGS} > app.out 2>&1
        rc=$?
        wall="$(wall_elapsed "${t0}")"

        # A failed run is the one case where the log must show the output,
        # because there is nothing else to say about it.
        if [ "${rc}" -ne 0 ]; then
            echo "    exit ${rc} -- last 20 lines of ${rundir}/app.out:"
            tail -20 app.out | sed 's/^/      /'
        fi
        vshow app.out "${rundir}/app.out"
        cd .. || exit 1

        # Figures of merit, as `key=value`, from the app's own extractor.  This
        # script does not know what any of them mean.
        app_extract "${BENCH_RUNDIR}" "${rundir}/metrics.kv"
        vshow "${rundir}/metrics.kv" "${rundir}/metrics.kv"

        #-----------------------------------------------------------------------
        # The record.  One line, appended -- a job killed at walltime keeps
        # every completed run and loses only the one that was going.
        #-----------------------------------------------------------------------
        record_common "${name}" "${ppn}" "${nthreads}" "${omp_name}"
        result_str  placement.mpiexec_flags  "${bound_flags}"
        result_set  placement.verdict        "${place}"
        result_set  placement.omp.OMP_PROC_BIND "${OMP_PROC_BIND:-}"
        result_set  placement.omp.OMP_PLACES    "${OMP_PLACES:-}"
        for fired in $(placement_rules_fired "${out}"); do result_rule "${fired}"; done
        result_set  repeat "${repeat}"
        result_set  repeats "${BENCH_REPEATS}"
        result_set  wall_s "${wall}"
        result_set  exit   "${rc}"
        result_set  warm   "${warm}"
        result_metrics_from_file "${rundir}/metrics.kv"
        result_emit results.jsonl

        score=""
        [ -n "${fom}" ] && \
            score="$(sed -n "s/^${fom}=//p" "${rundir}/metrics.kv" | tail -1)"
        [ -n "${score}" ] && scores+=("${score}")
        walls+=("${wall}")
        echo "    run ${repeat}/${BENCH_REPEATS}  wall=${wall}s  exit=${rc}${score:+  ${fom}=${score}}  placement=${place}"

        warm=true
        repeat=$(( repeat + 1 ))
    done

    # One summary line per cell: min and median of whichever number the app
    # declared as its figure of merit, else of the runner's own clock.
    if [ "${#scores[@]}" -gt 0 ]; then
        read -r lo mid <<< "$(stats "${scores[@]}")"
        summary+=("${name}|${ppn}x${nthreads}|${omp_name}|${fom}|${lo}|${mid}|${place}")
    elif [ "${#walls[@]}" -gt 0 ]; then
        read -r lo mid <<< "$(stats "${walls[@]}")"
        summary+=("${name}|${ppn}x${nthreads}|${omp_name}|wall_s|${lo}|${mid}|${place}")
    fi
done

#-------------------------------------------------------------------------------
# 8. The narrative summary.  The full record is results.jsonl; this is what a
#    person reads in the job log, and it is built from what the sweep just did
#    rather than from a flat file kept in parallel with it.
#-------------------------------------------------------------------------------
if [ "${#summary[@]}" -gt 0 ]; then
    echo
    echo "======================================================================="
    echo "SUMMARY  ${app_name:-${APP}}  on ${img_tag}  (${BENCH_REPEATS} repeat(s))"
    echo "======================================================================="
    printf "  %-10s %-9s %-8s %-10s %10s %10s %9s\n" \
        cell geometry omp metric min median placement
    for row in "${summary[@]}"; do
        IFS='|' read -r c g o m lo mid p <<< "${row}"
        printf "  %-10s %-9s %-8s %-10s %10s %10s %9s\n" \
            "${c}" "${g}" "${o:--}" "${m:--}" "${lo:--}" "${mid:--}" "${p:--}"
    done
    echo
    echo "  Median, not mean: one run that hit a noisy neighbour should not move"
    echo "  the number a comparison is made on.  The app's own figure of merit"
    echo "  decides, not wall time -- wall_s includes container startup and the"
    echo "  app's setup phase, which for some apps is most of it.  placement=fail"
    echo "  rows never win either way: a mis-bound run measures its binding, not"
    echo "  the code.  placement=warn is comparable -- the binding is suboptimal"
    echo "  but it is the binding that was measured, and the rule that fired is"
    echo "  named above."
fi

echo
echo "  results.jsonl written to ${RESULTS_DIR}"
_collect="${BENCH_HARNESS:-${BENCH_ROOT:-<checkout>/containers/deploy/bench}}/collect"
if [ -n "${BENCH_EXPERIMENT:-}" ]; then
    # One job of a sweep: the useful table is the whole experiment, which is the
    # directory above this one.
    echo "  tabulate the whole sweep with:  ${_collect} $(dirname "${RESULTS_DIR}") --best"
else
    echo "  tabulate with:  ${_collect} ${RESULTS_DIR} --best"
fi
echo
echo "Done at $(date)"
