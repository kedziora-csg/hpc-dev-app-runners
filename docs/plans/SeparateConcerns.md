# Separating Container Factory from Application Runners

## Executive Summary

**Recommendation:** YES, separate this repository into two. The current structure conflates two distinct responsibilities:
1. **Building and publishing optimized HPC container images** (factory)
2. **Developing, building, and testing applications within those images** (runner)

Separating them would clarify the project's core mission, enable independent release cycles, improve reusability, and make the repository easier to onboard new contributors and users.

---

## Current State Analysis

### What is the factory doing?
- Building multi-layer Docker images with configurable compilers (gcc, nvhpc, oneapi, …), MPI implementations (OpenMPI, MPICH), and scientific libraries (HDF5, NetCDF, PnetCDF, ParallelIO, FFTW, HeFFTe)
- Publishing to DockerHub (`ncarcisl/hpcdev-*`, `benjaminkirk/hpcdev-*`)
- Maintaining compiler/library versions and compatibility matrices
- Validating builds via smoke tests (hello-world, OSU benchmarks)

### What are the "apps" doing?
- Living as **build scripts in `/container/extras`** (WRF, CESM, ESMF, PETSc, DART, MPAS, Kokkos)
- Being copied into the image during build (see `containers/devenv/Makefile`)
- Treated as secondary, optional ("extras" in the naming and file layout)
- **Not currently part of the GHA matrix** — no automated build/test for apps against all compiler/MPI combinations

### The architectural tension
The repo name `demo_github_actions` and CLAUDE.md language ("almost all real work and almost every change happens here" re: the Dockerfile) reveal that the **factory is the primary mission**. Applications are secondary. But they live in the same repo anyway, creating ambiguity about scope.

---

## Why Separate Makes Sense

### 1. **Different stakeholders**
- **Factory repo:** Compiler/library engineers, HPC infrastructure teams, library maintainers
- **App runner repo:** Application developers (WRF, CESM, MPAS modelers), HPC users, benchmark teams

### 2. **Different release cadences**
- **Factory:** Driven by compiler/library updates, distro changes, CUDA/ROCm bumps. Maybe 2–4 releases/year.
- **Apps:** Driven by app-specific needs (new WRF version, PETSc algorithm change). Could be 10+ PRs/year.

### 3. **Different CI/CD workflows**
- **Factory:** Matrix across compilers × MPI × GPU × arch. Build, validate, publish to registry.
- **Apps:** For each app: build on N factory images, run tests/benchmarks, publish results (not images).

### 4. **Different problem spaces**
- **Factory:** "Does this C23 guard work on gcc-16 + OpenMPI? Does NVHPC still ignore `-march=`?" (compiler/library deep dives)
- **Apps:** "Does WRF compile on the nostalgia distro? Does HPCG get the expected GFLOPS on this GPU?" (science/performance)

### 5. **Reusability and collaboration**
- Other projects (NCAR, ORNL, LLNL, universities) can use the factory images **without** inheriting app build scripts they don't want
- Conversely, someone running HPCG benchmarks can pull app-runner workflows without needing the factory's compiler/library history

### 6. **Clearer onboarding**
- New factory contributor: "I'm improving the NVHPC stage" — focus on one repo.
- New app contributor: "I want to build and test ESMF on GPU" — use published factory images, don't need to understand the Dockerfile.

### 7. **Organizational clarity in the GHA matrix**
- Currently, the devel/matrix workflows are primarily *factory* tests (smoke tests are minimal)
- Apps like HPCG, WRF belong in a **separate workflow** or repo that orchestrates app builds on top of factory images
- This also solves the "extras aren't automated" observation — they can be in a proper CI/CD pipeline in their own home

---

## Proposed Architecture

