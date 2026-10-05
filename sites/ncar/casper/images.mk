# images.mk -- casper's image sets, for sif/Makefile.
#
# Written from sites/ncar.yaml + sites/ncar/casper.yaml.  Do not edit: the next
# `hpcrun/sitegen casper --write` overwrites it, and hpcrun/tests/test_bench.sh
# fails while it is stale.  Change the YAML instead.
#
# Included by sif/Makefile, so `make casper` builds the set below.

HPCRUN_CLUSTERS += casper
casper_site := ncar

casper_images := leap-oneapi-openmpi.sif \
    leap-gcc14-openmpi.sif \
    leap-nvhpc-openmpi.sif
casper_blas_images := leap-oneapi-openmpi-blas-znver3.sif \
    leap-gcc14-openmpi-blas-znver3.sif \
    leap-nvhpc-openmpi-blas-znver3.sif
casper_heffte_images := leap-oneapi-openmpi-heffte-znver3.sif \
    leap-gcc14-openmpi-heffte-znver3.sif \
    leap-nvhpc-openmpi-heffte-znver3.sif
casper_hpcg_images := leap-oneapi-openmpi-hpcg-znver3.sif \
    leap-gcc14-openmpi-hpcg-znver3.sif \
    leap-nvhpc-openmpi-hpcg-znver3.sif
cluster_images += $(casper_images) $(casper_blas_images) $(casper_heffte_images) $(casper_hpcg_images)
app_images += $(casper_blas_images) $(casper_heffte_images) $(casper_hpcg_images)

casper: $(casper_images)
echo-casper:
	@echo "$(casper_images)"
casper-blas: $(casper_blas_images)
echo-casper-blas:
	@echo "$(casper_blas_images)"
casper-heffte: $(casper_heffte_images)
echo-casper-heffte:
	@echo "$(casper_heffte_images)"
casper-hpcg: $(casper_hpcg_images)
echo-casper-hpcg:
	@echo "$(casper_hpcg_images)"
.PHONY: casper casper-blas casper-heffte casper-hpcg echo-casper echo-casper-blas echo-casper-heffte echo-casper-hpcg
