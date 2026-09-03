#!/bin/bash
#-------------------------------------------------------------------------------
# test_bench.sh -- the host side of the runner, checked with no cluster.
#
#     ./test_bench.sh
#
# No PBS, no container, no node hours.  Everything here is a property of the
# config format and the expansion, which is exactly the part that has to be
# right before a job is worth queueing -- and the part a schema exists to make
# checkable in a second.
#
# What it covers:
#
#   both YAML readers agree      PyYAML and the built-in subset, on every file
#                                we ship.  They are two implementations of one
#                                format, and this is the only thing that stops
#                                them drifting.
#   the shipped files validate   experiments against experiment.json, contracts
#                                against app.json
#   the schema catches mistakes  and with the RIGHT exit code, because the exit
#                                code is the interface
#   the reference is current     schema/README.md is generated from the schemas,
#                                and every key is either described or listed as
#                                not described yet
#   validate and submit agree    on the same file, the same exit code.  They
#                                share one gate (checks.preflight); this is what
#                                stops a caller growing a check of its own.
#   the expansion is right       job and cell counts, per_job semantics, the
#                                job.env <-> runner.sh contract
#   generated jobs are complete  no unfilled @PLACEHOLDER@, and a job.env that
#                                bash can actually source
#
# Run it after any edit under bench/.  Adding an experiment should need no edit
# here; adding a config KEY should need one line in the schema and none here.
#-------------------------------------------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${HERE}" || exit 1

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
pass=0 fail=0

ok   () { echo "  ok    $1"; pass=$((pass + 1)); }
bad  () { echo "  FAIL  $1"; shift; [ $# -gt 0 ] && printf '        %s\n' "$@"; fail=$((fail + 1)); }
want () { # want <description> <expected> <actual>
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected: $2" "got:      $3"; fi
}

# Every check runs against THIS checkout's site profiles, never an operator's
# ~/.config copy: the numbers below depend on which images the Makefile lists.
# Default to Derecho, which is what the hand-written cases below assume, and
# override per file where an experiment names a different machine -- a second
# site is exactly the thing that made a single pinned profile wrong.
export BENCH_SITE_CONF="${HERE}/../sites/derecho/site.sh"

conf_for () { # conf_for <experiment.yaml> -- the profile that file's site: names
    local site
    site="$(sed -n 's/^site:[[:space:]]*//p' "$1" | head -1)"
    echo "${HERE}/../sites/${site:-derecho}/site.sh"
}

# A directory of empty files standing in for the .sif set, so the image check
# has something to find.  An empty file is enough: nothing here opens one.
export BENCH_IMAGE_DIR="${TMP}/img"
mkdir -p "${BENCH_IMAGE_DIR}"
for img in $(cd ../ncar-hpc/libexec && make --no-print-directory echo-derecho-hpcg); do
    : > "${BENCH_IMAGE_DIR}/${img}"
done

echo "bench host side"
echo

#-- the two YAML readers agree, file by file -----------------------------------
echo "yaml readers"
for f in experiments/*.yaml ../sites/*.yaml ../../../scripts/app.d/*/app.yaml; do
    python3 - "$f" <<'PY' && ok "$(basename "$(dirname "$f")")/$(basename "$f"): PyYAML == built-in reader" \
                          || bad "$(basename "$(dirname "$f")")/$(basename "$f"): the two readers disagree"
import sys
sys.path.insert(0, ".")
from benchlib import yamlish
text = open(sys.argv[1]).read()
if not yamlish.HAVE_PYYAML:
    sys.exit(0)                    # nothing to compare against; not a failure
a = yamlish.loads(text)
b = yamlish._Fallback(text, sys.argv[1]).parse()
sys.exit(0 if a == b else 1)
PY
done

#-- everything we ship validates -----------------------------------------------
echo
echo "shipped files"
for f in experiments/*.yaml; do
    BENCH_SITE_CONF="$(conf_for "$f")" ./validate "$f" >/dev/null 2>&1
    rc=$?
    # 5 is image-missing, which depends on what is on this disk, not on the file.
    if [ "${rc}" -eq 0 ] || [ "${rc}" -eq 5 ]; then ok "$(basename "$f") validates"
    else bad "$(basename "$f") does not validate (exit ${rc})" \
             "$(BENCH_SITE_CONF="$(conf_for "$f")" ./validate "$f" 2>&1 | tail -5)"; fi
done
./validate --app ../../../scripts/app.d/*/app.yaml >/dev/null 2>&1 \
    && ok "every app.yaml satisfies bench/schema/app.json" \
    || bad "an app.yaml fails bench/schema/app.json" "$(./validate --app ../../../scripts/app.d/*/app.yaml 2>&1)"

#-- the reference is generated, so it cannot be stale or incomplete quietly -----
echo
echo "schema reference"
./schemadoc --check >/dev/null 2>&1 \
    && ok "schema/README.md matches the schemas" \
    || bad "schema/README.md is stale -- run ./schemadoc --write" \
           "$(./schemadoc --check 2>&1)"
./schemadoc --missing >/dev/null 2>&1 \
    && ok "every schema key is described, or listed in schema/undocumented.txt" \
    || bad "schema/undocumented.txt no longer matches the schemas" \
           "$(./schemadoc --missing 2>&1)"

#-- one ~/.config copy must not answer for every machine ------------------------
# The path ~/.config/hpcdev/site.sh has no site in it, so a copy made for one
# machine used to answer a request for another -- and a Site takes its name from
# the profile it read, so an experiment saying `site: casper` ran Derecho's core
# count, bind list and MPI recipe without a word.  Nothing in the results would
# have said so, which is why this is tested rather than documented.
echo
echo "profile search"
( export XDG_CONFIG_HOME="${TMP}/xdg"
  mkdir -p "${XDG_CONFIG_HOME}/hpcdev"
  cp ../sites/derecho/site.sh "${XDG_CONFIG_HOME}/hpcdev/site.sh"
  unset BENCH_SITE_CONF

  # Asking for derecho: the copy matches and is used.
  got="$(python3 -c 'import sys
sys.path.insert(0, ".")
from benchlib import site
print(site.find_conf("derecho"))' 2>&1)"
  case "${got}" in
      "${XDG_CONFIG_HOME}"/*) echo "  ok    a matching ~/.config copy is used" ;;
      *) echo "  FAIL  a matching ~/.config copy was skipped"; echo "        ${got}" ;;
  esac

  # Asking for casper: the copy names derecho, so it must be passed over for
  # the checkout's own casper profile.
  got="$(python3 -c 'import sys
sys.path.insert(0, ".")
from benchlib import site
print(site.find_conf("casper"))' 2>&1)"
  case "${got}" in
      *"/sites/casper/site.sh") echo "  ok    a ~/.config copy for another site is skipped" ;;
      *) echo "  FAIL  a Derecho ~/.config copy answered a Casper request"; echo "        ${got}" ;;
  esac

  # Naming the wrong profile outright is explicit, and still refused: an
  # override may say WHERE a profile is, never which machine it describes.
  out="$(BENCH_SITE_CONF="${XDG_CONFIG_HOME}/hpcdev/site.sh" ./validate casper-hpcg 2>&1)"
  case "${out}" in
      *"describes 'derecho'"*) echo "  ok    an explicitly named wrong-site profile is refused" ;;
      *) echo "  FAIL  BENCH_SITE_CONF pointing at another site was accepted" ;;
  esac
) | tee "${TMP}/search.out"
pass=$((pass + $(grep -c '^  ok ' "${TMP}/search.out")))
fail=$((fail + $(grep -c '^  FAIL' "${TMP}/search.out")))

#-- the site description, and the profile generated from it --------------------
# sites/<site>.yaml is the single statement of what a machine is; the generated
# block of sites/<site>/site.sh is what every job actually sources.  Nothing
# else compares them, so a stale profile would go on describing the machine as
# it was and no job would notice.
echo
echo "site descriptions"
./sitegen --check >/dev/null 2>&1 \
    && ok "every sites/<site>/site.sh matches its .yaml" \
    || bad "a site profile is stale -- run ./sitegen --write" "$(./sitegen --check 2>&1)"

# The generated block is spliced between markers, so regenerating must be a
# no-op and the hand-edited settings above it must survive untouched.  If they
# did not, a regeneration would silently discard an operator's paths.
before="$(sed '/BEGIN GENERATED/,$d' ../sites/derecho/site.sh)"
./sitegen derecho --write >/dev/null 2>&1
after="$(sed '/BEGIN GENERATED/,$d' ../sites/derecho/site.sh)"
want "regenerating leaves the hand-edited half alone" "${before}" "${after}"
./sitegen --check >/dev/null 2>&1
want "regenerating is idempotent" 0 "$?"

# Rules the schema cannot state, plus the generator's own refusal to quote a
# value it cannot safely write.  Each case is a file that is individually
# well-formed and still describes a machine no job could run on.
site_case () { # site_case <description> <ok|reject> <yaml>
    printf '%s\n' "$3" > "${TMP}/site.yaml"
    out="$(python3 -c 'import sys
sys.path.insert(0, ".")
from benchlib import BenchError, sitefile
try:
    sitefile.render(sitefile.load(sys.argv[1]))
    print("ok")
except BenchError:
    print("reject")' "${TMP}/site.yaml" 2>&1)"
    want "$1" "$2" "${out}"
}

site_base='schema: 1
site: testville
scheduler: {kind: pbspro, submit: qsub, queue: main}
modules:
  bootstrap: [module load apptainer]
  mpi_map: {openmpi: openmpi}
node: {cores: 64, smt: 1}
container: {runtime: apptainer, binds: [/glade]}
mpi:
  openmpi: {launcher: openmpi, overlay: host-openmpi}'

site_case "a good site description is accepted" ok "${site_base}"
site_case "an unknown key is config-invalid" reject "${site_base}
bogus: 1"
site_case "a scheduler nobody implemented is refused" reject \
    "$(printf '%s\n' "${site_base}" | sed 's/kind: pbspro/kind: lsf/')"
site_case "an mpi family with no module mapping is refused" reject \
    "$(printf '%s\n' "${site_base}" | sed 's/mpi_map: {openmpi: openmpi}/mpi_map: {}/')"
site_case "a module mapping for a family mpi: omits is refused" reject \
    "$(printf '%s\n' "${site_base}" | sed 's/mpi_map: {openmpi: openmpi}/mpi_map: {openmpi: openmpi, mpich: ""}/')"
site_case "the Cray shim under the wrong launcher is refused" reject \
    "$(printf '%s\n' "${site_base}" | sed 's/overlay: host-openmpi/overlay: cray-mpich-abi/')"
site_case "cores_per_l3 larger than the node is refused" reject \
    "$(printf '%s\n' "${site_base}" | sed 's/{cores: 64, smt: 1}/{cores: 64, smt: 1, cores_per_l3: 128}/')"
site_case "an unknown MPI family is refused" reject \
    "$(printf '%s\n' "${site_base}" | sed 's/  openmpi: {launcher/  intelmpi: {launcher/;s/mpi_map: {openmpi: openmpi}/mpi_map: {intelmpi: impi}/')"

# The generator writes into a shell file every job sources, so a value it cannot
# spell safely is refused rather than quoted.  Quoting arbitrary text correctly
# is the kind of thing that works until the day it does not.
site_case "a value carrying a quote is refused, not quoted" reject \
    "${site_base%$'\n'*}
  openmpi: {launcher: openmpi, overlay: host-openmpi, env: {X: \"a'\\\"b\"}}"

#-- exit codes are the interface -----------------------------------------------
echo
echo "exit codes"
base='schema: 1
site: derecho
defaults: {nodes: 1}
images: {list: [leap-oneapi-mpich-hpcg.sif]}
apps: [{name: hpcg}]
placements: [{name: pureMPI, ranks_per_node: 128, threads: 1}]
sweep: {matrix: [images, apps, placements], per_job: [placements]}'

case_exit () { # case_exit <description> <expected code> <yaml>
    printf '%s\n' "$3" > "${TMP}/case.yaml"
    ./validate "${TMP}/case.yaml" >/dev/null 2>&1
    want "$1" "$2" "$?"
}

case_exit "a good config exits 0"                 0 "${base}"
case_exit "an unknown key is config-invalid (3)"  3 "${base}
bogus: 1"
case_exit "a bad walltime is config-invalid (3)"  3 "${base}
defaults: {walltime: half an hour}"
case_exit "per_job outside matrix is invalid (3)" 3 "$(printf '%s\n' "${base}" | sed 's/per_job: \[placements\]/per_job: [omp_variants]/')"
case_exit "images in per_job is invalid (3)"      3 "$(printf '%s\n' "${base}" | sed 's/per_job: \[placements\]/per_job: [placements, images]/')"
case_exit "an uncrossed axis is invalid (3)"      3 "$(printf '%s\n' "${base}" | sed 's/matrix: \[images, apps, placements\]/matrix: [images, apps]/;s/threads: 1}\]/threads: 1}, {name: ccd, ranks_per_node: 16, threads: 8}]/')"
case_exit "a bad geometry is geometry-rejected (4)" 4 "$(printf '%s\n' "${base}" | sed 's/threads: 1}/threads: 3}/')"
case_exit "allow_undersubscribed permits it (0)"  0 "$(printf '%s\n' "${base}" | sed 's/threads: 1}/threads: 3}/;s/defaults: {nodes: 1}/defaults: {nodes: 1, allow_undersubscribed: true}/')"
case_exit "a missing .sif is image-missing (5)"   5 "$(printf '%s\n' "${base}" | sed 's/leap-oneapi-mpich-hpcg.sif/nosuch.sif/')"
./validate no-such-experiment >/dev/null 2>&1
want "an unknown experiment name is config-invalid (3)" 3 "$?"

#-- validate and submit apply one gate ------------------------------------------
# A green validate followed by a submit that refuses would make validate
# worthless, so the two must return the same code for the same file.
echo
echo "one gate"
# Both codes are compared against the expected one, not just against each
# other: two commands agreeing on 0 for a config that should be refused would
# pass a test that only asked whether they matched.
agree () { # agree <description> <expected code> <yaml>
    printf '%s\n' "$3" > "${TMP}/gate.yaml"
    ./validate "${TMP}/gate.yaml" >/dev/null 2>&1; v=$?
    rm -rf "${TMP}/gate.d"
    ./submit "${TMP}/gate.yaml" --dry-run --results-dir "${TMP}/gate.d" \
        >/dev/null 2>&1; s=$?
    want "$1" "$2 $2" "${v} ${s}"
}

agree "a good config: both accept (0)"       0 "${base}"
agree "a missing .sif: both refuse (5)"      5 "$(printf '%s\n' "${base}" | sed 's/leap-oneapi-mpich-hpcg.sif/nosuch.sif/')"
agree "a bad geometry: both refuse (4)"      4 "$(printf '%s\n' "${base}" | sed 's/threads: 1}/threads: 3}/')"
agree "an unknown key: both refuse (3)"      3 "${base}
bogus: 1"
agree "a bad walltime: both refuse (3)"      3 "${base}
defaults: {walltime: half an hour}"

for f in experiments/*.yaml; do
    c="$(conf_for "$f")"
    BENCH_SITE_CONF="${c}" ./validate "$f" >/dev/null 2>&1; v=$?
    rm -rf "${TMP}/gate.d"
    BENCH_SITE_CONF="${c}" ./submit "$f" --dry-run --results-dir "${TMP}/gate.d" \
        >/dev/null 2>&1; s=$?
    want "$(basename "$f"): validate and submit agree" "${v}" "${s}"
done
rm -rf "${TMP}/gate.d"

#-- the expansion ---------------------------------------------------------------
echo
echo "matrix expansion"
count () { # count <experiment> <what>
    ./validate "$1" --format json 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
jobs = d.get('jobs', [])
print({'jobs': len(jobs),
       'cells': sum(len(j['cells']) for j in jobs),
       'runs': sum(len(j['cells']) * j['repeats'] for j in jobs)}['$2'])"
}
want "derecho-hpcg is 6 jobs"   6  "$(count derecho-hpcg jobs)"
want "derecho-hpcg is 18 cells" 18 "$(count derecho-hpcg cells)"
want "derecho-hpcg is 54 runs at repeats=3" 54 "$(count derecho-hpcg runs)"
want "derecho-osu crosses two apps into 12 jobs" 12 "$(count derecho-osu jobs)"

# per_job is the queue-wait-versus-job-length knob: emptying it must turn the
# same 18 cells into 18 one-cell jobs, with nothing else changing.
printf '%s\n' "$(sed 's/per_job: \[placements, omp_variants\]/per_job: []/' \
    experiments/derecho-hpcg.yaml)" > "${TMP}/percell.yaml"
want "per_job: [] gives one cell per job" 18 "$(count "${TMP}/percell.yaml" jobs)"
want "per_job: [] keeps the cell count"   18 "$(count "${TMP}/percell.yaml" cells)"

# A cell's name is every filename it writes -- placement_<name>.out, run_<name>/
# -- so two cells sharing a placement name would silently overwrite each other.
# Crossing a second OMP variant inside one job is exactly how that happens.
sed 's|^  # - {name: perthr,|  - {name: perthr,|' experiments/derecho-hpcg.yaml \
    > "${TMP}/twoomp.yaml"
names="$(./validate "${TMP}/twoomp.yaml" --format json 2>/dev/null | python3 -c "
import json, sys
cells = json.load(sys.stdin)['jobs'][0]['cells']
print(len({c['name'] for c in cells}), len(cells))")"
want "two OMP variants give six distinctly named cells" "6 6" "${names}"

#-- generated jobs --------------------------------------------------------------
echo
echo "generated jobs"
./submit derecho-hpcg --dry-run --results-dir "${TMP}/out" >/dev/null 2>&1 \
    && ok "submit --dry-run generates without an account" \
    || bad "submit --dry-run failed" "$(./submit derecho-hpcg --dry-run --results-dir "${TMP}/out" 2>&1 | tail -5)"

d="${TMP}/out/leap-oneapi-mpich-hpcg"
for f in job.pbs job.env job.json; do
    [ -s "${d}/${f}" ] && ok "wrote ${f}" || bad "no ${f} in ${d}"
done
grep -q '@[A-Z_]*@' "${d}/job.pbs" \
    && bad "job.pbs still has unfilled placeholders" "$(grep -o '@[A-Z_]*@' "${d}/job.pbs" | sort -u)" \
    || ok "job.pbs has no unfilled placeholders"
grep -q '^#PBS -l select=2:ncpus=128' "${d}/job.pbs" \
    && ok "job.pbs carries the real select= directive, not a variable" \
    || bad "job.pbs select= directive is wrong" "$(grep '^#PBS -l select' "${d}/job.pbs")"

# A benchmark job claims the whole node by default, whether or not its cells use
# every core, because a co-tenant's work would land in the timings unseen.
# defaults.exclusive: false is the opt-out, for a machine whose nodes are shared
# by design -- and it must change what is REQUESTED, not just what is recorded.
grep -q '^#PBS -l select=2:ncpus=128:mpiprocs=128' "${d}/job.pbs" \
    && ok "an exclusive job asks for every core on the node" \
    || bad "the exclusive select= is wrong" "$(grep '^#PBS -l select' "${d}/job.pbs")"

# Built from ${base} rather than by editing a shipped file: a sed that has to
# insert a newline behaves differently under BSD and GNU sed, and a test that
# passes on one machine and not the other is worse than no test.
printf '%s\n' "${base}" \
    | sed 's/defaults: {nodes: 1}/defaults: {nodes: 2, exclusive: false, allow_undersubscribed: true}/' \
    | sed 's/ranks_per_node: 128/ranks_per_node: 8/' > "${TMP}/shared.yaml"
rm -rf "${TMP}/shared.d"
./submit "${TMP}/shared.yaml" --dry-run --results-dir "${TMP}/shared.d" >/dev/null 2>&1
want "exclusive: false asks only for the cores the cells use" \
     "#PBS -l select=2:ncpus=8:mpiprocs=8:ompthreads=1" \
     "$(grep -h '^#PBS -l select' "${TMP}/shared.d"/*/job.pbs 2>/dev/null)"

./validate "${TMP}/shared.yaml" 2>&1 | grep -q "share each node" \
    && ok "validate says out loud that the nodes will be shared" \
    || bad "a shared-node experiment validates with no warning"

# A description that says what the hardware is but not how to ask for it
# produces jobs that measure whatever the pool had free -- which is exactly what
# the first Casper run did.  So the selector has to reach the directive.
grep -q '^#PBS -l select=2:ncpus=128:mpiprocs=128:ompthreads=1$' "${d}/job.pbs" \
    && ok "no node.select leaves the directive unchanged" \
    || bad "an absent node.select changed the select directive" \
           "$(grep '^#PBS -l select' "${d}/job.pbs")"

rm -rf "${TMP}/sel.d"
# casper-hpcg names the openmpi third of the same image set, so the stand-in
# files created at the top of this script already cover it.
BENCH_SITE_CONF="${HERE}/../sites/casper/site.sh" ./submit \
    "${HERE}/experiments/casper-hpcg.yaml" --dry-run \
    --results-dir "${TMP}/sel.d" >/dev/null 2>&1
sel="$(grep -h '^#PBS -l select' "${TMP}/sel.d"/*/job.pbs 2>/dev/null | head -1)"
case "${sel}" in
    *":cpu_type=genoa") ok "node.select is appended to the select chunk" ;;
    *) bad "node.select did not reach the select directive" "${sel:-<no job.pbs>}" ;;
