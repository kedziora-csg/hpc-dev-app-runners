#-------------------------------------------------------------------------------
# apps/Dockerfile -- one application built on top of a published base image.
#
#     docker build -f apps/Dockerfile --build-arg APP=hpcg \
#         --build-arg BASE_IMAGE=<registry>/<repo>:<os>-<compiler>-<mpi>-latest .
#
# The build context is the REPOSITORY ROOT, and the app's recipe comes from
# apps/${APP}/ in it -- build.sh and the contract in app.d/ beside it -- so a
# fix to an app's build or its extractor needs no base rebuild.
# From the base this relies on its contract only (CONTRACT.md in
# NCAR/hpc-dev-container-factory): /container/config_env.sh,
# /container/extras/build_common.cfg, MARCH_FLAGS, the compilers and the MPI
# wrappers.
#
# Driven by .github/workflows/app-image-builder-ghcr.yaml, which also sets the
# image's labels -- what app, which version, which base, which target -- so a
# .sif made from it can say what it is without anyone parsing its file name.
#-------------------------------------------------------------------------------
ARG BASE_IMAGE="invalid"

#-------------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS final
#-------------------------------------------------------------------------------

SHELL ["/bin/bash", "--login", "-c"]

ARG APP="invalid"
ARG MAKE_J_PROCS=2

#-------------------------------------------------------------------------------
# Microarchitecture for the APPLICATION, independent of the base image.
#
# The base image sets MARCH_FLAGS once, for every library in it, and that value
# has to suit every consumer of that image.  An application is built for one
# target and can afford to be specific: the workflow reads the spelling from the
# images: block of the cluster description it builds for (-march=znver3, or
# -tp=zen3 for nvhpc, which ignores -march= silently).
#
# Empty means inherit whatever the base image set.  A value overrides it FOR
# THIS BUILD ONLY; nothing in the base image is rebuilt or changed.  The app's
# build.sh applies it, not this file, so nothing that re-sources the image
# environment later can clobber it, and it stamps the effective value into the
# installed app.yaml.
#-------------------------------------------------------------------------------
ARG APP_MARCH_FLAGS=""

COPY apps/${APP}/ /container/apps-src/${APP}/

# HPCG_RUN=0 skips the recipe's own post-build run: the workflow smoke-tests the
# published image through the app contract instead, which is the same path a
# cluster job takes.
RUN test -x "/container/apps-src/${APP}/build.sh" \
        || { echo "apps/${APP}/build.sh is missing or not executable"; exit 1; } \
    && echo "Building ${APP} from apps/${APP}/ ..." \
    && MAKE_J_PROCS="${MAKE_J_PROCS}" \
       HPCG_RUN=0 \
       APP_MARCH_FLAGS="${APP_MARCH_FLAGS}" \
       "/container/apps-src/${APP}/build.sh" \
    && test -f "/container/app.d/${APP}/app.yaml" \
        || { echo "apps/${APP}/build.sh installed no contract at /container/app.d/${APP}"; exit 1; } \
    && echo "# --> apps/${APP}/build.sh run on $(date) and included in image." >> /container/config_env.sh \
    && rm -rf /container/apps-src /tmp/* /var/tmp/*

# Local Variables:
# mode: dockerfile
# End:
