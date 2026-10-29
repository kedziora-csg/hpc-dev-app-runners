# Plans

The design record, kept beside the code it describes. Each plan dates its
decisions; where two disagree, the later date holds.

| Plan | What it covers | Status |
|---|---|---|
| [BenchmarkRunnerPlan.md](BenchmarkRunnerPlan.md) | The runner: the app contract, the site contract, placement checks, the experiment and results formats, and the phases that built them. §10 has the phases, §11 the open questions, §12 the decisions. | **Current.** Phase 5b (per-sub-cluster app targets) is done, 2026-10-29. Phase 4.6 (Slurm, for TACC) waits for an account. |
| [BenchRunnerPlanAddendum.md](BenchRunnerPlanAddendum.md) | Phase 4.7: laying the repository out by concern, which gave `apps/`, `sif/`, `hpcrun/` and `sites/`. | Done. Its paths under `containers/` and `scripts/` describe the repository before the factory left. |
| [ImagePublishingPlan.md](ImagePublishingPlan.md) | Who builds the base images and where they are published: option D, the factory in `NCAR/hpc-dev-container-factory`, and the switch of this repository onto its images (§5). | Steps 3 and 4 of §5 done, 2026-10-29: Derecho and Casper run app images built here on the factory's base. The move to `NCAR/hpc-dev-app-runners` is left. |
| [SeparateConcerns.md](SeparateConcerns.md), [SeparationAnalysis.md](SeparationAnalysis.md) | The first arguments, August 2026, that the factory and the runner should be separate. | Superseded. The split they argued for has happened, but not in the shape they sketched: no submodule, no `run.sh` per app, and the deployment scripts went with the runner, not the factory. |

The factory's own record -- its `CLAUDE.md`, `CONTRACT.md` and history -- is in
[NCAR/hpc-dev-container-factory](https://github.com/NCAR/hpc-dev-container-factory).