```
hpc-dev-container-factory/          (this repo, renamed + slimmed)
├── .github/workflows/
│   ├── matrix-build-images.yaml     (full production matrix)
│   ├── devel-build-images.yaml      (PR validation)
│   ├── dial-an-image.yaml           (manual single-variant dispatch)
│   └── (remove app-specific workflows)
├── containers/
│   ├── devenv/Dockerfile            (core: compilers, MPI, libraries)
│   ├── demo/Dockerfile              (lightweight demo base)
│   ├── test/Dockerfile              (OSU microbenchmarks, report_cpu_features)
│   └── publish/Dockerfile           (SBOM, final push)
├── scripts/build_common.cfg          (shared config)
├── containers/deploy/ncar-hpc/      (KEEP: cluster-specific launcher configs)
│                                     (these are how factory *outputs* are deployed,
│                                      not how they're built)
└── CLAUDE.md (updated scope)

hpc-dev-app-runners/                (new repo, separate)
├── .git (submodule: hpc-dev-container-factory)
│   └── factory/                     (as a git submodule)
├── .github/workflows/
│   ├── matrix-build-apps.yaml       (build HPCG, WRF, etc. on factory images)
│   ├── hpcg-bench.yaml              (HPCG-specific: build, run, publish results)
│   ├── wrf-test.yaml                (WRF-specific: compile, validate)
│   └── …
├── apps/
│   ├── hpcg/
│   │   ├── build.sh
│   │   ├── run.sh
│   │   └── .github/workflows/ (app-specific CI if complex)
│   ├── wrf/
│   │   ├── build.sh
│   │   └── run.sh
│   └── …
├── scripts/
│   └── (app-runner utilities, not factory scripts)
└── CLAUDE.md (app-runner scope)
```

**Key point:** The factory repo becomes purely about *building and publishing images*. The app-runner repo uses those published images as a base layer and orchestrates app builds.

---

## Migration Path

### Phase 1: Prepare the factory repo (no breaking changes)
1. Remove app-specific scripts and workflows (or move to `deprecated/`)
2. Update CLAUDE.md to clarify that factory outputs are images, not apps
3. Ensure all library/compiler versions are documented in workflow matrices
4. Tag the last "combined" state as `factory-release-v1.0`

### Phase 2: Create the app-runner repo
1. Initialize `hpc-dev-app-runners` with factory as a submodule
2. Move `scripts/build_*.sh` for apps (WRF, CESM, ESMF, PETSc, DART, MPAS, Kokkos) → `apps/*/build.sh`
3. Create `apps/hpcg/` with build + run + CI workflow
4. Write GHA workflows that:
   - Pin factory image versions (e.g., `ncarcisl/hpcdev-gcc15-openmpi:latest`)
   - Build each app on N factory images (subset of the full matrix)
   - Run smoke tests / benchmarks
   - Upload results (or publish benchmark data to a dashboard)

### Phase 3: Transition and deprecation
1. Announce both repos with clear scopes (README updates, GHA topics)
2. Redirect issues/PRs: factory issues → factory repo, app issues → app-runner repo
3. After a grace period, archive the old repo or mark it as superseded

---

## Handling Shared Concerns

### Deploy configs (`containers/deploy/ncar-hpc/`)
- **Keep in factory repo.** These describe how factory *outputs* (container images) are deployed on HPC clusters
- They're tied to image specifications, not app specifications
- App-runner can reference them via submodule if needed for context

### `build_common.cfg` and utilities
- **Keep in factory** as `scripts/build_common.cfg` (for in-image library builds)
- **App-runner can copy or inherit** utilities it needs (or source from factory submodule)
- Avoid circular dependencies: app-runner scripts should not depend on factory scripts being installed

### Container base selection (distro, compiler, MPI)
- **Factory:** Declares what combinations exist
- **App-runner workflows:** Pin specific combinations to test against (e.g., "test HPCG on `{gcc15, oneapi} × {openmpi, mpich}` on almalinux10-cuda")
- App-runner passes factory image URIs (e.g., `ghcr.io/ncarcisl/hpcdev-gcc15-openmpi:latest`) to `docker run` or Apptainer

---

## Specific benefits for your HPCG use case

### Today (single repo):
- ✗ Build HPCG into the container factory image → bloats the image, tightly couples HPCG to factory release cycle
- ✗ Build HPCG in the Dockerfile → factory repo must maintain HPCG build logic alongside compiler logic
- ✗ No automated matrix test: HPCG on {gcc, nvhpc, oneapi} × {openmpi, mpich} across distros

