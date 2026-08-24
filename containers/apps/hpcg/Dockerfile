ARG BASE_IMAGE="invalid"

#-------------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS final
#-------------------------------------------------------------------------------

SHELL ["/bin/bash", "--login", "-c"]

ARG BASE_IMAGE="invalid"
ARG MAKE_J_PROCS=2
ARG HPCG_RUN=0

#-------------------------------------------------------------------------------
# Microarchitecture for the APPLICATION, independent of the base image.
#
# The base image sets MARCH_FLAGS once, for every library in it, and that value
# is a compromise: it has to suit every consumer of that image.  An application
# is built for one machine and can afford to be specific -- Derecho is Zen 3, so
# -march=znver3 (or -tp=zen3 for nvhpc) is available to it in a way it is not to
# a general-purpose base image.
#
# Empty means inherit whatever the base image set, which is the safe default and
# the current behaviour.  A value overrides it FOR THIS BUILD ONLY; nothing in
# the base image is rebuilt or changed.
#
# The spelling is per compiler family and is not translated here: nvc rejects
# -march= and silently ignores it, so pass -tp= for nvhpc images.  On aarch64
# neither spelling applies; use -mcpu=.
#
# build_hpcg.sh applies it, not this file, so that nothing which re-sources the
# image environment later can clobber it.  It also stamps the effective value
# into the installed app.yaml, so a benchmark row records what it measured.
#-------------------------------------------------------------------------------
ARG APP_MARCH_FLAGS=""

RUN echo "Building HPCG application image from ${BASE_IMAGE} ..." \
    && MAKE_J_PROCS="${MAKE_J_PROCS}" \
       HPCG_RUN="${HPCG_RUN}" \
       APP_MARCH_FLAGS="${APP_MARCH_FLAGS}" \
       /container/extras/build_hpcg.sh \
    && test -x /container/bin/xhpcg \
    && echo "# --> /container/extras/build_hpcg.sh run on $(date) and included in image." >> /container/config_env.sh \
    && docker-clean

# Local Variables:
# mode: dockerfile
# End: