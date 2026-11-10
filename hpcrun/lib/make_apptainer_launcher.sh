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
#     source <cluster>/cluster.sh    # required: this file has no constants
#     source make_apptainer_launcher.sh
#     make_apptainer_launcher <outfile> <container_img> [mpi_family]
#
#   mpi_family defaults to being sniffed from the image name, then from
#   $LMOD_FAMILY_MPI.  Pass it explicitly when the image name is uninformative.
#
# Sets (and exports) LAUNCHER_MPI_FAMILY and LAUNCHER_COMPILER_FAMILY to what it
# actually used, so the caller can load the matching host modules, and
# LAUNCHER_HOST_SOFTWARE to the host software it bound, as name=host_path.
#
# Two settings come from the app's contract, through job.env, because the
# launcher is made before the contract is read and the job reads no YAML:
#     HPCRUN_REQUIRES_HOST_SOFTWARE   names from the cluster's host_software:
#     HPCRUN_REQUIRES_GPU_AWARE_MPI   true: the app passes device buffers
#
# Also provides two helpers the PBS scripts use to stay family-agnostic:
#     load_host_modules <compiler_family> <mpi_family>
#         load the host modules matching the container's toolchain.
#     mpi_launch_flags <mpi_family> <ranks_per_node> <depth> <bound|trap>
#         emit the mpiexec placement flags in the right dialect (Cray PALS vs
#         Open MPI), since the two share almost no spelling.
#
# WHAT IS DATA AND WHAT IS CODE
#
# The bind list, the library path, the two module maps and the launcher dialect
# per family are DATA and live in the site and cluster YAMLs, reaching this file
# as the
# HPCRUN_* variables and bench_site_* functions that a cluster profile exports.
# There are no machine constants left here, and no defaults standing in for them: a
# missing profile is an error, because the alternative -- Derecho's paths quietly
# used on a machine that is not Derecho -- is a wrong answer rather than a
# failure.
#
# The BODY of each overlay recipe is CODE and stays here.  Which of Cray's two
# library directories carries the MPICH ABI, and why OPAL_PREFIX has to be pinned
# when the container ships an OpenMPI of its own, are arguments; a data file is
# the wrong place to make an argument.  The YAML names which recipe a family
# uses, and the recipe is written below.
#-------------------------------------------------------------------------------

# Progress chatter is verbose-only; WARNINGS and errors always print.  vecho
# belongs to provenance.sh -- this fallback keeps the file usable when sourced
# on its own, e.g. from an interactive shell.
command -v vecho >/dev/null 2>&1 \
    || vecho () { [ "${HPCRUN_VERBOSE:-0}" != "0" ] && echo "$@"; return 0; }

# gpu_bind.sh is sourced by the generated launcher, from here, by absolute path.
_LAUNCHER_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

#-------------------------------------------------------------------------------
# The cluster profile is a prerequisite, not an optional extra.  Checked once, at
# source time, naming the one function whose absence would otherwise show up
# much later as an empty module name and a container that quietly kept its own
# MPI.
#-------------------------------------------------------------------------------
if ! command -v bench_site_mpi_overlay >/dev/null 2>&1; then
    echo "make_apptainer_launcher.sh: no cluster profile has been sourced." >&2
    echo "  Source the cluster profile first.  Every bind, library directory" >&2
    echo "  and module name this file uses comes from there, generated from" >&2
    echo "  the cluster YAML by hpcrun/sitegen." >&2
    return 1 2>/dev/null || exit 1
fi

#-------------------------------------------------------------------------------
# Path helpers
#-------------------------------------------------------------------------------

