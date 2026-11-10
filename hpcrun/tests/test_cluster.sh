#!/bin/bash
#-------------------------------------------------------------------------------
# test_cluster.sh -- the shell that consumes a cluster profile, with no cluster.
#
#     ./test_cluster.sh
#
# What this covers is the seam phase 4 introduced: the site and cluster YAMLs
# together are the only statement of a machine's binds, library path, module
# maps and MPI recipes, and make_apptainer_launcher.sh / probe_topology.sh read
# them from the profile hpcrun/sitegen generates.  Before, those values were literals in the shell; the
# risk now is different and worth testing for directly:
#
#   the launcher is still correct   the same binds, the same LD_LIBRARY_PATH
#                                   order, the same mpiexec flags as when they
#                                   were written into the file
#   a missing profile FAILS         rather than falling back to Derecho's paths
#                                   on a machine that is not Derecho, which is
#                                   the whole reason there are no defaults
#   an unsupported family FAILS     a cluster that lists no mpich cannot host an
#                                   mpich image, and says so
#   ${VAR} entries stay literal     a lib_dirs entry naming a module's variable
#                                   must survive the profile being sourced
#
# It runs against a SYNTHETIC profile, not against Derecho's, so it asserts
# behaviour rather than restating Derecho's values -- a test that copied them
# would pass whatever they became.
#-------------------------------------------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
pass=0 fail=0

ok   () { echo "  ok    $1"; pass=$((pass + 1)); }
bad  () { echo "  FAIL  $1"; shift; [ $# -gt 0 ] && printf '        %s\n' "$@"; fail=$((fail + 1)); }
want () { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected: $2" "got:      $3"; fi }

echo "cluster profile consumers"
echo

#-- a synthetic machine, with real directories so the existence tests bite -----
mkdir -p "${TMP}/fs"/{bound,optional,libs,usrlib,mpi/lib,cray/lib-abi-mpich,vers/9.9/lib}
: > "${TMP}/fs/image.sif"

cat > "${TMP}/cluster.sh" <<EOF
HPCRUN_SITE='ncar'
HPCRUN_CLUSTER='testville'
HPCRUN_CONTAINER_RUNTIME='apptainer'
HPCRUN_BINDS='${TMP}/fs/bound'
HPCRUN_BINDS_IF_PRESENT='${TMP}/fs/optional ${TMP}/fs/absent'
HPCRUN_BIND_MAP='${TMP}/fs/usrlib:/host_lib64'
HPCRUN_LIB_DIRS='${TMP}/fs/libs ${TMP}/fs/vers/*/lib \${TEST_MODULE_ROOT}/lib ${TMP}/fs/absent'
HPCRUN_CORES_PER_NODE='64'
HPCRUN_SMT='2'
HPCRUN_SOCKETS='2'
HPCRUN_SMT_STRIDE='64'
HPCRUN_CORES_PER_L3='4'
HPCRUN_CORES_PER_NUMA='8'
bench_site_compiler_module () { case "\$1" in oneapi) echo 'intel' ;; *) echo '' ;; esac; }
bench_site_mpi_module    () { case "\$1" in openmpi) echo 'openmpi' ;; *) echo '' ;; esac; }
bench_site_mpi_unload    () { case "\$1" in mpich) echo 'openmpi' ;; *) echo '' ;; esac; }
bench_site_mpi_launcher  () { case "\$1" in mpich) echo 'pals' ;; openmpi) echo 'openmpi' ;; *) echo '' ;; esac; }
bench_site_mpi_overlay   () { case "\$1" in mpich) echo 'cray-mpich-abi' ;; openmpi) echo 'host-openmpi' ;; *) echo '' ;; esac; }
bench_site_mpi_env       () { case "\$1" in mpich) echo 'A=1 B=two' ;; *) echo '' ;; esac; }
EOF

# One subshell per case: sourcing a profile and a library is exactly what a job
# does, and leaking either between cases would let one case pass on another's
# state.
run () { bash -c "
    set -u
    . '${TMP}/cluster.sh'
    export TEST_MODULE_ROOT='${TMP}/fs/mpi'
    export CRAY_MPICH_DIR='${TMP}/fs/cray'
    . '${HERE}/../lib/make_apptainer_launcher.sh'
    $1" 2>&1; }

#-- the launcher ---------------------------------------------------------------
echo "launcher"

out="$(run "make_apptainer_launcher '${TMP}/out.sh' '${TMP}/fs/image.sif' mpich && cat '${TMP}/out.sh'")"

echo "${out}" | grep -q -- "--bind ${TMP}/fs/bound" \
    && ok "an unconditional bind is emitted" \
    || bad "the unconditional bind is missing" "${out}"

echo "${out}" | grep -q -- "--bind ${TMP}/fs/optional" \
    && ok "a conditional bind is emitted when the directory exists" \
    || bad "the conditional bind is missing"

echo "${out}" | grep -q -- "--bind ${TMP}/fs/absent" \
    && bad "a conditional bind was emitted for a directory that does not exist" \
    || ok "a conditional bind is dropped when the directory does not exist"

echo "${out}" | grep -q -- "--bind ${TMP}/fs/usrlib:/host_lib64" \
    && ok "a remapped bind keeps its container-side name" \
    || bad "the remapped bind is wrong"

# The order is load-bearing: the overlay's own directory must come first, or the
# container's libmpi is found before the host's and every rank singleton
# initialises into its own MPI_COMM_WORLD.
path="$(echo "${out}" | sed -n 's/.*LD_LIBRARY_PATH=\([^ ]*\).*/\1/p')"
case "${path}" in
    "${TMP}/fs/cray/lib-abi-mpich":*) ok "the MPI overlay's directory comes first" ;;
    *) bad "the overlay directory is not first" "LD_LIBRARY_PATH=${path}" ;;
