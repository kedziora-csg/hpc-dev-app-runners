# Placement checker fixtures

Captured `report_placement` output from real Derecho runs (job 7092561, two
nodes, leap-gcc14 images), frozen here as golden files for `../self_test.sh`.

| file | how it was launched | what it shows |
|---|---|---|
| `bound_mpich.out` | `-ppn 8 --cpu-bind core -d 16` | the good case: 1 thread per physical core, 2 L3 groups/rank |
| `trap_mpich.out` | `-ppn 8` (no binding flags) | Cray PALS pins each *rank* to one hardware thread, so all 16 OpenMP threads pile onto a single core |
| `trap_openmpi.out` | `-N 8` (no binding flags) | Open MPI core-pins each thread correctly, but *ranks* overlap: 8 threads per core |

## Why these are files and not a live sweep

`Placement_derecho.pbs` used to run the no-binding-flags case on real nodes after
every good run, as a negative control -- proof that `check_placement` /
`placement_summary` can actually *detect* bad placement, rather than having
silently degraded into something that always passes.

That control is worth keeping; paying for it in node hours is not. Across six
images the trap output varied only with the MPI family, never with the compiler
-- the one thing those images actually differ in -- so four of the six runs were
pure duplication, and the sweep doubled the job's cost to re-derive a constant.

Frozen inputs are also a *stronger* control than a live run, because they cannot
drift: if someone rewrites the checker such that it always returns OK, these
files fail immediately, on a login node, in milliseconds.

## Refreshing

These only need regenerating if `report_placement`'s output format changes.
Re-run the relevant launch line from a `# launch` header inside the file itself,
then copy the result back over the fixture and re-run `../self_test.sh`.
