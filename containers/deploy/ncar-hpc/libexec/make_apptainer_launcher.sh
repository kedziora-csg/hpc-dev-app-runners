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
# Sets (and exports) LAUNCHER_MPI_FAMILY to what it actually used.
#-------------------------------------------------------------------------------

#-------------------------------------------------------------------------------
# Resolve version-bearing paths at runtime; hardcoded version numbers rot at the
# next system update.
#-------------------------------------------------------------------------------
_launcher_common_paths () {
    PALS_LIB="$(ls -d /opt/cray/pals/*/lib 2>/dev/null | tail -1)"
    FABRIC_LIB="${NCAR_ROOT_LIBFABRIC:+${NCAR_ROOT_LIBFABRIC}/lib64}"
    FABRIC_LIB="${FABRIC_LIB:-$(ls -d /opt/cray/libfabric/*/lib64 2>/dev/null | tail -1)}"
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

make_apptainer_launcher () {
    local outfile="$1" img="$2" family="${3:-}"

    [ -n "${outfile}" ] && [ -n "${img}" ] \
        || { echo "usage: make_apptainer_launcher <outfile> <image> [family]"; return 1; }
    [ -f "${img}" ] || { echo "no such image: ${img}"; return 1; }

    [ -n "${family}" ] || family="$(_launcher_sniff_family "${img}")"
    _launcher_common_paths

    local binds env_lines ld_path
    binds='--bind /glade --bind /local_scratch \
    --bind /run --bind /var/run \
    --bind /opt/cray --bind /etc/cray \
    --bind /usr/lib64:/host_lib64'

    echo "gk: in make_apptainer_launcher"

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
                                     "${PALS_LIB}" "${FABRIC_LIB}" /usr/lib64):/host_lib64"
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
            #-------------------------------------------------------------------
            echo "gk: in openmpi case, issuing `module load openmpi`"
            module load openmpi
            
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
                                     "${PALS_LIB}" "${FABRIC_LIB}" /usr/lib64):/host_lib64"
            # Avoid UCX poking /proc of other ranks, which the container
            # namespace forbids (same reason as the Casper script).
            env_lines='    --env UCX_POSIX_USE_PROC_LINK=n \
    --env OMPI_MCA_btl_vader_single_copy_mechanism=none \'
            ;;

        *)
            echo "make_apptainer_launcher: unknown MPI family '${family}'"
            echo "  expected mpich | mpich3 | openmpi; pass it explicitly or"
            echo "  name the image so it can be sniffed"
            return 1
            ;;
    esac

    echo "gk: making launcher for ${img} (family=${family}) in dir $(pwd)"
    echo "gk: outfile=${outfile}"
    echo 

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
    echo "launcher: ${outfile}  (family=${family})"
}