esac

case "${path}" in
    *"${TMP}/fs/vers/9.9/lib"*) ok "a * entry resolves to a real directory" ;;
    *) bad "the glob entry did not resolve" "LD_LIBRARY_PATH=${path}" ;;
esac

case "${path}" in
    *"${TMP}/fs/mpi/lib"*) ok "a \${VAR} entry expands from the environment" ;;
    *) bad "the \${VAR} entry did not expand" "LD_LIBRARY_PATH=${path}" ;;
esac

case "${path}" in
    *"${TMP}/fs/absent"*) bad "a nonexistent directory reached LD_LIBRARY_PATH" ;;
    *) ok "a nonexistent directory is dropped, not left empty" ;;
esac

case "${path}" in
    *:/host_lib64) ok "the remapped path is appended last" ;;
    *) bad "the remapped container path is not at the end" "LD_LIBRARY_PATH=${path}" ;;
esac

echo "${out}" | grep -q -- "--env A=1" && echo "${out}" | grep -q -- "--env B=two" \
    && ok "the family's env: entries become --env flags" \
    || bad "the family env is missing from the launcher"

# A generated script that does not parse is a job that dies on every rank with
# a shell error, which reads as an MPI problem.
run "make_apptainer_launcher '${TMP}/out.sh' '${TMP}/fs/image.sif' mpich" >/dev/null 2>&1
bash -n "${TMP}/out.sh" && ok "the generated launcher parses" \
                        || bad "the generated launcher has a syntax error" "$(cat "${TMP}/out.sh")"

#-- the mpiexec dialects -------------------------------------------------------
echo
echo "launch flags"
want "pals bound"      "-ppn 16 --cpu-bind core -d 8" "$(run "mpi_launch_flags mpich 16 8 bound")"
want "pals trap"       "-ppn 128"                     "$(run "mpi_launch_flags mpich 128 1 trap")"
want "openmpi bound"   "--map-by ppr:16:node:pe=8 --bind-to core" \
                       "$(run "mpi_launch_flags openmpi 16 8 bound")"
want "openmpi trap"    "-N 16"                        "$(run "mpi_launch_flags openmpi 16 1 trap")"

run "mpi_launch_flags nosuch 1 1 bound" >/dev/null 2>&1
want "a family the cluster does not list is refused" 1 "$?"

#-- refusing, rather than guessing ----------------------------------------------
echo
echo "no profile, no defaults"

# The point of generating cluster.sh rather than keeping literals in the shell:
# a machine with no profile must fail, not quietly run with another machine's
# paths.
bash -c "set -u; . '${HERE}/../lib/make_apptainer_launcher.sh'" >/dev/null 2>&1
want "sourcing the launcher without a cluster profile fails" 1 "$?"

out="$(run "bench_site_mpi_overlay () { echo ''; }
            make_apptainer_launcher '${TMP}/o2.sh' '${TMP}/fs/image.sif' mpich")"
case "${out}" in
    *"cannot host MPI family"*) ok "an unsupported MPI family is refused by name" ;;
    *) bad "an unsupported family was not refused clearly" "${out}" ;;
esac

#-- topology falls back to the profile, and says that it did --------------------
echo
echo "topology fallback"
topo () { bash -c "
    set -u
    ${1}
    . '${HERE}/../lib/probe_topology.sh'
    _topo_set_fallback
    echo \"\${TOPO_CORES_PER_NODE} \${TOPO_SMT} \${TOPO_CORES_PER_L3} \${TOPO_SOURCE}\""; }

want "the fallback comes from the profile" "64 2 4 fallback:site-profile:testville" \
     "$(topo ". '${TMP}/cluster.sh'")"

# Not Derecho's 128: with nothing to go on the fallback must describe a machine
# no real placement fits, so the caller notices instead of accepting a geometry
# the node cannot run.
want "with no profile the fallback invents nothing" "1 1 1 fallback:none" "$(topo "true")"

