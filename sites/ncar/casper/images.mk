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
casper_hpcg_images := leap-oneapi-openmpi-hpcg-znver3.sif \
    leap-gcc14-openmpi-hpcg-znver3.sif \
    leap-nvhpc-openmpi-hpcg-znver3.sif
cluster_images += $(casper_images) $(casper_hpcg_images)
app_images += $(casper_hpcg_images)

casper: $(casper_images)
echo-casper:
	@echo "$(casper_images)"
casper-hpcg: $(casper_hpcg_images)
echo-casper-hpcg:
	@echo "$(casper_hpcg_images)"
.PHONY: casper casper-hpcg echo-casper echo-casper-hpcg
