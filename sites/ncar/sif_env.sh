>/dev/null 2>&1 \
           module purge && module load apptainer

export TMPDIR=/var/tmp/${USER}-apptainer/
export APPTAINER_TMPDIR=/var/tmp/
export APPTAINER_CACHEDIR=${WORK}/.apptainer-cache/

mkdir -p ${TMPDIR} ${APPTAINER_TMPDIR} ${APPTAINER_CACHEDIR}

export workdir="$(mktemp -d)"

mkdir -p ${workdir}/{tmp,var/tmp}

remove_workdir() { [ -d ${workdir} ] && echo "removing ${workdir}" && rm -rf "${workdir}"; }

trap remove_workdir EXIT
