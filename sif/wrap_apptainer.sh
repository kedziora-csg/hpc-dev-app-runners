#!/bin/bash

#----------------------------------------------------------------------------
# environment
SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
selfdir="$(dirname $(readlink -f ${BASH_SOURCE[0]}))"
# The site's Apptainer setup: $SIF_ENV if set, as sif/Makefile honours it, or
# else the one sites/<site>/sif_env.sh in this checkout.  Several sites and no
# SIF_ENV is a question only the operator can answer, so it is asked, not guessed.
if [ -z "${SIF_ENV:-}" ]; then
    sif_envs=( "${selfdir}"/../sites/*/sif_env.sh )
    if [ "${#sif_envs[@]}" -ne 1 ] || [ ! -f "${sif_envs[0]}" ]; then
        echo "cannot choose a site's sif_env.sh: found ${#sif_envs[@]} under ${selfdir}/../sites;"
        echo "  set SIF_ENV to the one to use"
        exit 1
    fi
    SIF_ENV="${sif_envs[0]}"
fi
source "${SIF_ENV}" || { echo "cannot source ${SIF_ENV}" ; exit 1; }
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

INSTALL_ROOT=${WORK}/CONTAINERS/${container_img}
mkdir -p ${INSTALL_ROOT}
unset extra_binds

[ -d /local_scratch ] && extra_binds="--bind /local_scratch ${extra_binds}"

# interactive use
if [ 0 -eq ${#} ]; then
    apptainer \
        --quiet \
        run \
        --nv \
        --cleanenv \
        --env WORK=${WORK} \
        --env SCRATCH=${SCRATCH} \
        --env INSTALL_ROOT=${INSTALL_ROOT} \
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
        --env WORK=${WORK} \
        --env SCRATCH=${SCRATCH} \
        --env INSTALL_ROOT=${INSTALL_ROOT} \
        --bind /glade ${extra_binds} \
        --bind ${workdir}/tmp:/tmp \
        --bind ${workdir}/var/tmp:/var/tmp \
        ${selfdir}/${container_img}.sif \
        /bin/bash --noprofile --norc --login -c "${@}"
    #set +x
    #echo '$?='${?}
fi

remove_workdir
