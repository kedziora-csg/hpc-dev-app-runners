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
#     source <site>/site.sh          # required: this file has no site constants
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
#         load the host modules matching the container's toolchain.
#     mpi_launch_flags <mpi_family> <ranks_per_node> <depth> <bound|trap>
#         emit the mpiexec placement flags in the right dialect (Cray PALS vs
#         Open MPI), since the two share almost no spelling.
#
# WHAT IS DATA AND WHAT IS CODE
#
# The bind list, the library path, the two module maps and the launcher dialect
# per family are DATA and live in sites/<site>.yaml, reaching this file as the
# BENCH_* variables and bench_site_* functions that sites/<site>/site.sh exports.
# There are no site constants left here, and no defaults standing in for them: a
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
    || vecho () { [ "${BENCH_VERBOSE:-0}" != "0" ] && echo "$@"; return 0; }

#-------------------------------------------------------------------------------
# The site profile is a prerequisite, not an optional extra.  Checked once, at
# source time, naming the one function whose absence would otherwise show up
# much later as an empty module name and a container that quietly kept its own
# MPI.
#-------------------------------------------------------------------------------
if ! command -v bench_site_mpi_overlay >/dev/null 2>&1; then
    echo "make_apptainer_launcher.sh: no site profile has been sourced." >&2
    echo "  Source sites/<site>/site.sh first.  Every bind, library directory" >&2
    echo "  and module name this file uses comes from there, generated from" >&2
    echo "  sites/<site>.yaml by bench/sitegen." >&2
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

# The site's library directories, resolved, in order.  Whatever an overlay
# recipe prepends goes ahead of these.
_launcher_site_libdirs () {
    local entry
    for entry in ${BENCH_LIB_DIRS}; do
        _launcher_expand_dir "${entry}"
    done
}

# The --bind arguments for this site.  Unconditional binds first, then the ones
# that only apply where the directory exists, then the remapped ones.
#
# Apptainer treats a missing bind SOURCE as fatal, which is why the second list
# exists at all: an unconditional bind of a filesystem some nodes lack turns
# "that mount is absent" into "the job will not start".
_launcher_site_binds () {
    local out="" d pair
    for d in ${BENCH_BINDS}; do
        out="${out}${out:+ }--bind ${d}"
    done
    for d in ${BENCH_BINDS_IF_PRESENT}; do
        [ -d "${d}" ] && out="${out}${out:+ }--bind ${d}"
    done
    for pair in ${BENCH_BIND_MAP}; do
        [ -d "${pair%%:*}" ] && out="${out}${out:+ }--bind ${pair}"
    done
    echo "${out}"
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
# Order matters: gcc14 must be tested before the bare gcc substring.  Falls back
# to the host's own loaded compiler family when the name is uninformative.
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
    [ -n "${comp}" ] || comp="${LMOD_FAMILY_COMPILER:-}"
    echo "${comp}"
}

#-------------------------------------------------------------------------------
# Host modules.  The host MPI that displaces the container's must be built with
# a compatible compiler, so the compiler MUST be loaded before the MPI: Lmod
# resolves the MPI build against the loaded compiler, and a variable like
# NCAR_ROOT_OPENMPI is only set once that MPI is loaded.
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
        echo "  add it to modules.compiler_map in sites/${BENCH_SITE}.yaml"
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
            echo "mpi_launch_flags: ${BENCH_SITE} declares no launcher for MPI family '${fam}'" >&2
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
        echo "make_apptainer_launcher: ${BENCH_SITE} cannot host MPI family '${family}'"
        echo "  sites/${BENCH_SITE}.yaml lists no mpi: entry for it, so there is no"
        echo "  overlay recipe and no launcher dialect.  Either the image is wrong"
        echo "  for this machine, or the site description is incomplete."
        return 1
    }

    local binds ld_path head_dirs extra_env
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
            # Normally loaded by load_host_modules (compiler first, then the
            # matching openmpi build).  Loaded here too so a standalone call
            # still resolves NCAR_ROOT_OPENMPI.
            [ -n "${NCAR_ROOT_OPENMPI:-}" ] \
                || module load "$(bench_site_mpi_module "${family}")" 2>/dev/null

            local ompi_root="${NCAR_ROOT_OPENMPI:-}"
            [ -n "${ompi_root}" ] || {
                echo "make_apptainer_launcher: NCAR_ROOT_OPENMPI is unset."
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
            echo "make_apptainer_launcher: sites/${BENCH_SITE}.yaml asks for overlay"
            echo "  '${overlay}', which has no recipe here.  Add one to this case,"
            echo "  or use one of: cray-mpich-abi, host-openmpi, none"
            return 1
            ;;
    esac

    # The overlay's own directory first, then the site's, then whatever the bind
    # map renamed -- that last one has no host directory to test for, so it is
    # appended after _join_libpath rather than through it.
    ld_path="$(_join_libpath ${head_dirs} $(_launcher_site_libdirs))"
    local pair kv
    for pair in ${BENCH_BIND_MAP}; do
        [ -d "${pair%%:*}" ] && ld_path="${ld_path}${ld_path:+:}${pair#*:}"
    done

    _LAUNCHER_ARGS=""
    _launcher_add_arg "${binds}"
    _launcher_add_arg "--env LD_LIBRARY_PATH=${ld_path}"
    for kv in $(bench_site_mpi_env "${family}") ${extra_env}; do
        _launcher_add_arg "--env ${kv}"
    done

    vecho "Making launcher for ${img} (family=${family} overlay=${overlay}) in dir $(pwd)"

    cat <<EOF > "${outfile}" && chmod +x "${outfile}"
#!/bin/bash
# generated by make_apptainer_launcher.sh
#   site=${BENCH_SITE}  family=${family}  overlay=${overlay}
\$(which ${BENCH_CONTAINER_RUNTIME}) --quiet exec \\
${_LAUNCHER_ARGS}
    ${img} "\${@}"
EOF

    export LAUNCHER_MPI_FAMILY="${family}"
    vecho "launcher: ${outfile}  (family=${family})"
}
