ARG BASE_IMAGE="invalid"

#-------------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS final
#-------------------------------------------------------------------------------

SHELL ["/bin/bash", "--login", "-c"]

ARG BASE_IMAGE="invalid"
ARG MAKE_J_PROCS=2
ARG HPCG_RUN=0

RUN echo "Building HPCG application image from ${BASE_IMAGE} ..." \
    && MAKE_J_PROCS="${MAKE_J_PROCS}" \
       HPCG_RUN="${HPCG_RUN}" \
       /container/extras/build_hpcg.sh \
    && test -x /container/bin/xhpcg \
    && echo "# --> /container/extras/build_hpcg.sh run on $(date) and included in image." >> /container/config_env.sh \
    && docker-clean

# Local Variables:
# mode: dockerfile
# End: