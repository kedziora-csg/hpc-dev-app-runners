#!/bin/bash
#-------------------------------------------------------------------------------
# make_apptainer_launcher.sh -- emit the per-rank Apptainer wrapper used by the
# PBS scripts in ../PBS/.
#
# The host job launcher (Cray PALS mpiexec on Derecho) starts N copies of the
# generated script; each one execs apptainer, which runs the real executable
# inside the container with the HOST's MPI swapped in.  Everything about how
# that swap is done depends on the container's MPI family, and that is the only
# thing this file exists to encapsulate -- the PBS scripts stay family-agnostic.
#
# USAGE
#     source make_apptainer_launcher.sh
#     make_apptainer_launcher <outfile> <container_img> [mpi_family]
#
#   mpi_family defaults to being sniffed from the image name, then from
#   $LMOD_FAMILY_MPI.  Pass it explicitly when the image name is uninformative.
#
# Sets (and exports) LAUNCHER_MPI_FAMILY and LAUNCHER_COMPILER_FAMILY to what it
# actually used, so the caller can load the matching host modules.
#
# Also provides two helpers the PBS scripts use to stay family-agnostic:
#     load_host_modules <compiler_family> <mpi_family>
#         load the Derecho modules matching the container's toolchain.
#     mpi_launch_flags <mpi_family> <ranks_per_node> <depth> <bound|trap>
#         emit the mpiexec placement flags in the right dialect (Cray PALS vs
#         Open MPI), since the two share almost no spelling.
#-------------------------------------------------------------------------------

# Progress chatter is verbose-only; WARNINGS and errors always print.  vecho
# belongs to provenance.sh -- this fallback keeps the file usable when sourced
# on its own, e.g. from an interactive shell.
command -v vecho >/dev/null 2>&1 \
    || vecho () { [ "${BENCH_VERBOSE:-0}" != "0" ] && echo "$@"; return 0; }

#-------------------------------------------------------------------------------
# Resolve version-bearing paths at runtime; hardcoded version numbers rot at the
# next system update.
#-------------------------------------------------------------------------------
_launcher_common_paths () {
    PALS_LIB="$(ls -d /opt/cray/pals/*/lib 2>/dev/null | tail -1)"
    FABRIC_LIB="${NCAR_ROOT_LIBFABRIC:+${NCAR_ROOT_LIBFABRIC}/lib64}"
    FABRIC_LIB="${FABRIC_LIB:-$(ls -d /opt/cray/libfabric/*/lib64 2>/dev/null | tail -1)}"
    # GPFS (IBM Spectrum Scale).  The host resolves libgpfs.so through its own
    # /etc/ld.so.conf; the container has its own, so the directory has to be
    # named explicitly -- see the GPFS note in the openmpi arm below.
    GPFS_ROOT="/usr/lpp/mmfs"
    GPFS_LIB="${GPFS_ROOT}/lib"
}

# Emit "--bind <dir>" only when <dir> exists on the host.  Apptainer treats a
# missing bind SOURCE as a fatal error, so an unconditional bind of a
# site-specific path (GPFS, Cray) turns "this filesystem isn't here" into
# "the job won't start" on any host that lacks it.
_bind_if_present () {
    [ -d "$1" ] && echo "--bind $1"
}

# Join arguments with ':', dropping any that are empty or name a nonexistent
# directory.  This matters more than it looks: an EMPTY element in
# LD_LIBRARY_PATH means "the current working directory", so a path built by
# naive interpolation of an unset variable ("a::b") silently makes the loader
# search $PWD -- a correctness and security problem that only shows up when one
# of the site paths fails to resolve.
_join_libpath () {
    local out="" p
    for p in "$@"; do
        [ -n "${p}" ] || continue
        [ -d "${p}" ] || continue
        out="${out:+${out}:}${p}"
    done
    echo "${out}"
}

_launcher_sniff_family () {
    local img="$1" fam=""
    case "${img}" in
        *mpich3*)  fam="mpich3"  ;;
        *mpich*)   fam="mpich"   ;;
        *openmpi*) fam="openmpi" ;;
    esac
    [ -n "${fam}" ] || fam="${LMOD_FAMILY_MPI}"
    echo "${fam}"
}

# Sniff the compiler family from the image name (<os>-<compiler>-<mpi>[...].sif).
# Order matters: gcc14 must be tested before the bare gcc substring.  Defaults to
# oneapi -- the Derecho site-default compiler -- when the name is uninformative.
_launcher_sniff_compiler () {
    local img="$1" comp=""
    case "${img}" in
        *oneapi*) comp="oneapi" ;;
        *nvhpc*)  comp="nvhpc"  ;;
        *aocc*)   comp="aocc"   ;;
        *gcc14*)  comp="gcc14"  ;;
        *clang*)  comp="clang"  ;;
        *gcc*)    comp="gcc"    ;;
    esac
    [ -n "${comp}" ] || comp="${LMOD_FAMILY_COMPILER:-oneapi}"
    echo "${comp}"
}

# Map a container compiler tag to the matching Derecho module.  oneapi -> intel
# because the site-default `intel` module IS the oneapi toolchain (intel/2025.2.1);
# gcc14 -> gcc/14.3.0 to match the container's gcc exactly.
_launcher_compiler_module () {
    case "$1" in
        oneapi) echo "intel"      ;;
        gcc14)  echo "gcc/14.3.0" ;;
        gcc)    echo "gcc"        ;;
        nvhpc)  echo "nvhpc"      ;;
        aocc)   echo "aocc"       ;;
        clang)  echo "clang"      ;;
        *)      echo ""           ;;
    esac
}

# Load the Derecho host modules matching the container's toolchain, so the host
# MPI that displaces the container's is built with a compatible compiler.  The
# compiler MUST be loaded before the MPI: Lmod resolves the openmpi build against
# the loaded compiler, and NCAR_ROOT_OPENMPI is only set once openmpi is loaded.
load_host_modules () {
    local comp="$1" mpi="$2" cmod
    cmod="$(_launcher_compiler_module "${comp}")"
    if [ -n "${cmod}" ]; then
        vecho "load_host_modules: module load ${cmod}"
        module load "${cmod}" || return 1
    else
        echo "load_host_modules: WARNING no module mapping for compiler '${comp}'"
    fi
    case "${mpi}" in
        openmpi)
            vecho "load_host_modules: module load openmpi"
            module load openmpi || return 1
            ;;
        mpich|mpich3)
            # Cray MPICH ships in the default ncarenv; nothing to add.  Drop any
            # openmpi left loaded by a previous image so its mpiexec and libs do
            # not shadow Cray PALS / the MPICH ABI shim.
            module unload openmpi 2>/dev/null || true
            ;;
    esac
}

# Emit the mpiexec placement flags (everything except -n and the executable) in
# the dialect of <mpi_family>.  Cray PALS (mpich) and Open MPI 5.0.x (openmpi,
# Derecho's host is 5.0.9) disagree on every spelling:
#   procs-per-node : PALS -ppn N          Open MPI -N N
#   depth binding  : PALS --cpu-bind core -d D
#                    Open MPI --map-by ppr:P:node:pe=D --bind-to core
# mode=bound gives each rank a D-core span (OpenMP spreads its threads inside)
# plus one more if SMT is enabled. 
# mode=trap omits the per-rank binding request, reproducing the classic pile-up
# the placement checker must catch.
mpi_launch_flags () {
    local fam="$1" ppn="$2" depth="$3" mode="$4"
    case "${fam}" in
        openmpi)
            case "${mode}" in
                bound) echo "--map-by ppr:${ppn}:node:pe=${depth} --bind-to core" ;;
                *)     echo "-N ${ppn}" ;;
            esac
            ;;
        *)  # Cray PALS: mpich / mpich3
            case "${mode}" in
                bound) echo "-ppn ${ppn} --cpu-bind core -d ${depth}" ;;
                *)     echo "-ppn ${ppn}" ;;
            esac
            ;;
    esac
}

make_apptainer_launcher () {
    local outfile="$1" img="$2" family="${3:-}"

    [ -n "${outfile}" ] && [ -n "${img}" ] \
        || { echo "usage: make_apptainer_launcher <outfile> <image> [family]"; return 1; }
    [ -f "${img}" ] || { echo "no such image: ${img}"; return 1; }

    [ -n "${family}" ] || family="$(_launcher_sniff_family "${img}")"
    export LAUNCHER_COMPILER_FAMILY="$(_launcher_sniff_compiler "${img}")"
    _launcher_common_paths

    local binds env_lines ld_path
    binds='--bind /glade --bind /local_scratch \
    --bind /run --bind /var/run \
    --bind /opt/cray --bind /etc/cray \
    --bind /usr/lib64:/host_lib64'
    # GPFS: needed by any host MPI whose ROMIO carries the GPFS ADIO backend
    # (Derecho/Casper OpenMPI does).  Harmless for the others.
    binds="${binds} $(_bind_if_present "${GPFS_ROOT}")"

    case "${family}" in
        mpich|mpich3)
            #-------------------------------------------------------------------
            # Cray MPICH ABI shim.  Cray ships TWO library directories:
            #   lib/            the native Cray build, libmpi_cray.so.12
            #   lib-abi-mpich/  the shim, libmpi.so.12 with stock MPICH's ABI
            # ONLY the second can displace the container's own libmpi.so.12.
            # Point at lib/ and every rank silently singleton-initialises into
            # its own MPI_COMM_WORLD of size 1 -- N serial programs wearing the
            # costume of a running job.
            #-------------------------------------------------------------------
            local cray_mpi="${CRAY_MPICH_DIR:-${CRAY_MPICH_PREFIX}}"
            [ -d "${cray_mpi}/lib-abi-mpich" ] || {
                echo "make_apptainer_launcher: no lib-abi-mpich under '${cray_mpi}'"
                echo "  (is cray-mpich loaded?  module list)"
                return 1
            }
            ld_path="$(_join_libpath "${cray_mpi}/lib-abi-mpich" /opt/cray/pe/lib64 \
                                     "${PALS_LIB}" "${FABRIC_LIB}" "${GPFS_LIB}" \
                                     /usr/lib64):/host_lib64"
            # XPMEM/CMA single-copy needs ptrace visibility the container
            # namespace does not have.
            env_lines='    --env MPICH_SMP_SINGLE_COPY_MODE=NONE \
    --env MPICH_VERSION_DISPLAY=1 \'
            ;;

        openmpi)
            #-------------------------------------------------------------------
            # UNVERIFIED ON DERECHO.  OpenMPI is not part of the MPICH ABI
            # Compatibility Initiative, so there is no cross-implementation shim:
            # the container's OpenMPI must VERSION-MATCH the host's (ABI is only
            # guaranteed within a release series).  It also bootstraps over PMIx
            # and must agree with what PALS serves -- the usual failure point.
            #
            # This arm follows the pattern proven on Casper (OSU_casper.pbs),
            # adapted to Derecho's paths.  Treat it as a starting hypothesis, and
            # check the '# mpi' header line of report_placement to see which
            # library actually loaded.
            #
            # GPFS: NCAR's OpenMPI is built with ROMIO's GPFS ADIO backend, so
            # libmpi.so.40 carries a hard NEEDED on libgpfs.so.  On the host that
            # resolves out of /etc/ld.so.conf; inside the container it does not
            # exist at all, and every rank dies before main() with
            #     libgpfs.so: cannot open shared object file
            # Hence /usr/lpp/mmfs is bound above and its lib/ is on the path
            # below.  Cray MPICH's ABI shim has no such dependency, which is why
            # only this arm needed it.
            #-------------------------------------------------------------------
            # Host OpenMPI is normally loaded by load_host_modules (compiler
            # first, then the matching openmpi build).  Fall back to loading it
            # here so a standalone call still resolves NCAR_ROOT_OPENMPI.
            [ -n "${NCAR_ROOT_OPENMPI:-}" ] || module load openmpi 2>/dev/null

            local ompi_root="${NCAR_ROOT_OPENMPI:-}"
            [ -n "${ompi_root}" ] || {
                echo "make_apptainer_launcher: NCAR_ROOT_OPENMPI is unset."
                echo "  Load the host OpenMPI first:  module load openmpi"
                echo "  (if no openmpi module exists here, the container's own"
                echo "   OpenMPI cannot be displaced and will not use the fabric)"
                return 1
            }
            binds="${binds} \\
    --bind ${ompi_root}"
            ld_path="$(_join_libpath "${ompi_root}/lib" /opt/cray/pe/lib64 \
                                     "${PALS_LIB}" "${FABRIC_LIB}" "${GPFS_LIB}" \
                                     /usr/lib64):/host_lib64"
            # Avoid UCX poking /proc of other ranks, which the container
            # namespace forbids (same reason as the Casper script).
            #
            # OPAL_PREFIX pins the host OpenMPI's idea of its own install root.
            # Open MPI normally derives it from the runtime location of
            # libopen-pal, but the container also ships an OpenMPI under
            # /container; naming it explicitly guarantees the MCA components,
            # help files and wrapper data come from the HOST tree we just bound.
            env_lines="    --env UCX_POSIX_USE_PROC_LINK=n \\
    --env OMPI_MCA_btl_vader_single_copy_mechanism=none \\
    --env OPAL_PREFIX=${ompi_root} \\"
            ;;

        *)
            echo "make_apptainer_launcher: unknown MPI family '${family}'"
            echo "  expected mpich | mpich3 | openmpi; pass it explicitly or"
            echo "  name the image so it can be sniffed"
            return 1
            ;;
    esac

    vecho "Making launcher for ${img} (family=${family}) in dir $(pwd)"

    cat <<EOF > "${outfile}" && chmod +x "${outfile}"
#!/bin/bash
# generated by make_apptainer_launcher.sh -- family=${family}
\$(which apptainer) --quiet exec \\
    ${binds} \\
    --env LD_LIBRARY_PATH=${ld_path} \\
${env_lines}
    ${img} "\${@}"
EOF

    export LAUNCHER_MPI_FAMILY="${family}"
    vecho "launcher: ${outfile}  (family=${family})"
}
