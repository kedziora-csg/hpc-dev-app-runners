# Placement checker fixtures

Frozen `report_placement` output, used as golden files by `../self_test.sh`
(does the checker reach the right verdict?) and `../test_rules.sh` (does it name
the right pathology?).

There are two kinds, kept apart on purpose.

## Captured — real Derecho runs

Job 7092561, two nodes, leap-gcc14 images. These are measurements.

| file | how it was launched | what it shows |
|---|---|---|
| `bound_mpich.out` | `-ppn 8 --cpu-bind core -d 16` | the good case: 1 thread per physical core, 2 L3 groups/rank |
| `trap_mpich.out` | `-ppn 8` (no binding flags) | Cray PALS pins each *rank* to one hardware thread, so all 16 OpenMP threads pile onto a single core |
| `trap_openmpi.out` | `-N 8` (no binding flags) | Open MPI core-pins each thread correctly, but *ranks* overlap: 8 threads per core |

`topology.json` beside them is Derecho's probed node topology
(`../probe_topology.sh`). The checker resolves it from the directory of the
report file, which is what lets these run on a login node — or a laptop — and
still be judged with Derecho's cache and NUMA geometry.

## Derived — constructed, in `derived/`

Mechanically transformed from `bound_mpich.out` by `derived/make_derived.sh`,
never hand-edited. They cover pathologies that would otherwise need node hours
and a deliberately misconfigured launcher to observe. See that script's header
for what each one is and why.

## Why these are files and not a live sweep

`Placement_derecho.pbs` used to run the no-binding-flags case on real nodes after
every good run, as a negative control -- proof that the checker can actually
*detect* bad placement, rather than having silently degraded into something that
always passes.

That control is worth keeping; paying for it in node hours is not. Across six
images the trap output varied only with the MPI family, never with the compiler
-- the one thing those images actually differ in -- so four of the six runs were
pure duplication, and the sweep doubled the job's cost to re-derive a constant.

Frozen inputs are also a *stronger* control than a live run, because they cannot
drift: if someone rewrites the checker such that it always returns OK, these
files fail immediately, on a login node, in milliseconds.

The opposite degradation matters just as much. A checker that reports a
pathology on a *good* run gets ignored, and an ignored checker detects nothing
either. The fixtures that must come out **clean** — `bound_mpich.out` and three
of the derived ones — are the guard against that, and they are the reason
`expected/*.rules` asserts the fired set in both directions.

## Expectations

`expected/<fixture>.rules` lists the rule names that must fire on that fixture —
exactly, in both directions. Every fixture must have one; a fixture without an
expectation file fails rather than being skipped.

Adding a pathological case is three steps: drop the run into `fixtures/` (or add
a transform to `derived/make_derived.sh`), add one `rule` line to
`../placement_rules.sh`, and write the expectation file.

## Refreshing

The captured files only need regenerating if `report_placement`'s output format
changes. Re-run the relevant launch line from a `# launch` header inside the file
itself, then copy the result back over the fixture, re-run
`derived/make_derived.sh`, and re-run `../self_test.sh`.
