#!/bin/bash
#-------------------------------------------------------------------------------
# gpu_bind.sh -- give a rank the GPU on its own NUMA domain.
#
# Sourced by the generated launcher on a node type with NVIDIA GPUs, once per
# rank, on the HOST side of `apptainer exec`: that is where mpiexec has already
# bound the rank to its cores and set its local-rank variable, and the container
# inherits whatever is exported here.
#
#     gpu_bind      export CUDA_VISIBLE_DEVICES as one GPU's UUID
#
# WHICH GPU
#
# The one on the NUMA domain of the rank's first core.  Not "local rank modulo
# the GPU count", which is what set_gpu_rank did: on a Derecho A100 node the
# GPUs' NUMA domains run in reverse of the cores', so that rule gives every rank
# the GPU furthest from it (GpuNodesPlan.md, step 0).  Ranks that share a NUMA
# domain share its GPU; a rank on a domain with no GPU of its own takes local
# rank modulo the count, and the log says so.
#
# FROM WHICH GPUs
#
# The job's own CUDA_VISIBLE_DEVICES, when it is set.  PBS sets it to the UUIDs
# of the GPUs it allocated, so a job on part of a node stays on its own GPUs.
# A UUID that is not on this node -- PALS hands every node the first node's
# list -- is dropped, and a node left with none falls back to all of its own.
# Each GPU is identified by UUID and bus ID, never by CUDA index, because CUDA's
# order is neither PCI's nor NUMA's.  A list of bare indices cannot be mapped
# without asking CUDA, so it is left exactly as it is, and so is an empty one,
# which is CUDA's way of hiding every GPU.
#
# Read from /proc/driver/nvidia and /sys, not nvidia-smi: a few small files per
# rank, where nvidia-smi costs a second each and 128 ranks would queue on it.
#
# CONTROLS
#
#     HPCRUN_GPU_BIND=none     leave CUDA_VISIBLE_DEVICES as the job has it
#     HPCRUN_GPU_BIND_LOG      a file each rank appends one line to, saying
#                              which GPU it got and why; the runner sets it
#                              for the placement run and reads it back
#     HPCRUN_GPU_BIND_ROOT     prefix for /proc and /sys, for the tests
#
# And, for the runner, reading those lines back:
#
#     gpu_bind_summary <log> [report_gpus output]
#         sets GPU_SUMMARY, one line saying what the ranks got, GPU_RANKS,
#         GPU_FAR (ranks whose GPU is on another NUMA domain) and
#         GPU_NO_KERNEL (ranks for which report_gpus did not print kernel=ok;
#         0 without its output).  Prints nothing: the caller wants the counts,
#         which a $(...) would lose.
#-------------------------------------------------------------------------------

gpu_bind () {
    local root="${HPCRUN_GPU_BIND_ROOT:-}"
    local d uuid bus numa cpus cpu node="" local_rank how chosen=""
    local -a uuids=() buses=() numas=() allow=()

    [ "${HPCRUN_GPU_BIND:-numa}" != none ] || { _gpu_bind_log "" "" "" "" off; return 0; }

    # This node's GPUs, in PCI order (the directory names are bus IDs).
    for d in "${root}"/proc/driver/nvidia/gpus/*; do
        [ -r "${d}/information" ] || continue
        bus="${d##*/}"
        uuid="$(sed -n 's/^GPU UUID:[[:space:]]*//p' "${d}/information")"
        numa="$(cat "${root}/sys/bus/pci/devices/${bus}/numa_node" 2>/dev/null)"
        [ -n "${uuid}" ] || continue
        uuids+=("${uuid}") buses+=("${bus}") numas+=("${numa:--1}")
    done
    [ "${#uuids[@]}" -gt 0 ] || { _gpu_bind_log "" "" "" "" no-gpus; return 0; }

    # Set and empty is CUDA's "no GPUs", and someone asked for it: kept, not
    # read as unset, which would hand the rank one.
    if [ -n "${CUDA_VISIBLE_DEVICES+set}" ] && [ -z "${CUDA_VISIBLE_DEVICES}" ]; then
        _gpu_bind_log "" "" "" "" hidden
        return 0
    fi

    # The job's GPUs, as indices into the lists above.
    if [ -n "${CUDA_VISIBLE_DEVICES:-}" ]; then
        for uuid in ${CUDA_VISIBLE_DEVICES//,/ }; do
            case "${uuid}" in
                GPU-*) ;;
                *) _gpu_bind_log "" "" "" "" "not-uuids:${CUDA_VISIBLE_DEVICES}"; return 0 ;;
            esac
            for d in "${!uuids[@]}"; do
                [ "${uuids[d]}" = "${uuid}" ] && allow+=("${d}")
            done
        done
    fi
    [ "${#allow[@]}" -gt 0 ] || allow=("${!uuids[@]}")

    # The rank's first core, and its NUMA domain.
    cpus="$(sed -n 's/^Cpus_allowed_list:[[:space:]]*//p' "${root}/proc/self/status" 2>/dev/null)"
    cpu="${cpus%%[,-]*}"
    for d in "${root}/sys/devices/system/cpu/cpu${cpu}"/node*; do
        [ -e "${d}" ] && node="${d##*/node}"
    done

    how=numa
    for d in "${allow[@]}"; do
        [ -n "${node}" ] && [ "${numas[d]}" = "${node}" ] && { chosen="${d}"; break; }
    done
    if [ -z "${chosen}" ]; then
        local_rank="${PMI_LOCAL_RANK:-${OMPI_COMM_WORLD_LOCAL_RANK:-${SLURM_LOCALID:-0}}}"
        chosen="${allow[$(( local_rank % ${#allow[@]} ))]}"
        how=modulo
    fi

    export CUDA_VISIBLE_DEVICES="${uuids[chosen]}"
    _gpu_bind_log "${cpu}" "${node}" "${buses[chosen]}" "${numas[chosen]}" "${how}"
}