#-- memory and GPUs, for an app that sizes its problem ---------------------------
echo
echo "topology probe: memory and GPUs"
# A Derecho A100 node's /proc and /sys, with a cgroup limit below MemTotal, and
# an nvidia-smi that answers for the first GPU.
P="${TMP}/probe"
mkdir -p "${P}/proc/self" "${P}/sys/fs/cgroup/memory/pbs_jobs.service/jobid/1.desched1"
printf 'MemTotal:       527608240 kB\n' > "${P}/proc/meminfo"
printf '12:memory:/pbs_jobs.service/jobid/1.desched1\n0::/x\n' > "${P}/proc/self/cgroup"
echo 515396075520 > "${P}/sys/fs/cgroup/memory/pbs_jobs.service/jobid/1.desched1/memory.limit_in_bytes"
for spec in 0000:03:00.0:3 0000:41:00.0:2 0000:81:00.0:1 0000:c1:00.0:0; do
    bus="${spec%:*}"
    mkdir -p "${P}/proc/driver/nvidia/gpus/${bus}" "${P}/sys/bus/pci/devices/${bus}"
    printf 'Model: \t\t NVIDIA A100-SXM4-40GB\nBus Location: \t %s\n' "${bus}" \
        > "${P}/proc/driver/nvidia/gpus/${bus}/information"
    echo "${spec##*:}" > "${P}/sys/bus/pci/devices/${bus}/numa_node"
done
printf '#!/bin/sh\nprintf "40960\\n40960\\n"\n' > "${TMP}/smi"; chmod +x "${TMP}/smi"
probe () { HPCRUN_PROBE_ROOT="$1" HPCRUN_PROBE_NVIDIA_SMI="${TMP}/smi" bash -c "
    . '${HERE}/../lib/probe_topology.sh'
    echo \"\$(_probe_mem_mb) \$(_probe_gpus)\""; }
want "memory is the cgroup's limit, and the GPUs with their NUMA domains" \
     "491520 4 NVIDIA_A100-SXM4-40GB 40960 3,2,1,0" "$(probe "${P}")"
echo 9223372036854771712 > "${P}/sys/fs/cgroup/memory/pbs_jobs.service/jobid/1.desched1/memory.limit_in_bytes"
want "an unlimited cgroup leaves MemTotal" "515242 4" "$(probe "${P}" | cut -d' ' -f1,2)"
# cgroup v2, a job step whose own memory.max is `max` under a job that sets
# one: the job's limit holds, and is what the step may use.
C2="${TMP}/probe-v2"
mkdir -p "${C2}/proc/self" "${C2}/sys/fs/cgroup/pbs/job/step"
cp "${P}/proc/meminfo" "${C2}/proc/"
printf '0::/pbs/job/step\n' > "${C2}/proc/self/cgroup"
echo max > "${C2}/sys/fs/cgroup/pbs/job/step/memory.max"
echo 8589934592 > "${C2}/sys/fs/cgroup/pbs/job/memory.max"
want "a limit on a parent cgroup holds for its child" "8192" \
     "$(probe "${C2}" | cut -d' ' -f1)"
mkdir -p "${TMP}/cpuonly/proc"; cp "${P}/proc/meminfo" "${TMP}/cpuonly/proc/"
want "a node without GPUs says none" "515242 0 - 0 -" "$(probe "${TMP}/cpuonly")"
# The geometry the hooks are handed.  One GPU a rank while the runner binds;
# every GPU with the binding off; none on a CPU node.
geom () { bash -c "
    . '${HERE}/../lib/probe_topology.sh'; . '${HERE}/../lib/app_contract.sh'
    $1
    app_export_geometry /r numa 1 4 4 16
    echo \"\${HPCRUN_MEM_PER_NODE_MB:-} \${HPCRUN_GPUS_PER_NODE} \${HPCRUN_GPUS_PER_RANK} \${HPCRUN_GPU_MEM_MB:-}\""; }
want "the hooks get memory, GPUs a node, GPUs a rank and GPU memory" "491520 4 1 40960" \
     "$(geom 'TOPO_MEM_PER_NODE_MB=491520 TOPO_GPUS=4 TOPO_GPU_MEM_MB=40960')"
want "with the binding off a rank sees every GPU" "4 4" \
     "$(geom 'TOPO_GPUS=4 HPCRUN_GPU_BIND=none' | cut -d' ' -f2,3)"
want "a CPU node: no GPUs, and unknowns are empty" " 0 0 " "$(geom 'TOPO_GPUS=0')"
# What a rank sees follows CUDA_VISIBLE_DEVICES where gpu_bind leaves it alone.
want "PBS's UUIDs: the binding gives a rank one" "1" \
     "$(geom 'TOPO_GPUS=4 CUDA_VISIBLE_DEVICES=GPU-a,GPU-b,GPU-c,GPU-d' | cut -d' ' -f3)"
want "a list of indices, left as it is: a rank sees all of it" "2" \
     "$(geom 'TOPO_GPUS=4 CUDA_VISIBLE_DEVICES=2,3' | cut -d' ' -f3)"
want "with the binding off, the job's list and not the node's count" "2" \
     "$(geom 'TOPO_GPUS=4 HPCRUN_GPU_BIND=none CUDA_VISIBLE_DEVICES=GPU-a,GPU-b' | cut -d' ' -f3)"
want "an empty list hides every GPU" "0" \
     "$(geom 'TOPO_GPUS=4 CUDA_VISIBLE_DEVICES=' | cut -d' ' -f3)"
