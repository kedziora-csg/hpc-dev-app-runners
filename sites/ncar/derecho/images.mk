# images.mk -- derecho's image sets, for sif/Makefile.
#
# Written from sites/ncar.yaml + sites/ncar/derecho.yaml.  Do not edit: the next
# `hpcrun/sitegen derecho --write` overwrites it, and hpcrun/tests/test_bench.sh
# fails while it is stale.  Change the YAML instead.
#
# Included by sif/Makefile, so `make derecho` builds the set below.

HPCRUN_CLUSTERS += derecho
derecho_site := ncar

derecho_images := leap-oneapi-mpich.sif \
    leap-gcc14-mpich.sif \
    leap-nvhpc-mpich.sif \
    leap-oneapi-openmpi.sif \
    leap-gcc14-openmpi.sif \
    leap-nvhpc-openmpi.sif
derecho_heffte_images := leap-oneapi-mpich-heffte-znver3.sif \
    leap-gcc14-mpich-heffte-znver3.sif \
    leap-nvhpc-mpich-heffte-znver3.sif \
    leap-oneapi-openmpi-heffte-znver3.sif \
    leap-gcc14-openmpi-heffte-znver3.sif \
    leap-nvhpc-openmpi-heffte-znver3.sif
derecho_hpcg_images := leap-oneapi-mpich-hpcg-znver3.sif \
    leap-gcc14-mpich-hpcg-znver3.sif \
    leap-nvhpc-mpich-hpcg-znver3.sif \
    leap-oneapi-openmpi-hpcg-znver3.sif \
    leap-gcc14-openmpi-hpcg-znver3.sif \
    leap-nvhpc-openmpi-hpcg-znver3.sif
cluster_images += $(derecho_images) $(derecho_heffte_images) $(derecho_hpcg_images)
app_images += $(derecho_heffte_images) $(derecho_hpcg_images)

derecho: $(derecho_images)
echo-derecho:
	@echo "$(derecho_images)"
derecho-heffte: $(derecho_heffte_images)
echo-derecho-heffte:
	@echo "$(derecho_heffte_images)"
derecho-hpcg: $(derecho_hpcg_images)
echo-derecho-hpcg:
	@echo "$(derecho_hpcg_images)"
.PHONY: derecho derecho-heffte derecho-hpcg echo-derecho echo-derecho-heffte echo-derecho-hpcg