# _gpu_bind_log <cpu> <numa> <gpu bus> <gpu numa> <how> -- one line, for a rank
# only: the launcher also runs ldd and test for the runner, outside mpiexec.
_gpu_bind_log () {
    local rank="${PMI_RANK:-${OMPI_COMM_WORLD_RANK:-${SLURM_PROCID:-}}}"
    [ -n "${HPCRUN_GPU_BIND_LOG:-}" ] && [ -n "${rank}" ] || return 0
    printf 'host=%s rank=%s cpu=%s numa=%s gpu=%s bus=%s gpu_numa=%s how=%s\n' \
        "$(hostname -s 2>/dev/null)" "${rank}" "${1:--}" "${2:--}" \
        "${CUDA_VISIBLE_DEVICES:--}" "${3:--}" "${4:--}" "$5" >> "${HPCRUN_GPU_BIND_LOG}"
}

gpu_bind_summary () {
    local log="$1" report="${2:-}" gpus far_list ok
    GPU_RANKS=0 GPU_FAR=0 GPU_NO_KERNEL=0
    GPU_SUMMARY="no rank reported a GPU binding (${log##*/} is empty)"
    [ -s "${log}" ] || return 1
    GPU_RANKS="$(wc -l < "${log}" | tr -d '[:space:]')"
    gpus="$(sed -n 's/.*host=\([^ ]*\).* gpu=\([^ ]*\) .*/\1 \2/p' "${log}" | sort -u | wc -l | tr -d '[:space:]')"
    # numa= and gpu_numa= differ: the rank's first core and its GPU are apart.
    far_list="$(awk '{ for (i = 1; i <= NF; i++) { split($i, kv, "="); f[kv[1]] = kv[2] }
                      if (f["how"] != "off" && f["numa"] != f["gpu_numa"]) printf "%s ", f["rank"] }' "${log}")"
    GPU_FAR="$(echo ${far_list} | wc -w | tr -d '[:space:]')"
    if [ -n "${report}" ]; then
        ok="$(grep -c 'kernel=ok' "${report}" 2>/dev/null)"
        GPU_NO_KERNEL=$(( GPU_RANKS - ${ok:-0} ))
        [ "${GPU_NO_KERNEL}" -ge 0 ] || GPU_NO_KERNEL=0
    fi
    GPU_SUMMARY="${GPU_RANKS} rank(s) on ${gpus} GPU(s)"
    if [ "${GPU_FAR}" -eq 0 ]; then GPU_SUMMARY="${GPU_SUMMARY}, each on its own NUMA domain"
    else GPU_SUMMARY="${GPU_SUMMARY}; WARNING rank(s) ${far_list}on a GPU of another NUMA domain"; fi
    [ -z "${report}" ] || GPU_SUMMARY="${GPU_SUMMARY}; kernel ran on $(( GPU_RANKS - GPU_NO_KERNEL ))/${GPU_RANKS}"
    return 0
}
