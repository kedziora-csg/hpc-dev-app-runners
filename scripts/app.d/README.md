# The app contract

Everything an application must provide so an app-agnostic runner can drive it.
The runner never learns an application's name.

```
app.d/<app>/
    app.yaml    metadata, declared metrics, requirements
    prepare     prepare <rundir>  -- write inputs.  Optional.
                                     Exit non-zero to DECLINE this cell.
    launch      print the argv to run.  Optional; default is `binary` from app.yaml.
    extract     extract <rundir>  -- print `key=value` lines to stdout.  Optional.
```

**An app with no hooks at all is legal.** An `app.yaml` with just `binary:` gets
you wall time and nothing else. That zero-effort entry point is the point: a
contract nobody can satisfy in ten minutes gets bypassed.

## Where these live at run time

Installed into the image by `build_<app>.sh`, at `/container/app.d/<app>/`. The
`.sif` then fully describes what it can run, the extractor travels with the app
*version* it was written against, and a recorded result can name an image digest
and mean it.

Fixing an extractor therefore means rebuilding an image, so the runner also
honours `BENCH_APP_DIR=<host path>` to override — bind-mounted in, for fast
iteration. Results produced that way carry `app_dir_override: true` and are never
mistaken for reproducible ones. The override path must be under a directory the
launcher binds (on Derecho, `/glade`), because the hooks run *inside* the
container either way.

## What the hooks are handed

Every app gets the same variables, so a hook is a small shell script and not an
argument-parsing exercise.

| Variable | Meaning |
|---|---|
| `BENCH_APP` | app name |
| `BENCH_RUNDIR` | private, empty, writable working directory for this cell |
| `BENCH_NODES` | nodes in this job |
| `BENCH_RANKS` | total ranks |
| `BENCH_RANKS_PER_NODE`, `BENCH_THREADS` | the decomposition |
| `BENCH_PLACEMENT` | placement name (`ccd`, `numa`, …) — labelling only |
| `BENCH_SCALE` | app-defined size class (`smoke`, `node`, `weak`, `strong`) |
| `BENCH_TARGET_SECONDS` | how long the run should aim to take |
| `BENCH_CORES_PER_NODE`, `BENCH_CORES_PER_L3`, `BENCH_CORES_PER_NUMA` | probed topology, for apps that size inputs from cache or memory |
| `BENCH_SCRATCH` | site scratch, for apps needing large input trees |

## Rules

- `prepare` writes into `$BENCH_RUNDIR` and nowhere else. Exit non-zero to
  decline a cell — the runner records it as skipped, with the reason, rather
  than failing the job.
- `extract` reads only `$BENCH_RUNDIR`, does no network, and prints `key=value`.
  **Unparseable output is a missing metric, not a failed run**: exit 0 with no
  output.
- `extract` prints `valid=true|false` when the app can judge its own result. A
  `valid=false` row is recorded but never wins a comparison.
- `launch` prints one line of argv. Use it for flags; use `prepare` for files.

## Adding an app

1. Write `app.d/<name>/app.yaml`. `binary:` alone is a legal contract.
2. Add hooks only where the app needs them.
3. Install it from `build_<name>.sh` — one `cp -R`, see `build_hpcg.sh`.
4. Prove it: `libexec/test_app_contract.sh` runs every contract here against a
   stub launcher, with no cluster and no container.

If adding an app requires editing the runner, the contract has failed and the
runner is what needs fixing.