# Expand one lib_dirs entry into zero or more real directories.
#
# Three forms, in the order they are handled:
#   ${VAR}/sub   a directory a module supplies; drops out when VAR is unset
#   /a/*/lib     a glob; newest match wins, because these carry a version
#                number that changes under us at every system update
#   /a/b         itself
# Anything that does not exist drops out here rather than reaching the path.
_launcher_expand_dir () {
    local entry="$1" var rest match

    case "${entry}" in
        '${'*'}'/*)
            var="${entry#\$\{}"; var="${var%%\}*}"
            rest="${entry#*\}}"
            # Indirect expansion, not eval: the name is matched against
            # ${VAR} above, so nothing else in the string can be executed.
            [ -n "${!var:-}" ] || return 0
            entry="${!var}${rest}"
            ;;
    esac

    case "${entry}" in
        *'*'*)
            match="$(ls -d ${entry} 2>/dev/null | tail -1)"
            [ -n "${match}" ] && echo "${match}"
            return 0
            ;;
    esac
    [ -d "${entry}" ] && echo "${entry}"
    return 0
}

# Expand an mpi.<family>.root: `${VAR}`, `${VAR}/sub` or a plain path, to the
# directory it names, or to nothing if VAR is unset or the directory is absent.
# The same indirect expansion as a lib_dirs entry, and for the same reason.
_launcher_expand_root () {
    case "$1" in
        '${'*'}') _launcher_expand_dir "$1/." | sed 's|/\.$||' ;;
        *)        _launcher_expand_dir "$1" ;;
    esac
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
        case ":${out}:" in *":${p}:"*) continue ;; esac
        out="${out:+${out}:}${p}"
    done
    echo "${out}"
}

# The cluster's library directories, resolved, in order.  Whatever an overlay
# recipe prepends goes ahead of these.
_launcher_site_libdirs () {
    local entry
    for entry in ${HPCRUN_LIB_DIRS}; do
        _launcher_expand_dir "${entry}"
    done
}

# The --bind arguments for this cluster.  Unconditional binds first, then the ones
# that only apply where the directory exists, then the remapped ones.
#
# Apptainer treats a missing bind SOURCE as fatal, which is why the second list
# exists at all: an unconditional bind of a filesystem some nodes lack turns
# "that mount is absent" into "the job will not start".
_launcher_site_binds () {
    local out="" d pair
    for d in ${HPCRUN_BINDS}; do
        out="${out}${out:+ }--bind ${d}"
    done
    for d in ${HPCRUN_BINDS_IF_PRESENT}; do
        [ -d "${d}" ] && out="${out}${out:+ }--bind ${d}"
    done
    for pair in ${HPCRUN_BIND_MAP}; do
        [ -d "${pair%%:*}" ] && out="${out}${out:+ }--bind ${pair}"
    done
    echo "${out}"
}

# _launcher_expand_vars <text> -- every ${NAME} in it replaced by the
# environment's value, empty when unset.  Prints the result.  Bounded, so a
# value that names itself cannot loop.
_launcher_expand_vars () {
    local text="$1" var n=0
    while [ "${n}" -lt 16 ]; do
        n=$(( n + 1 ))
        case "${text}" in
            *'${'*'}'*)
                var="${text#*\$\{}"; var="${var%%\}*}"
                text="${text//\$\{${var}\}/${!var:-}}" ;;
            *) break ;;
        esac
    done
    printf '%s' "${text}"
}

# _launcher_site_covers <host path> -- 0 when a site bind at its own name puts
# the path inside the container at the same place.  A host:dest pair does not.
_launcher_site_covers () {
    local d
    for d in ${HPCRUN_BINDS} ${HPCRUN_BINDS_IF_PRESENT}; do
        case "${d}" in *:*) continue ;; esac
        case "$1/" in "${d%/}/"*) return 0 ;; esac
    done
    return 1
}

# host_software_resolve <name> <mpi family> -- the install's directory on the
# host: ${mpi} is the family, and any other ${NAME} is what the environment says
# now that the host modules are loaded.  Prints why and returns 1 when the
# cluster does not declare it or the directory is not there.
host_software_resolve () {
    local name="$1" family="$2" spec var
    command -v bench_site_host_software_path >/dev/null 2>&1 \
        && spec="$(bench_site_host_software_path "${name}")"
    [ -n "${spec:-}" ] || {
        echo "host software '${name}': cluster ${HPCRUN_CLUSTER} declares no host_software.${name}" >&2
        return 1; }
    spec="${spec//\$\{mpi\}/${family}}"
    spec="$(_launcher_expand_vars "${spec}")"
    [ -d "${spec}" ] || {
        echo "host software '${name}': ${spec} does not exist" >&2
        echo "  (host_software.${name}.path in the cluster's YAML, for MPI family ${family})" >&2
        return 1; }
    echo "${spec}"
}

# Append one continuation line to the argument block being built.  A string
# rather than an array because it is written into a heredoc as it stands, and
# because the block has to end WITHOUT a trailing newline: the image and its
# arguments are the last line, and a stray blank line between two backslash
# continuations ends the command early.
_launcher_add_arg () {
    _LAUNCHER_ARGS="${_LAUNCHER_ARGS}${_LAUNCHER_ARGS:+
}    $* \\"
}

#-------------------------------------------------------------------------------
# Sniffing what an image is
#-------------------------------------------------------------------------------
# What an image says about itself: one of the hpcdev.* labels the app workflow
# stamps (apps/Dockerfile's image, carried into the .sif by apptainer build), or
# nothing.  Read FIRST, because a file name is a claim anyone can edit by
# renaming -- and which host-MPI recipe is applied is decided from the answer.
# The name patterns below remain for images built before the labels existed.
_launcher_label () {
    local img="$1" key="$2"
    [ -f "${img}" ] || return 0
    command -v "${HPCRUN_CONTAINER_RUNTIME:-apptainer}" >/dev/null 2>&1 || return 0
    "${HPCRUN_CONTAINER_RUNTIME:-apptainer}" inspect --labels "${img}" 2>/dev/null \
        | sed -n "s/^${key//./\\.}:[[:space:]]*//p" | head -1
}

_launcher_sniff_family () {
    local img="$1" fam=""
    fam="$(_launcher_label "${img}" hpcdev.mpi)"
    [ -n "${fam}" ] && { echo "${fam}"; return 0; }
    case "${img}" in
        *mpich3*)  fam="mpich3"  ;;
        *mpich*)   fam="mpich"   ;;
        *openmpi*) fam="openmpi" ;;
    esac
    [ -n "${fam}" ] || fam="${LMOD_FAMILY_MPI}"
    echo "${fam}"
}

# The compiler family: the image's hpcdev.compiler label, else sniffed from its
# name (<os>-<compiler>-<mpi>[...].sif).
# Order matters: gcc14 must be tested before the bare gcc substring.  Falls back
# to the host's own loaded compiler family when the name is uninformative.
_launcher_sniff_compiler () {
    local img="$1" comp=""
    comp="$(_launcher_label "${img}" hpcdev.compiler)"
    [ -n "${comp}" ] && { echo "${comp}"; return 0; }
    case "${img}" in
        *oneapi*) comp="oneapi" ;;
        *nvhpc*)  comp="nvhpc"  ;;
        *aocc*)   comp="aocc"   ;;
        *gcc14*)  comp="gcc14"  ;;
        *clang*)  comp="clang"  ;;
        *gcc*)    comp="gcc"    ;;
    esac
    [ -n "${comp}" ] || comp="${LMOD_FAMILY_COMPILER:-}"
    echo "${comp}"
}

#-------------------------------------------------------------------------------
# Host modules.  The host MPI that displaces the container's must be built with
# a compatible compiler, so the compiler MUST be loaded before the MPI: Lmod
# resolves the MPI build against the loaded compiler, and the variable an
# mpi.<family>.root names is only set once that MPI is loaded.
#
# Which module answers to which container tag is the site's business and comes
# from bench_site_compiler_module / bench_site_mpi_module.
#-------------------------------------------------------------------------------
load_host_modules () {
    local comp="$1" mpi="$2" cmod mmod drop m

    cmod="$(bench_site_compiler_module "${comp}")"
    if [ -n "${cmod}" ]; then
        vecho "load_host_modules: module load ${cmod}"
        module load "${cmod}" || return 1
    else
        echo "load_host_modules: WARNING no module mapping for compiler '${comp}'"
        echo "  add it to modules.compiler_map in sites/${HPCRUN_SITE}.yaml"
    fi

    # Dropped before loading, not after: a module left over from a previous
    # image puts its own mpiexec and libraries ahead of this family's, which is
    # a silently wrong run rather than a failure.
    drop="$(bench_site_mpi_unload "${mpi}")"
    for m in ${drop}; do
        vecho "load_host_modules: module unload ${m}"
        module unload "${m}" 2>/dev/null || true
    done

    mmod="$(bench_site_mpi_module "${mpi}")"
    if [ -n "${mmod}" ]; then
        vecho "load_host_modules: module load ${mmod}"
        module load "${mmod}" || return 1
    else
        # Empty is a decision, not a gap: Cray MPICH ships in the default
        # environment and there is nothing to add.  A family the site cannot
        # host at all is absent from mpi: and is caught in the case below.
        vecho "load_host_modules: no host module for mpi family '${mpi}'"
    fi
}

#-------------------------------------------------------------------------------
# Emit the mpiexec placement flags (everything except -n and the executable) in
# this site's dialect for <mpi_family>.  Cray PALS and Open MPI 5.0.x disagree
# on every spelling:
#   procs-per-node : PALS -ppn N          Open MPI -N N
#   depth binding  : PALS --cpu-bind core -d D
#                    Open MPI --map-by ppr:P:node:pe=D --bind-to core
# mode=bound gives each rank a D-core span (OpenMP spreads its threads inside)
# plus one more if SMT is enabled.
# mode=trap omits the per-rank binding request, reproducing the classic pile-up
# the placement checker must catch.
#-------------------------------------------------------------------------------
mpi_launch_flags () {
    local fam="$1" ppn="$2" depth="$3" mode="$4"
    local dialect; dialect="$(bench_site_mpi_launcher "${fam}")"

    case "${dialect}" in
        openmpi)
            case "${mode}" in
                bound) echo "--map-by ppr:${ppn}:node:pe=${depth} --bind-to core" ;;
                *)     echo "-N ${ppn}" ;;
            esac
            ;;
        pals)
            case "${mode}" in
                bound) echo "-ppn ${ppn} --cpu-bind core -d ${depth}" ;;
                *)     echo "-ppn ${ppn}" ;;
            esac
            ;;
        srun)
            case "${mode}" in
                bound) echo "--ntasks-per-node=${ppn} --cpus-per-task=${depth} --cpu-bind=cores" ;;
                *)     echo "--ntasks-per-node=${ppn}" ;;
            esac
            ;;
        *)
            echo "mpi_launch_flags: ${HPCRUN_CLUSTER} declares no launcher for MPI family '${fam}'" >&2
            return 1
            ;;
    esac
}

