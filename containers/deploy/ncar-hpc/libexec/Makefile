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

echo:
	@echo "$(all_images)"

clean:
	rm -f *~

pristine:
	git clean -xdf -e "*.sif"

# '$*' matches the '%' part, see https://www.gnu.org/software/make/manual/html_node/Automatic-Variables.html
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