esac

# The job names its profile outright, and PBS runs it from its own spool
# directory -- so a relative path, which is how anyone would type
# $BENCH_SITE_CONF on a login node, would resolve to nothing once the job
# started rather than when it was submitted.
grep -q '^\. "/' "${d}/job.pbs" \
    && ok "job.pbs names the site profile by absolute path" \
    || bad "job.pbs names the site profile relatively" "$(grep '^\. ' "${d}/job.pbs")"

# The job.env <-> runner.sh contract: every name runner.sh reads is a name
# submit writes.  This is the seam the whole "the job never parses YAML" design
# rests on, and nothing else checks it.
( . "${d}/job.env" >/dev/null 2>&1
  [ "${BENCH_CELL_COUNT}" = 3 ] || exit 1
  [ "${BENCH_CELL_1_NAME}" = ccd ] || exit 1
  [ "${BENCH_CELL_1_RANKS_PER_NODE}" = 16 ] || exit 1
  [ "${BENCH_CELL_1_THREADS}" = 8 ] || exit 1
  [ "${BENCH_CELL_1_OMP_PLACES}" = cores ] || exit 1
  [ -n "${APP}" ] && [ -n "${RESULTS_DIR}" ] && [ -n "${container_img}" ]
) && ok "job.env sources in bash and defines every cell field" \
  || bad "job.env does not define what runner.sh reads"