#-------------------------------------------------------------------------------
# The launcher itself.
#-------------------------------------------------------------------------------
make_apptainer_launcher () {
    local outfile="$1" img="$2" family="${3:-}"

    [ -n "${outfile}" ] && [ -n "${img}" ] \
        || { echo "usage: make_apptainer_launcher <outfile> <image> [family]"; return 1; }
    [ -f "${img}" ] || { echo "no such image: ${img}"; return 1; }

    [ -n "${family}" ] || family="$(_launcher_sniff_family "${img}")"
    export LAUNCHER_COMPILER_FAMILY="$(_launcher_sniff_compiler "${img}")"

    local overlay; overlay="$(bench_site_mpi_overlay "${family}")"
    [ -n "${overlay}" ] || {
        echo "make_apptainer_launcher: ${HPCRUN_CLUSTER} cannot host MPI family '${family}'"
        echo "  sites/${HPCRUN_SITE}/${HPCRUN_CLUSTER}.yaml lists no mpi: entry for it,"
        echo "  so there is no"
        echo "  overlay recipe and no launcher dialect.  Either the image is wrong"
        echo "  for this machine, or the site description is incomplete."
        return 1
    }

    local binds ld_path head_dirs extra_env gtl=""
    binds="$(_launcher_site_binds)"
    extra_env=""

    case "${overlay}" in
        cray-mpich-abi)
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
            head_dirs="${cray_mpi}/lib-abi-mpich"

            # On NVIDIA GPU nodes, Cray MPICH's GPU transport (GTL), always
            # preloaded.  It costs host buffers nothing (step 0 of
            # GpuNodesPlan.md: 0.47 against 0.48 us), and without it
            # MPICH_GPU_SUPPORT_ENABLED=1 fails at MPI_Init -- so an app that
            # passes device buffers needs only that variable.  The variable
            # itself is NOT set here: it costs host buffers 6.5 us a message.
            # GTL lives beside the ofi/ builds, not in either library
            # directory, and needs libcuda, which is why CPU nodes get none.
            if [ "${HPCRUN_GPU_VENDOR:-}" = nvidia ]; then
                gtl="${cray_mpi%/ofi/*}/gtl/lib/libmpi_gtl_cuda.so.0"
                [ -f "${gtl}" ] || {
                    echo "make_apptainer_launcher: no GTL library at ${gtl}"
                    echo "  (Cray MPICH's GPU transport, for a node type with NVIDIA GPUs)"
                    return 1
                }
            fi
            ;;

        host-openmpi)
            #-------------------------------------------------------------------
            # OpenMPI is not part of the MPICH ABI Compatibility Initiative, so
            # there is no cross-implementation shim: the container's OpenMPI must
            # VERSION-MATCH the host's (ABI is only guaranteed within a release
            # series).  It also bootstraps over PMIx and must agree with what the
            # host launcher serves -- the usual failure point.  Check the '# mpi'
            # header line of report_placement to see which library actually
            # loaded.
            #
            # GPFS: NCAR's OpenMPI is built with ROMIO's GPFS ADIO backend, so
            # libmpi.so.40 carries a hard NEEDED on libgpfs.so.  On the host that
            # resolves out of /etc/ld.so.conf; inside the container it does not
            # exist at all, and every rank dies before main() with
            #     libgpfs.so: cannot open shared object file
            # Hence GPFS is in the site's binds_if_present and its lib/ is in
            # lib_dirs.  Cray MPICH's ABI shim has no such dependency, which is
            # why only this recipe needed it.
            #-------------------------------------------------------------------
            # Where the host tree is comes from the cluster description's
            # mpi.<family>.root -- usually ${NAME} for a variable the MPI module
            # sets.  That module is normally loaded by load_host_modules
            # (compiler first, then the matching build); it is loaded here too
            # so a standalone call still resolves the root.
            local root_spec ompi_root
            root_spec="$(bench_site_mpi_root "${family}" 2>/dev/null)"
            [ -n "${root_spec}" ] || {
                echo "make_apptainer_launcher: the cluster profile states no"
                echo "  mpi.${family}.root, which the host-openmpi overlay needs."
                echo "  Add it to the cluster's YAML and run hpcrun/sitegen --write."
                return 1
            }
            ompi_root="$(_launcher_expand_root "${root_spec}")"
            [ -n "${ompi_root}" ] \
                || module load "$(bench_site_mpi_module "${family}")" 2>/dev/null
            [ -n "${ompi_root}" ] || ompi_root="$(_launcher_expand_root "${root_spec}")"
            [ -n "${ompi_root}" ] || {
                echo "make_apptainer_launcher: ${root_spec} resolves to nothing."
                echo "  Load the host OpenMPI first:  module load $(bench_site_mpi_module "${family}")"
                echo "  (if no openmpi module exists here, the container's own"
                echo "   OpenMPI cannot be displaced and will not use the fabric)"
                return 1
            }
            binds="${binds} --bind ${ompi_root}"
            head_dirs="${ompi_root}/lib"
            # OPAL_PREFIX pins the host OpenMPI's idea of its own install root.
            # Open MPI normally derives it from the runtime location of
            # libopen-pal, but the container also ships an OpenMPI under
            # /container; naming it explicitly guarantees the MCA components,
            # help files and wrapper data come from the HOST tree just bound.
            # Computed, not declared, which is why it is here and not in the
            # site file's env: block.
            extra_env="OPAL_PREFIX=${ompi_root}"
            ;;

        none)
            # The container's own MPI is used as it is.  Single-node work, or a
            # site with no host MPI worth swapping in.
            head_dirs=""
            ;;

        *)
            echo "make_apptainer_launcher: this cluster asks for overlay"
            echo "  '${overlay}', which has no recipe here.  Add one to this case,"
            echo "  or use one of: cray-mpich-abi, host-openmpi, none"
            return 1
            ;;
    esac

    # Host libraries the host MPI needs and an app built in an image is not
    # linked with: the description's mpi.<family>.preload.  Derecho's libxpmem
    # is one -- Cray's wrappers link it into a native app, and Cray MPICH's
    # XPMEM symbols are weak, so without it single copy falls back to CMA,
    # which the container refuses.  Checked here, because LD_PRELOAD of a
    # missing file is a warning and the run goes on without it -- and for the
    # same reason a file no site bind exposes is bound by itself, at its own
    # path.  sitegen checks that only for an entry without ${NAME}.
    local entry mpi_preload=""
    if command -v bench_site_mpi_preload >/dev/null 2>&1; then
        for entry in $(bench_site_mpi_preload "${family}"); do
            entry="$(_launcher_expand_vars "${entry}")"
            [ -f "${entry}" ] || {
                echo "make_apptainer_launcher: mpi.${family}.preload names ${entry},"
                echo "  which does not exist.  Update the cluster's YAML and run"
                echo "  hpcrun/sitegen --write."
                return 1
            }
            _launcher_site_covers "${entry}" || binds="${binds} --bind ${entry}"
            mpi_preload="${mpi_preload:+${mpi_preload}:}${entry}"
        done
    fi
    mpi_preload="${mpi_preload}${gtl:+${mpi_preload:+:}${gtl}}"

    # Host software the app requires (its contract's requires.host_software,
    # which submit wrote into job.env): bound at its mount, or at its own path
    # when a site bind does not already cover it, with its lib_dirs, under the
    # mount, on the library path.  LAUNCHER_HOST_SOFTWARE says what was bound,
    # for run.meta.
    local name hs_host hs_mount hs_libs="" sub d
    LAUNCHER_HOST_SOFTWARE=""
    for name in ${HPCRUN_REQUIRES_HOST_SOFTWARE:-}; do
        hs_host="$(host_software_resolve "${name}" "${family}")" || return 1
        hs_mount="$(bench_site_host_software_mount "${name}" 2>/dev/null)"
        if [ -n "${hs_mount}" ]; then
            binds="${binds} --bind ${hs_host}:${hs_mount}"
        else
            hs_mount="${hs_host}"
            _launcher_site_covers "${hs_host}" || binds="${binds} --bind ${hs_host}"
        fi
        for sub in $(bench_site_host_software_lib_dirs "${name}" 2>/dev/null); do
            [ -d "${hs_host}/${sub}" ] && hs_libs="${hs_libs:+${hs_libs}:}${hs_mount}/${sub}"
        done
        LAUNCHER_HOST_SOFTWARE="${LAUNCHER_HOST_SOFTWARE:+${LAUNCHER_HOST_SOFTWARE} }${name}=${hs_host}"
    done
    export LAUNCHER_HOST_SOFTWARE

    # The overlay's own directory first, then the host software's, then the
    # site's, then whatever the bind map renamed.  The last two kinds name
    # directories inside the container, with no host directory to test, so
    # they are joined around _join_libpath rather than through it.
    ld_path="$(_join_libpath ${head_dirs})"
    [ -n "${hs_libs}" ] && ld_path="${ld_path:+${ld_path}:}${hs_libs}"
    d="$(_join_libpath $(_launcher_site_libdirs))"
    [ -n "${d}" ] && ld_path="${ld_path:+${ld_path}:}${d}"
    local pair kv
    for pair in ${HPCRUN_BIND_MAP}; do
        [ -d "${pair%%:*}" ] && ld_path="${ld_path}${ld_path:+:}${pair#*:}"
    done

    _LAUNCHER_ARGS=""
    # --nv is apptainer's spelling of "set up the NVIDIA devices", so it is
    # code here rather than data in the description.  /host_lib64 stays: it
    # supplies the same driver library, and the CPU path depends on it.
    case "${HPCRUN_GPU_VENDOR:-}" in
        nvidia) _launcher_add_arg "--nv" ;;
        "")     ;;
        *)      echo "make_apptainer_launcher: WARNING no recipe for ${HPCRUN_GPU_VENDOR} GPUs;"
                echo "  the container will not see them" ;;
    esac
    _launcher_add_arg "${binds}"
    _launcher_add_arg "--env LD_LIBRARY_PATH=${ld_path}"
    for kv in $(bench_site_mpi_env "${family}") ${extra_env}; do
        _launcher_add_arg "--env ${kv}"
    done

    # What has to be decided per rank, at run time, comes before the exec.
    #
    # PALS keeps each launch's apinfo file, which PMI_Init reads, in
    # PALS_SPOOL_DIR under the job's TMPDIR.  Launches have seen it so far only
    # because the operator's TMPDIR happened to be under a bound path; a rank
    # that cannot read it fails with pals_init2() failed: 2 (step 0 of
    # GpuNodesPlan.md).  So it is bound, unless a bind above already covers it.
    local covered="" d preload_var
    for d in ${HPCRUN_BINDS} ${HPCRUN_BINDS_IF_PRESENT}; do
        case "${d}" in *:*) continue ;; esac
        [ -d "${d}" ] && covered="${covered}|${d%/}/*"
    done
    _LAUNCHER_PRE="_spool=()
