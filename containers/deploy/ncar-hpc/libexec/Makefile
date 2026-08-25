# The registry the Deffiles bootstrap from.  Stated once here so the digest
# pinning below and the `From:` lines in Deffile/Deffile.apps cannot drift apart.
#
# hpcdev-derecho, not hpcdev: these images target this machine's CPU
# (-march=znver3) and are not the portable factory images.  Same tag names, a
# different promise, so a different repository -- see derecho-images-ghcr.yaml.
GHCR_BASE_REF := ghcr.io/kedziora-csg/hpcdev-derecho-x86_64
GHCR_APPS_REF := ghcr.io/kedziora-csg/hpcdev-apps-x86_64

openmpi_images := almalinux9-gcc-openmpi.sif \
                  almalinux9-gcc14-openmpi.sif \
                  almalinux9-aocc-openmpi.sif \
                  almalinux9-nvhpc-openmpi.sif \
                  almalinux9-oneapi-openmpi.sif

mpich_images := $(subst openmpi,mpich,$(openmpi_images))
mpich3_images := $(subst openmpi,mpich3,$(openmpi_images))
cpu_images := $(openmpi_images) $(mpich_images) $(mpich3_images)
cuda_images := $(subst .sif,-cuda.sif,$(cpu_images))
all_images :=  $(cuda_images) $(cpu_images)
all: $(all_images)

# The blessed Derecho deployment set: leap x {oneapi, gcc14, nvhpc} x {mpich,
# openmpi}.  leap because openSUSE Leap 15 is built from the same SLE 15 SP6
# sources as Derecho's host OS; those three compilers because they are the ones
# NCAR provides modules for (gcc14 matches gcc/14.3.0 exactly); mpich because
# only MPICH can be displaced by Cray MPICH's ABI shim, openmpi to test the
# alternative.  Used by ../submit_placement_matrix.sh.
derecho_images := leap-oneapi-mpich.sif \
                  leap-gcc14-mpich.sif \
                  leap-nvhpc-mpich.sif \
                  leap-oneapi-openmpi.sif \
                  leap-gcc14-openmpi.sif \
                  leap-nvhpc-openmpi.sif
derecho_hpcg_images := $(patsubst %.sif,%-hpcg.sif,$(derecho_images))

derecho: $(derecho_images)
derecho-hpcg: $(derecho_hpcg_images)

echo-derecho:
	@echo "$(derecho_images)"

echo-derecho-hpcg:
	@echo "$(derecho_hpcg_images)"

echo:
	@echo "$(all_images)"

# What is on disk, and what the registry says now.  The answer to "is my .sif
# current?", which `make` alone cannot tell you once a .sif exists.
check-images:
	@for i in $(derecho_images); do \
	    t="$${i%.sif}" ; \
	    have="$$(apptainer inspect $$i 2>/dev/null \
	             | sed -n 's/.*image.base.digest[": ]*\([a-z0-9:]*\).*/\1/p' | head -1)" ; \
	    want="$$(./pin_image_digest.sh --resolve $(GHCR_BASE_REF):$$t-latest 2>/dev/null)" ; \
	    if   [ ! -f "$$i" ];              then state="no .sif -- run make derecho" ; \
	    elif [ -z "$$want" ];             then state="cannot reach the registry" ; \
	    elif [ "$$have" = "$$want" ];     then state="current" ; \
	    elif [ -z "$$have" ];             then state="STALE? built before digests were stamped" ; \
	    else                                   state="STALE -- has $${have#sha256:} want $${want#sha256:}" ; fi ; \
	    printf "  %-34s %s\n" "$$i" "$$state" ; \
	done

# The placement checker's regression suite.  No node hours, no container, no
# scheduler -- it runs against the frozen reports in fixtures/, so run it after
# any edit to check_placement.sh, placement_rules.sh or probe_topology.sh.
test:
	@./self_test.sh
	@echo
	@./test_results.sh
	@echo
	@./test_app_contract.sh

clean:
	rm -f *~

pristine:
	git clean -xdf -e "*.sif"

# Each .def is pinned to the DIGEST its `-latest` tag resolves to, so the build
# is immutable and the resulting .sif can name the image it came from.  See
# pin_image_digest.sh -- if resolution fails the build still proceeds from the
# tag, with the digest recorded as `unknown`.
#
# The digest is re-resolved on EVERY make, via FORCE, but the .def is only
# replaced when the resolved digest actually differs.  That combination is what
# makes `make derecho` mean "give me the current images":
#
#   - resolve every time, or a moved upstream tag is invisible and make reports
#     everything up to date while the .sif on disk is weeks old;
#   - replace only on change, or every make would touch the .def and rebuild all
#     six .sif files whether or not anything moved.
#
# .PRECIOUS keeps make from treating .def as an intermediate and deleting it
# after the build -- without it there is nothing to compare against next time,
# and the "only on change" half stops working.
#
# '$*' matches the '%' part, see https://www.gnu.org/software/make/manual/html_node/Automatic-Variables.html
.PHONY: FORCE
FORCE:

.PRECIOUS: %.def %-hpcg.def

# repin <deffile> -- keep, replace, or decline to replace the generated .def.
define repin
	if ! grep -q '@sha256:' $@.tmp && [ -f $@ ]; then \
	    echo "  $@: digest lookup failed; keeping the existing pin" ; \
	    rm -f $@.tmp ; \
	elif cmp -s $@.tmp $@ 2>/dev/null; then \
	    rm -f $@.tmp ; \
	else \
	    mv $@.tmp $@ ; \
	    echo "  $@: upstream image changed -- $@ will rebuild" ; \
	fi
endef

%-hpcg.def: Deffile.apps pin_image_digest.sh FORCE
	@cp $< $@.tmp
	@sed -i 's/<PLACEHOLDER_IMG_TAG>/$*-hpcg/g' $@.tmp
	@./pin_image_digest.sh --pin $@.tmp $(GHCR_APPS_REF):$*-hpcg-latest
	@$(repin)

%.def: Deffile pin_image_digest.sh FORCE
	@cp $< $@.tmp
	@sed -i 's/<PLACEHOLDER_IMG_TAG>/$*/g' $@.tmp
	@./pin_image_digest.sh --pin $@.tmp $(GHCR_BASE_REF):$*-latest
	@$(repin)

%.sif: %.def Makefile ../config_env.sh
	@echo "Constructing $@ from $<"
	rm -f $@
	source ../config_env.sh ; \
	module list ; \
	which apptainer ; \
	echo "using workdir=$${workdir}" ; \
	apptainer \
	  build \
	  --bind $${workdir}/tmp:/tmp \
	  --bind $${workdir}/var/tmp:/var/tmp \
	  --force \
	  $@ $< ; \
	rm -rf $${workdir}
	@ls -ltrh $@
	@mkdir -p ../bin/ && cd ../bin/ && ln -sf ../libexec/wrap_apptainer.sh $*