# Two entries of one app must not collide, or one silently overwrites the other.
./submit derecho-osu --dry-run --results-dir "${TMP}/osu" >/dev/null 2>&1
n="$(ls -d "${TMP}/osu"/* 2>/dev/null | wc -l | tr -d '[:space:]')"
want "two osu benchmarks get 12 distinct directories" 12 "${n}"
grep -q "OSU_BENCHMARK='osu_allreduce'" \
    "${TMP}/osu/leap-oneapi-mpich-hpcg-allreduce/job.env" \
    && ok "an app's env reaches its job.env, exported for the container" \
    || bad "OSU_BENCHMARK missing from the allreduce job.env"

# A results directory that already holds a run must not be appended to by
# accident: two runs in one results.jsonl is a comparison nobody can undo.
: > "${d}/results.jsonl"
./submit derecho-hpcg --dry-run --results-dir "${TMP}/out" >/dev/null 2>&1
want "an occupied results directory is refused without --force" 2 "$?"
./submit derecho-hpcg --dry-run --force --results-dir "${TMP}/out" >/dev/null 2>&1
want "--force accepts it" 0 "$?"
rm -f "${d}/results.jsonl"

#-- the runner ------------------------------------------------------------------
echo
echo "runner"
bash -n runner.sh && ok "runner.sh parses" || bad "runner.sh has a syntax error"
( unset NCAR_HPC_ROOT; ./runner.sh >/dev/null 2>&1 )
want "runner.sh refuses to run without a site profile" 1 "$?"

