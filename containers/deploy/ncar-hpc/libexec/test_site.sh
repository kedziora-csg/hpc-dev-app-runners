#!/bin/bash
#-------------------------------------------------------------------------------
# test_site.sh -- the shell that consumes a site profile, checked with no cluster.
#
#     ./test_site.sh
#
# What this covers is the seam phase 4 introduced: sites/<site>.yaml is the only
# statement of a machine's binds, library path, module maps and MPI recipes, and
# make_apptainer_launcher.sh / probe_topology.sh read them from the profile
# bench/sitegen generates.  Before, those values were literals in the shell; the
# risk now is different and worth testing for directly:
#
#   the launcher is still correct   the same binds, the same LD_LIBRARY_PATH
#                                   order, the same mpiexec flags as when they
#                                   were written into the file
#   a missing profile FAILS         rather than falling back to Derecho's paths
#                                   on a machine that is not Derecho, which is
#                                   the whole reason there are no defaults
#   an unsupported family FAILS     a site that lists no mpich cannot host an
#                                   mpich image, and says so
#   ${VAR} entries stay literal     a lib_dirs entry naming a module's variable
#                                   must survive the profile being sourced
#
# It runs against a SYNTHETIC site, not against derecho/site.sh, so it asserts
# behaviour rather than restating Derecho's values -- a test that copied them
# would pass whatever they became.
#-------------------------------------------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY="$(cd "${HERE}/../.." && pwd)"

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
pass=0 fail=0

ok   () { echo "  ok    $1"; pass=$((pass + 1)); }
bad  () { echo "  FAIL  $1"; shift; [ $# -gt 0 ] && printf '        %s\n' "$@"; fail=$((fail + 1)); }
want () { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected: $2" "got:      $3"; fi }

echo "site profile consumers"
echo

#-- a synthetic machine, with real directories so the existence tests bite -----
mkdir -p "${TMP}/fs"/{bound,optional,libs,usrlib,mpi/lib,cray/lib-abi-mpich,vers/9.9/lib}
: > "${TMP}/fs/image.sif"

cat > "${TMP}/site.sh" <<EOF
BENCH_SITE='testville'
BENCH_CONTAINER_RUNTIME='apptainer'
BENCH_BINDS='${TMP}/fs/bound'
BENCH_BINDS_IF_PRESENT='${TMP}/fs/optional ${TMP}/fs/absent'
BENCH_BIND_MAP='${TMP}/fs/usrlib:/host_lib64'
BENCH_LIB_DIRS='${TMP}/fs/libs ${TMP}/fs/vers/*/lib \${TEST_MODULE_ROOT}/lib ${TMP}/fs/absent'
BENCH_CORES_PER_NODE='64'
BENCH_SMT='2'
BENCH_SOCKETS='2'
BENCH_SMT_STRIDE='64'
BENCH_CORES_PER_L3='4'
BENCH_CORES_PER_NUMA='8'
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
    . '${TMP}/site.sh'
    export TEST_MODULE_ROOT='${TMP}/fs/mpi'
    export CRAY_MPICH_DIR='${TMP}/fs/cray'
    . '${HERE}/make_apptainer_launcher.sh'
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
want "a family the site does not list is refused" 1 "$?"

#-- refusing, rather than guessing ----------------------------------------------
echo
echo "no profile, no defaults"

# The point of generating site.sh rather than keeping literals in the shell: a
# machine with no profile must fail, not quietly run with another machine's
# paths.
bash -c "set -u; . '${HERE}/make_apptainer_launcher.sh'" >/dev/null 2>&1
want "sourcing the launcher without a site profile fails" 1 "$?"

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
    . '${HERE}/probe_topology.sh'
    _topo_set_fallback
    echo \"\${TOPO_CORES_PER_NODE} \${TOPO_SMT} \${TOPO_CORES_PER_L3} \${TOPO_SOURCE}\""; }

want "the fallback comes from the profile" "64 2 4 fallback:site-profile:testville" \
     "$(topo ". '${TMP}/site.sh'")"

# Not Derecho's 128: with nothing to go on the fallback must describe a machine
# no real placement fits, so the caller notices instead of accepting a geometry
# the node cannot run.
want "with no profile the fallback invents nothing" "1 1 1 fallback:none" "$(topo "true")"

echo
echo "  ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