# A probe that found no GPUs is believed over a profile that says four.
mkdir -p "${TMP}/zero" "${TMP}/old"
printf '{\n  "cores_per_node": 64,\n  "gpus": 0\n}\n' > "${TMP}/zero/topology.json"
want "a probed 0 GPUs overrides the profile's count" "0" \
     "$(bash -c ". '${HERE}/../lib/probe_topology.sh'; HPCRUN_GPUS_PER_NODE=4
                 load_topology '${TMP}/zero/topology.json'; echo \${TOPO_GPUS}")"
printf '{\n  "cores_per_node": 64\n}\n' > "${TMP}/old/topology.json"
want "a topology.json without the key keeps the profile's" "4" \
     "$(bash -c ". '${HERE}/../lib/probe_topology.sh'; HPCRUN_GPUS_PER_NODE=4
                 load_topology '${TMP}/old/topology.json'; echo \${TOPO_GPUS}")"

#-- a node type with NVIDIA GPUs -----------------------------------------------
echo
echo "GPU node type"
# Cray's layout: GTL beside the ofi/ builds, not in either library directory.
mkdir -p "${TMP}/fs/gtl/gtl/lib" "${TMP}/fs/gtl/ofi/gnu/12.3/lib-abi-mpich"
: > "${TMP}/fs/gtl/gtl/lib/libmpi_gtl_cuda.so.0"
gpu_run () { run "export HPCRUN_GPU_VENDOR=nvidia CRAY_MPICH_DIR='${TMP}/fs/gtl/ofi/gnu/12.3'
                  $1"; }

out="$(gpu_run "make_apptainer_launcher '${TMP}/g.sh' '${TMP}/fs/image.sif' mpich && cat '${TMP}/g.sh'")"
echo "${out}" | grep -q -- '^    --nv \\$' \
    && ok "--nv on a node type with NVIDIA GPUs" || bad "no --nv for NVIDIA GPUs" "${out}"
echo "${out}" | grep -q "gpu_bind.sh' && gpu_bind$" \
    && ok "each rank is bound to a GPU before the exec" || bad "no gpu_bind in the launcher" "${out}"
echo "${out}" | grep -q "^export APPTAINERENV_LD_PRELOAD='${TMP}/fs/gtl/gtl/lib/libmpi_gtl_cuda.so.0'" \
    && ok "Cray MPICH's GTL library is preloaded inside the container" \
    || bad "no GTL preload" "${out}"
echo "${out}" | grep -q 'MPICH_GPU_SUPPORT_ENABLED' \
    && bad "GPU support was switched on for every app" "${out}" \
    || ok "MPICH_GPU_SUPPORT_ENABLED is left to the app"
bash -n "${TMP}/g.sh" && ok "the GPU launcher parses" || bad "the GPU launcher has a syntax error"

out="$(run "make_apptainer_launcher '${TMP}/c.sh' '${TMP}/fs/image.sif' mpich && cat '${TMP}/c.sh'")"
echo "${out}" | grep -qE -- '--nv|gpu_bind|LD_PRELOAD' \
    && bad "a CPU node type got GPU settings" "${out}" \
    || ok "a CPU node type gets none of them"

out="$(gpu_run "make_apptainer_launcher '${TMP}/g2.sh' '${TMP}/fs/image.sif' openmpi")"
case "${out}" in
    *GTL*) bad "the GTL library was asked of the Open MPI recipe" "${out}" ;;
    *)     ok "GTL belongs to the Cray MPICH recipe only" ;;
esac

out="$(run "export HPCRUN_GPU_VENDOR=nvidia
            make_apptainer_launcher '${TMP}/g3.sh' '${TMP}/fs/image.sif' mpich")"
want "a GPU node type whose Cray MPICH has no GTL library is refused" 1 "$?"

# The variant's preload is kept, after GTL's: one list, never one written over
# the other.  A stub apptainer shows what the container would be given.
mkdir -p "${TMP}/stubrt"
cat > "${TMP}/stubrt/apptainer" <<'RT'
#!/bin/bash
echo "PRELOAD=${APPTAINERENV_LD_PRELOAD:-} CVD=${CUDA_VISIBLE_DEVICES:-}"
echo "ARGS=$*"
RT
chmod +x "${TMP}/stubrt/apptainer"
out="$(PATH="${TMP}/stubrt:${PATH}" APPTAINERENV_LD_PRELOAD=/mkl.so HPCRUN_GPU_BIND=none \
       "${TMP}/g.sh" true)"
case "${out}" in
    *"PRELOAD=${TMP}/fs/gtl/gtl/lib/libmpi_gtl_cuda.so.0:/mkl.so "*) ok "a variant's preload follows GTL's" ;;
    *) bad "the preloads were not joined" "${out}" ;;
esac

# PALS_SPOOL_DIR holds the apinfo file PMI_Init reads.  Bound when no site bind
# covers it; left alone when one does.
out="$(PATH="${TMP}/stubrt:${PATH}" PALS_SPOOL_DIR="${TMP}/fs/bound/spool" "${TMP}/c.sh" true)"
case "${out}" in
    *"--bind ${TMP}/fs/bound/spool "*) bad "a spool directory already under a bind was bound again" "${out}" ;;
    *) ok "a spool directory under a site bind is not bound again" ;;