case \"\${PALS_SPOOL_DIR:-}/\" in
    /${covered}) ;;
    *) [ -d \"\${PALS_SPOOL_DIR}\" ] && _spool=(--bind \"\${PALS_SPOOL_DIR}\") ;;
esac"
    if [ "${HPCRUN_GPU_VENDOR:-}" = nvidia ]; then
        _LAUNCHER_PRE="${_LAUNCHER_PRE}
# One GPU a rank, the one on its own NUMA domain.
. '${_LAUNCHER_HERE}/gpu_bind.sh' && gpu_bind"
    fi
    # An app that passes device buffers to MPI (requires.gpu_aware_mpi) gets
    # Cray MPICH's GPU support, which GTL above makes possible -- unless a
    # variant set the variable first, which is how an experiment forces it
    # either way.  Not for every app: it costs host buffers 6.5 us a message.
    if [ "${HPCRUN_REQUIRES_GPU_AWARE_MPI:-false}" = true ]; then
        if [ -n "${gtl}" ]; then
            _LAUNCHER_PRE="${_LAUNCHER_PRE}
# The app passes device buffers to MPI (requires.gpu_aware_mpi).
export MPICH_GPU_SUPPORT_ENABLED=\"\${MPICH_GPU_SUPPORT_ENABLED:-1}\""
        else
            echo "make_apptainer_launcher: WARNING the app passes device buffers to MPI,"
            echo "  and the ${overlay} recipe has no GPU transport to turn on here"
        fi
    fi
    if [ -n "${mpi_preload}" ]; then
        # Inside the container only, ahead of whatever a variant preloads:
        # one list, never one written over the other.
        preload_var="$(printf '%s' "${HPCRUN_CONTAINER_RUNTIME}" | tr '[:lower:]' '[:upper:]')ENV_LD_PRELOAD"
        _LAUNCHER_PRE="${_LAUNCHER_PRE}
# The host MPI's own libraries, inside the container, ahead of a variant's preload.
export ${preload_var}='${mpi_preload}'\"\${${preload_var}:+:\${${preload_var}}}\""
    fi

    vecho "Making launcher for ${img} (family=${family} overlay=${overlay}) in dir $(pwd)"

    cat <<EOF > "${outfile}" && chmod +x "${outfile}"
#!/bin/bash
# generated by make_apptainer_launcher.sh
#   site=${HPCRUN_SITE}  cluster=${HPCRUN_CLUSTER}  family=${family}  overlay=${overlay}${HPCRUN_GPU_VENDOR:+  gpus=${HPCRUN_GPU_VENDOR}}${LAUNCHER_HOST_SOFTWARE:+
#   host software: ${LAUNCHER_HOST_SOFTWARE}}
${_LAUNCHER_PRE}
\$(which ${HPCRUN_CONTAINER_RUNTIME}) --quiet exec \\
${_LAUNCHER_ARGS}
    "\${_spool[@]}" \\
    ${img} "\${@}"
EOF

    export LAUNCHER_MPI_FAMILY="${family}"
    vecho "launcher: ${outfile}  (family=${family})"
}