### After separation:
- ✓ Add `apps/hpcg/build.sh` to app-runner repo
- ✓ Write a workflow (`hpcg-bench.yaml`) that:
  - Pulls the factory image (e.g., `ncarcisl/hpcdev-gcc15-openmpi:latest`)
  - Runs `docker run … /app-runner/apps/hpcg/build.sh` to build HPCG inside
  - Runs `/app-runner/apps/hpcg/run.sh` to execute benchmarks
  - Uploads results to a database or artifact
- ✓ Automate this across the compiler/MPI matrix without modifying the factory
- ✓ Decouple HPCG development from factory release cycles
- ✓ Reuse the same pattern for WRF, CESM, MPAS, etc.

---

## Potential drawbacks and mitigations

| Drawback | Mitigation |
|----------|-----------|
| **Two repos to manage** | Document scope in each README; add CI badge linking them; clarify in GHA topics. |
| **Submodule complexity** | Use submodules but document the standard clone: `git clone --recursive`. Provide a Makefile target for updates. |
| **Harder to test factory changes against apps** | Create a `test-factory-with-apps` workflow in app-runner triggered by factory releases (or manual dispatch). Publish `main`-branch images and test against those. |
| **Risk of divergence** | Sync CLAUDE.md and versioning docs across both repos. Use releases/tags to tie them together (e.g., "factory v1.2 is tested against app-runner commits abc123..def456"). |
| **API breaking changes** | Factory image environment variables and directory structures must be stable. Document the "contract" (e.g., `/container/config_env.sh`, `$INSTALL_ROOT`). Bump versions if the contract changes. |

---

## Implementation checklist

### If you decide to separate:

**Factory repo (`hpc-dev-container-factory`):**
- [ ] Rename repo or update scope in README
- [ ] Remove app-specific scripts (or archive in `deprecated/`)
- [ ] Remove app-specific workflows or mark them deprecated
- [ ] Update CLAUDE.md: clarify that the factory *produces images*, not apps
- [ ] Document the "contract" (environment variables, directory structure, `/container/config_env.sh` format)
- [ ] Tag final state: `v1.0-factory-only`
- [ ] Update GHA topics/description

**App-runner repo (new: `hpc-dev-app-runners`):**
- [ ] Create repo with factory as a submodule
- [ ] Set up directory structure: `apps/{hpcg,wrf,cesm,…}/`
- [ ] Write `apps/hpcg/build.sh` and `apps/hpcg/run.sh`
- [ ] Create `hpcg-bench.yaml` workflow (matrix on factory images)
- [ ] Write CLAUDE.md for app-runner scope
- [ ] Update top-level README with usage examples
- [ ] (Optional) Set up benchmark results database or publishing

### If you stay unified:

- [ ] Rename `scripts/` to `factory/` and `extras/` to clarify scope
- [ ] Update CLAUDE.md to clearly separate factory vs. app concerns
- [ ] Add app-specific workflows (e.g., `matrix-build-apps.yaml`)
- [ ] Automate HPCG, WRF, etc. in the GHA matrix (at least in devel)
- [ ] Consider using directory organization (e.g., `factory/`, `apps/`) to signal intent

---

## Recommendation

**Separate the repos.** Here's why:

1. The factory has a clear, cohesive mission: **build and publish optimized HPC images**
2. Applications are a different concern: **use and test those images**
3. The "extras" convention signals that apps are already de facto separate
4. HPCG (and future benchmarks) deserve first-class CI/CD, not a hidden build script
5. Other organizations can cleanly reuse the factory without app baggage
6. Contributors and users have a clear mental model: factory = base, app-runner = what you build with it

The submodule structure keeps them linked (you can clone both with one command) while maintaining separation of concerns.

---

## Related reading
- [Docker official multi-project pattern](https://docs.docker.com/build/guide/multi-project/)
- [Monorepo vs. multirepo trade-offs](https://medium.com/@lucamezzalira/monorepo-vs-multi-repo-and-enterprise-applications-e9b4833fe32c)
- [Git submodules best practices](https://git-scm.com/book/en/v2/Git-Tools-Submodules)