esac
mkdir -p "${TMP}/spool"
out="$(PATH="${TMP}/stubrt:${PATH}" PALS_SPOOL_DIR="${TMP}/spool" "${TMP}/c.sh" true)"
case "${out}" in
    *"--bind ${TMP}/spool "*) ok "a spool directory outside every bind is bound" ;;
    *) bad "the PALS spool directory was not bound" "${out}" ;;
esac

#-- host libraries the host MPI needs -------------------------------------------
echo
echo "host MPI preload"
# Derecho's libxpmem, under a ${VAR} to show the expansion.  The family's own
# library comes first, then GTL's, then a variant's.
mkdir -p "${TMP}/fs/optional/xpmem"
: > "${TMP}/fs/optional/xpmem/libxpmem.so.0"
mpi_preload="bench_site_mpi_preload () { case \"\$1\" in mpich) echo '\${XPMEM_TEST}/libxpmem.so.0' ;; *) echo '' ;; esac; }
             export XPMEM_TEST='${TMP}/fs/optional/xpmem'"

out="$(run "${mpi_preload}
            make_apptainer_launcher '${TMP}/x.sh' '${TMP}/fs/image.sif' mpich && cat '${TMP}/x.sh'")"
echo "${out}" | grep -q "^export APPTAINERENV_LD_PRELOAD='${TMP}/fs/optional/xpmem/libxpmem.so.0'\"" \
    && ok "a family's preload reaches a CPU node type's launcher, \${VAR} expanded" \
    || bad "no preload for the family" "${out}"
bash -n "${TMP}/x.sh" && ok "that launcher parses" || bad "that launcher has a syntax error"

out="$(gpu_run "${mpi_preload}
                make_apptainer_launcher '${TMP}/xg.sh' '${TMP}/fs/image.sif' mpich")"
out="$(PATH="${TMP}/stubrt:${PATH}" APPTAINERENV_LD_PRELOAD=/mkl.so HPCRUN_GPU_BIND=none \
       "${TMP}/xg.sh" true)"
case "${out}" in
    *"PRELOAD=${TMP}/fs/optional/xpmem/libxpmem.so.0:${TMP}/fs/gtl/gtl/lib/libmpi_gtl_cuda.so.0:/mkl.so "*)
        ok "the family's preload, then GTL's, then a variant's" ;;
    *)  bad "the three preloads were not joined in order" "${out}" ;;
esac

out="$(run "${mpi_preload}
            bench_site_mpi_root () { echo '\${TEST_MODULE_ROOT}'; }
            make_apptainer_launcher '${TMP}/xo.sh' '${TMP}/fs/image.sif' openmpi && cat '${TMP}/xo.sh'")"
case "${out}" in
    *LD_PRELOAD*)          bad "the mpich family's preload reached an Open MPI launcher" "${out}" ;;
    *"generated by make_apptainer_launcher"*) ok "another family gets none of it" ;;
    *)                     bad "no Open MPI launcher to look at" "${out}" ;;
esac

out="$(run "${mpi_preload}
            export XPMEM_TEST='${TMP}/fs/absent'
            make_apptainer_launcher '${TMP}/xm.sh' '${TMP}/fs/image.sif' mpich")"
want "a family whose preload is missing is refused" 1 "$?"

# Every ${NAME} of an entry, wherever it is; and a file no site bind exposes is
# bound by itself, or the loader would not find it in the container.
mkdir -p "${TMP}/elsewhere/v2/lib64"
: > "${TMP}/elsewhere/v2/lib64/libxpmem.so.0"
out="$(run "bench_site_mpi_preload () { echo '\${XP_ROOT}/\${XP_VER}/lib64/libxpmem.so.0'; }
            export XP_ROOT='${TMP}/elsewhere' XP_VER=v2
            make_apptainer_launcher '${TMP}/xv.sh' '${TMP}/fs/image.sif' mpich && cat '${TMP}/xv.sh'")"
echo "${out}" | grep -q "^export APPTAINERENV_LD_PRELOAD='${TMP}/elsewhere/v2/lib64/libxpmem.so.0'\"" \
    && ok "a preload with two \${VAR}s, both expanded" || bad "a \${VAR} was left in the preload" "${out}"
echo "${out}" | grep -q -- "--bind ${TMP}/elsewhere/v2/lib64/libxpmem.so.0 " \
    && ok "a preload outside every site bind is bound by itself" \
    || bad "the uncovered preload was not bound" "${out}"
out="$(cat '${TMP}/x.sh' 2>/dev/null)"
case "${out}" in
    *"--bind ${TMP}/fs/optional/xpmem/libxpmem.so.0"*) bad "a preload under a site bind was bound again" "${out}" ;;
    *) ok "a preload under a site bind is not bound again" ;;
esac