# The exec boundary.  Both entry points source the site profile and then `exec`
# runner.sh: exported VARIABLES cross an exec, shell FUNCTIONS do not.  So the
# runner arrives with NCAR_HPC_ROOT set and bench_site_mpi_overlay undefined,
# and dies sourcing the launcher -- after the queue wait, in a job that had
# already printed its node list.  That is what the first Casper submission hit,
# and nothing here would have caught it.
#
# Reproduced exactly: source, exec, and assert the runner gets PAST loading its
# libraries.  It still fails afterwards for want of an image and a `module`
# command, which is fine -- the assertion is about which failure comes first.
out="$(bash -c '. "$1" >/dev/null 2>&1; exec ./runner.sh' _ \
       "${HERE}/../sites/derecho/site.sh" 2>&1)"
case "${out}" in
    *"no site profile has been sourced"*)
        bad "the site profile's functions did not survive the exec into runner.sh" \
            "$(printf '%s' "${out}" | tail -4)" ;;
    *)  ok "runner.sh recovers the site profile across an exec" ;;
esac

# And the generator's half of it: the job names the profile so the runner
# recovers the one this job was submitted with, not one it searched for.
grep -q '^export BENCH_SITE_CONF=' "${d}/job.pbs" \
    && ok "job.pbs exports the profile path across the exec" \
    || bad "job.pbs does not export BENCH_SITE_CONF"

