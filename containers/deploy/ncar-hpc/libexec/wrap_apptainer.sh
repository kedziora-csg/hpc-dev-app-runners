#!/bin/bash

#----------------------------------------------------------------------------
# environment
SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
selfdir="$(dirname $(readlink -f ${BASH_SOURCE[0]}))"
source ${selfdir}/../config_env.sh || { echo "cannot locate config_env.sh!" ; exit 1; }
#----------------------------------------------------------------------------

topdir="$(pwd)"

cd ${selfdir} || exit 1

#case "${0}" in
#    *"cisldev-"*)
#        container_img="$(basename ${0})"
#        ;;
#esac

container_img="$(basename ${0})"

make ${container_img}.sif >/dev/null || exit 1

cd ${topdir} || exit 1

unset extra_binds

[ -d /local_scratch ] && extra_binds="--bind /local_scratch ${extra_binds}"

# interactive use
if [ 0 -eq ${#} ]; then
    apptainer \
        --quiet \
        run \
        --nv \
        --cleanenv \
        --bind /glade ${extra_binds} \
        --bind ${workdir}/tmp:/tmp \
        --bind ${workdir}/var/tmp:/var/tmp \
        ${selfdir}/${container_img}.sif
else
    #echo "args=""${@}"
    #set -x
    apptainer \
        --quiet \
        exec \
        --nv \
        --cleanenv \
        --bind /glade ${extra_binds} \
        --bind ${workdir}/tmp:/tmp \
        --bind ${workdir}/var/tmp:/var/tmp \
        ${selfdir}/${container_img}.sif \
        /bin/bash --noprofile --norc --login -c "${@}"
    #set +x
    #echo '$?='${?}
fi

remove_workdir