#-- host software an app requires, and GPU-aware MPI ----------------------------
echo
echo "host software"
# One install per MPI family, as NVIDIA ships its benchmarks, under a ${VAR} to
# show the expansion, and bound at a mount; and one under a site bind, at its
# own path, with library directories.
mkdir -p "${TMP}/fs/nv/bench_mpich/lib" "${TMP}/fs/bound/comm/nccl/lib" "${TMP}/fs/bound/comm/nvshmem/lib"
host_sw="bench_site_host_software_path () { case \"\$1\" in
                 bench) echo '\${NV_TEST}/bench_\${mpi}' ;;
                 comm)  echo '${TMP}/fs/bound/comm' ;; *) echo '' ;; esac; }
         bench_site_host_software_mount () { case \"\$1\" in bench) echo '/opt/bench' ;; *) echo '' ;; esac; }
         bench_site_host_software_lib_dirs () { case \"\$1\" in
                 bench) echo 'lib' ;; comm) echo 'nccl/lib nvshmem/lib absent/lib' ;; *) echo '' ;; esac; }
         export NV_TEST='${TMP}/fs/nv'"
out="$(run "${host_sw}
            HPCRUN_REQUIRES_HOST_SOFTWARE='bench comm'
            make_apptainer_launcher '${TMP}/h.sh' '${TMP}/fs/image.sif' mpich && cat '${TMP}/h.sh'
            echo \"HS=\${LAUNCHER_HOST_SOFTWARE}\"")"
echo "${out}" | grep -q -- "--bind ${TMP}/fs/nv/bench_mpich:/opt/bench" \
    && ok "an install is bound at its mount, \${mpi} and \${VAR} expanded" \
    || bad "the install was not bound at its mount" "${out}"
echo "${out}" | grep -q -- "--bind ${TMP}/fs/bound/comm" \
    && bad "an install under a site bind was bound again" "${out}" \
    || ok "an install under a site bind is not bound again"
echo "${out}" | grep -q -- "LD_LIBRARY_PATH=${TMP}/fs/cray/lib-abi-mpich:/opt/bench/lib:${TMP}/fs/bound/comm/nccl/lib:${TMP}/fs/bound/comm/nvshmem/lib:${TMP}/fs/libs" \
    && ok "its lib_dirs follow the MPI's and precede the site's; an absent one is dropped" \
    || bad "the library path is not overlay, host software, site" "${out}"
want "the launcher says what it bound" "HS=bench=${TMP}/fs/nv/bench_mpich comm=${TMP}/fs/bound/comm" \
     "$(echo "${out}" | grep '^HS=')"
bash -n "${TMP}/h.sh" && ok "the launcher with host software parses" || bad "syntax error with host software"
out="$(run "${host_sw}
            export NV_TEST='${TMP}/fs/elsewhere' HPCRUN_REQUIRES_HOST_SOFTWARE='bench'
            make_apptainer_launcher '${TMP}/h2.sh' '${TMP}/fs/image.sif' mpich" 2>&1)"
want "an install whose directory is not there is refused" 1 "$?"
case "${out}" in *"elsewhere/bench_mpich does not exist"*) ok "and the refusal names the path" ;;
                 *) bad "the refusal does not name the path" "${out}" ;; esac
out="$(run "HPCRUN_REQUIRES_HOST_SOFTWARE='bench'
            make_apptainer_launcher '${TMP}/h3.sh' '${TMP}/fs/image.sif' mpich" 2>&1)"
want "host software the cluster does not declare is refused" 1 "$?"

echo
echo "GPU-aware MPI"
out="$(gpu_run "HPCRUN_REQUIRES_GPU_AWARE_MPI=true
                make_apptainer_launcher '${TMP}/ga.sh' '${TMP}/fs/image.sif' mpich && cat '${TMP}/ga.sh'")"
echo "${out}" | grep -q '^export MPICH_GPU_SUPPORT_ENABLED="${MPICH_GPU_SUPPORT_ENABLED:-1}"$' \
    && ok "an app that passes device buffers gets Cray MPICH's GPU support" \
    || bad "no MPICH_GPU_SUPPORT_ENABLED for a gpu_aware_mpi app" "${out}"
out="$(PATH="${TMP}/stubrt:${PATH}" HPCRUN_GPU_BIND=none MPICH_GPU_SUPPORT_ENABLED=0 \
       bash -c ". '${TMP}/ga.sh' true >/dev/null; echo \"M=\${MPICH_GPU_SUPPORT_ENABLED}\"")"
want "a variant's own setting wins" "M=0" "${out}"
out="$(run "HPCRUN_REQUIRES_GPU_AWARE_MPI=true
            make_apptainer_launcher '${TMP}/gc.sh' '${TMP}/fs/image.sif' mpich && cat '${TMP}/gc.sh'")"
case "${out}" in
    *"export MPICH_GPU_SUPPORT_ENABLED"*) bad "a CPU node type got GPU support switched on" "${out}" ;;
    *"WARNING"*"device buffers"*)         ok "a CPU node type warns and leaves it off" ;;
    *)                                    bad "no warning on a CPU node type" "${out}" ;;
esac