#-- results ---------------------------------------------------------------------
echo
echo "collect"
mkdir -p "${TMP}/res/j1"
cp ../../../scripts/app.d/hpcg/app.yaml "${TMP}/res/j1/app.yaml"
python3 - "${TMP}/res/j1/results.jsonl" <<'PY'
import json, sys
rows = []
for place, ppn, thr, base in (("pureMPI", 128, 1, 85.0), ("ccd", 16, 8, 77.0)):
    for rep, delta in enumerate((0.0, 0.9, -0.4), start=1):
        rows.append({"schema": 1, "site": "derecho", "nodes": 2,
                     "image": {"sif": "leap-oneapi-mpich-hpcg.sif"},
                     "app": {"name": "hpcg"},
                     "placement": {"name": place, "ranks_per_node": ppn,
                                   "threads": thr, "omp_variant": "percore",
                                   "verdict": "ok", "rules": []},
                     "repeat": rep, "repeats": 3, "warm": True,
                     "wall_s": 200.0 - base + delta, "exit": 0,
                     "metrics": {"gflops": base + delta}})
open(sys.argv[1], "w").write("".join(json.dumps(r) + "\n" for r in rows))
PY
want "repeats collapse to one line per cell" 2 \
    "$(./collect "${TMP}/res" 2>/dev/null | sed -n '3,/^$/p' | grep -c hpcg)"
want "--per-run keeps every run" 6 \
    "$(./collect "${TMP}/res" --per-run 2>/dev/null | grep -c 'leap-oneapi')"
# 85.0, 85.9, 84.6 -> median 85.0, and the mean would be 85.166...
./collect "${TMP}/res" --best 2>/dev/null | grep -q 'gflops median=85 min=84.6 (n=3)' \
    && ok "--best ranks on the median, not the mean or a single sample" \
    || bad "--best median is wrong" "$(./collect "${TMP}/res" --best 2>/dev/null | grep gflops)"

# The whole point of the sweep: its output is a runnable configuration.
./collect "${TMP}/res" --emit-profile > "${TMP}/profile.yaml" 2>/dev/null
sed '/^profiles:/,$d' experiments/derecho-hpcg.yaml > "${TMP}/round.yaml"
cat "${TMP}/profile.yaml" >> "${TMP}/round.yaml"
./validate "${TMP}/round.yaml" --profile production >/dev/null 2>&1 \
    && ok "--emit-profile output validates and selects one cell" \
    || bad "--emit-profile output does not round-trip" "$(cat "${TMP}/profile.yaml")"

echo
echo "  ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
