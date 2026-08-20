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

# The placement checker's regression suite.  No node hours, no container, no
# scheduler -- it runs against the frozen reports in fixtures/, so run it after
# any edit to check_placement.sh, placement_rules.sh or probe_topology.sh.
test:
	@./self_test.sh

clean:
	rm -f *~

pristine:
	git clean -xdf -e "*.sif"

# '$*' matches the '%' part, see https://www.gnu.org/software/make/manual/html_node/Automatic-Variables.html
%-hpcg.def: Deffile.apps
	@echo "Constructing $@ from $<"
	@rm -f $@
	@cp $< $@.tmp
	@sed -i 's/<PLACEHOLDER_IMG_TAG>/$*-hpcg/g' $@.tmp
	@mv $@{.tmp,}

%.def: Deffile
	@echo "Constructing $@ from $<"
	@rm -f $@
	@cp $< $@.tmp
	@sed -i 's/<PLACEHOLDER_IMG_TAG>/$*/g' $@.tmp
	@mv $@{.tmp,}

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