#-- which GPU each rank gets ----------------------------------------------------
echo
echo "GPU binding"
# A Derecho A100 node, as step 0 measured it: four GPUs whose NUMA domains run
# in reverse of the cores', 16 cores a domain.
G="${TMP}/gpunode"
mkdir -p "${G}/proc/self"
i=0
for bus in 0000:03:00.0 0000:41:00.0 0000:82:00.0 0000:c1:00.0; do
    mkdir -p "${G}/proc/driver/nvidia/gpus/${bus}" "${G}/sys/bus/pci/devices/${bus}"
    printf 'Model: \t\t NVIDIA A100-SXM4-40GB\nGPU UUID: \t GPU-%d\nBus Location: \t %s\n' \
        "${i}" "${bus}" > "${G}/proc/driver/nvidia/gpus/${bus}/information"
    echo $(( 3 - i )) > "${G}/sys/bus/pci/devices/${bus}/numa_node"
    i=$(( i + 1 ))
done
for cpu in 0 16 32 48 64; do
    mkdir -p "${G}/sys/devices/system/cpu/cpu${cpu}/node$(( cpu / 16 % 4 ))"
done
bind () { # bind <first cpus> [VAR=value ...] -- the GPU chosen, and the log line
    local cpus="$1"; shift
    printf 'Cpus_allowed_list:\t%s\n' "${cpus}" > "${G}/proc/self/status"
    env -u CUDA_VISIBLE_DEVICES HPCRUN_GPU_BIND_ROOT="${G}" PMI_RANK=0 PMI_LOCAL_RANK=1 \
        HPCRUN_GPU_BIND_LOG=/dev/stdout "$@" \
        bash -c ". '${HERE}/../lib/gpu_bind.sh'; gpu_bind; echo \"CVD=\${CUDA_VISIBLE_DEVICES:-}\""
}
want "a rank on NUMA 0 gets the GPU on NUMA 0, not GPU 0" "CVD=GPU-3" "$(bind 0-15 | tail -1)"
want "a rank on NUMA 2 gets the GPU on NUMA 2"           "CVD=GPU-1" "$(bind 32-47 | tail -1)"
want "a rank's first core decides, on an SMT sibling too" "CVD=GPU-3" "$(bind 64,65 | tail -1)"
want "the job's own GPUs are the ones chosen from" "CVD=GPU-0" \
     "$(bind 0-15 CUDA_VISIBLE_DEVICES=GPU-1,GPU-0 | tail -1)"
want "another node's UUIDs fall back to this node's GPUs" "CVD=GPU-3" \
     "$(bind 0-15 CUDA_VISIBLE_DEVICES=GPU-elsewhere | tail -1)"
want "a list of indices is left as it is" "CVD=2,3" \
     "$(bind 0-15 CUDA_VISIBLE_DEVICES=2,3 | tail -1)"
want "an empty list stays empty, not one GPU" "CVD= hidden" \
     "$(bind 0-15 CUDA_VISIBLE_DEVICES= | awk '/^host=/ { split($NF, h, "="); w = h[2] } /^CVD=/ { c = $0 } END { print c, w }')"
want "HPCRUN_GPU_BIND=none leaves the job's list alone" "CVD=GPU-1,GPU-0" \
     "$(bind 0-15 CUDA_VISIBLE_DEVICES=GPU-1,GPU-0 HPCRUN_GPU_BIND=none | tail -1)"
want "with no GPU on its domain, local rank modulo the job's GPUs" "CVD=GPU-1" \
     "$(bind 0-15 CUDA_VISIBLE_DEVICES=GPU-0,GPU-1 | tail -1)"
case "$(bind 0-15 | head -1)" in
    "host="*" rank=0 cpu=0 numa=0 gpu=GPU-3 bus=0000:c1:00.0 gpu_numa=0 how=numa") ok "each rank logs its GPU" ;;
    *) bad "the binding log line is wrong" "$(bind 0-15 | head -1)" ;;
esac

# What the runner reads back.
printf '%s\n' 'host=n1 rank=0 cpu=0 numa=0 gpu=GPU-3 bus=c1 gpu_numa=0 how=numa' \
              'host=n1 rank=1 cpu=32 numa=2 gpu=GPU-1 bus=41 gpu_numa=2 how=numa' > "${TMP}/near.txt"
printf '%s\n' 'host=n1 rank=0 cpu=0 numa=0 gpu=GPU-0 bus=03 gpu_numa=3 how=modulo' \
              'host=n1 rank=1 cpu=32 numa=2 gpu=GPU-1 bus=41 gpu_numa=2 how=numa' > "${TMP}/far.txt"
printf '%s\n' 'report_gpus: host=n1 rank=0 kernel=ok' 'report_gpus: host=n1 rank=1 kernel=no kernel image' > "${TMP}/rg.out"
summ () { bash -c ". '${HERE}/../lib/gpu_bind.sh'; gpu_bind_summary $*
                  echo \"\${GPU_RANKS} \${GPU_FAR} \${GPU_NO_KERNEL} | \${GPU_SUMMARY}\""; }
want "two ranks, each on its own NUMA domain's GPU" \
     "2 0 0 | 2 rank(s) on 2 GPU(s), each on its own NUMA domain" "$(summ "${TMP}/near.txt")"
case "$(summ "${TMP}/far.txt")" in
    "2 1 0 | "*"WARNING rank(s) 0 on a GPU of another NUMA domain"*) ok "a rank on a far GPU is named" ;;
    *) bad "a far GPU was not reported" "$(summ "${TMP}/far.txt")" ;;
esac
case "$(summ "${TMP}/near.txt" "${TMP}/rg.out")" in
    "2 0 1 | "*"kernel ran on 1/2") ok "a rank whose kernel did not run is counted" ;;
    *) bad "report_gpus was not read" "$(summ "${TMP}/near.txt" "${TMP}/rg.out")" ;;
esac

echo
echo "image identity"
# An image says what it is in its labels, and the launcher asks them before the
# file name: which host-MPI recipe is applied is decided from the answer, and a
# renamed .sif must not change it.  A stub container runtime answers inspect.
mkdir -p "${TMP}/rt"
cat > "${TMP}/rt/apptainer" <<'RT'
#!/bin/bash
[ "$1 $2" = "inspect --labels" ] || exit 1
case "$3" in
    *labelled*) printf 'hpcdev.compiler: oneapi\nhpcdev.mpi: openmpi\nhpcdev.os: leap\n' ;;
    *)          printf 'compiler: gcc\n' ;;
esac
RT
chmod +x "${TMP}/rt/apptainer"
: > "${TMP}/leap-gcc14-mpich-labelled.sif"
: > "${TMP}/leap-gcc14-mpich-plain.sif"
ident () { # ident <sif> [PATH prefix] -- "compiler mpi" as the launcher sees them
    PATH="${2:+$2:}/usr/bin:/bin" bash -c ". '${TMP}/cluster.sh'
        . '${HERE}/../lib/make_apptainer_launcher.sh'
        echo \"\$(_launcher_sniff_compiler '$1') \$(_launcher_sniff_family '$1')\""
}
want "the labels win over the file name" "oneapi openmpi" \
     "$(ident "${TMP}/leap-gcc14-mpich-labelled.sif" "${TMP}/rt")"
want "an unlabelled image falls back to its name" "gcc14 mpich" \
     "$(ident "${TMP}/leap-gcc14-mpich-plain.sif" "${TMP}/rt")"
want "with no runtime to ask, the name answers" "gcc14 mpich" \
     "$(ident "${TMP}/leap-gcc14-mpich-labelled.sif")"

echo
echo "instruction set"
# A host without AVX-512, a binary report_cpu_features says uses it, and an
# objdump that says where.  AVX-512 only in routines that dispatch at run time
# (Intel's SVML) is not a requirement; anywhere else it is, and so is not being
# able to tell.
mkdir -p "${TMP}/arch"
cat > "${TMP}/arch/rcf" <<'RCF'
#!/bin/bash
echo "  ISA flags: avx2 bmi1 bmi2 fma sse4_1 sse4_2"
echo "  AVX-512 (zmm) used by binary: ${FAKE_USED:-YES}"
[ -n "${FAKE_REQ:-}" ] && echo "  AVX-512 required: ${FAKE_REQ}"
exit 0
RCF
cat > "${TMP}/arch/objdump" <<'OBJ'
#!/bin/bash
case "${FAKE_ZMM:-}" in
    svml) printf '0000000000458130 <__svml_cos2_z0>:\n  45814c:\tvfmadd231pd %%zmm2,%%zmm1,%%zmm3\n' ;;
    own)  printf '0000000000401000 <main>:\n  401010:\tvaddpd %%zmm0,%%zmm1,%%zmm2\n0000000000458130 <__svml_cos2_z0>:\n  45814c:\tvfmadd231pd %%zmm2,%%zmm1,%%zmm3\n' ;;
    *)    exit 1 ;;
esac
OBJ
cat > "${TMP}/arch/launch" <<LAUNCH
#!/bin/bash
PATH="${TMP}/arch:\${PATH}" exec "\$@"
LAUNCH
chmod +x "${TMP}/arch/rcf" "${TMP}/arch/objdump" "${TMP}/arch/launch"
: > "${TMP}/arch/bin"
arch () { # arch <FAKE_ZMM> -- "rc verdict"
    FAKE_ZMM="$1" HPCRUN_CPU_FEATURES="${TMP}/arch/rcf" bash -c ". '${HERE}/../lib/check_arch.sh'
        arch_check '${TMP}/arch/launch' '${TMP}/arch/bin' '${TMP}/arch/cf.txt' >/dev/null
        echo \"\$? \${ARCH_VERDICT}\""
}
want "AVX-512 only in Intel's dispatched SVML is not a requirement" "0 ok" "$(arch svml)"
want "AVX-512 in the binary's own code still refuses the job" "1 over-built" "$(arch own)"
want "AVX-512 it cannot place still refuses the job" "1 over-built" "$(arch none)"
# The factory's report_cpu_features says itself whether the binary needs it
# (CONTRACT.md); objdump is then not asked, so "none" would refuse if it were.
want "a report that says required: no is trusted" "0 ok" \
     "$(FAKE_REQ='no  (only in run-time-dispatched routines, never run without AVX-512)' arch none)"
want "a report that says required: YES refuses, with no zmm named" "1 over-built" \
     "$(FAKE_USED='no  (but AVX-512 instructions on narrower registers, below)' \
        FAKE_REQ='YES  (in 3 of its own functions; requires an AVX-512 host)' arch svml)"

echo
echo "  ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
