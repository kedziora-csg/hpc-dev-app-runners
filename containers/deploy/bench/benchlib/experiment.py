"""experiment -- load an experiment file and expand it into jobs and cells.

This is the whole of what phase 3 moves out of shell.  `submit_placement_matrix.sh`
knew one matrix -- six images, one job each -- because it was written around it.
Here the matrix is data: which axes exist, which are crossed, and which of them
ONE job iterates.

    axes            images x apps x placements x omp_variants
    sweep.matrix    the axes actually crossed
    sweep.per_job   the subset ONE job iterates; the rest become separate jobs

So `per_job: [placements, omp_variants]` is today's behaviour -- one job per
image, every decomposition inside it -- and `per_job: []` is one cell per job,
which is what a six-hour application wants.  That trade is a line in a file
rather than an edit to a submitter.

THE ONE THING per_job MAY NOT HOLD

Images and apps.  A job builds its launcher once, resolves one app contract, and
records one `ldd` and one run.meta -- all of which are properties of an image and
an app, and none of which change between cells.  Letting either vary inside a job
would mean re-deriving them per cell and a results directory that no longer
describes a single thing.  Rejected with EXIT_CONFIG rather than accepted into a
job.env the runner would half-honour.

GEOMETRY

`ranks_per_node x threads` has exactly two legal products, and rejecting the rest
is the point:

    cores_per_node          one thread per physical core
    cores_per_node x smt    one thread per hardware thread -- both SMT siblings
                            compute; the ONLY way to engage SMT, and unrelated to
                            OMP_PLACES, which at the smaller product changes only
                            a thread's mask, never how many cores do work

Anything else is refused unless `allow_undersubscribed`, because --cpu-bind depth
packs consecutively from core 0: a smaller product does not idle the spare cores,
it crowds every rank onto the low chiplets.  That is a wrong answer that looks
like a valid data point, which is the worst kind.
"""

import os

from . import BenchError, EXIT_CONFIG, EXIT_GEOMETRY
from . import schema as schema_mod
from . import site as site_mod
from . import yamlish

AXES = ("images", "apps", "placements", "omp_variants")
JOB_ONLY_AXES = ("images", "apps")

EXPERIMENT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                              "experiments")


class Cell(object):
    """One measured configuration: an image, an app, a placement, an OMP variant.

    `name` is what the cell's artifacts are named with -- placement_<name>.out,
    run_<name>/ -- so it has to be unique within its job or two cells silently
    overwrite each other's report and run directory.  The OMP variant joins the
    placement name only when a job actually iterates more than one, so the
    common single-variant sweep keeps the short names people already read in a
    results directory.
    """

    def __init__(self, image, app, placement, omp, qualify_omp=False):
        self.image = image
        self.app = app
        self.placement = placement
        self.omp = omp
        self.name = placement["name"]
        if qualify_omp:
            self.name += "-" + omp["name"]


class Job(object):
    """One scheduler submission: fixed image and app, a list of cells."""

    def __init__(self, key, image, app, cells, defaults):
        self.key = key
        self.image = image
        self.app = app
        self.cells = cells
        self.nodes = defaults["nodes"]
        self.walltime = defaults["walltime"]
        self.repeats = defaults["repeats"]
        self.scale = app.get("scale") or defaults["scale"]
        self.target_seconds = app.get("target_seconds") or defaults["target_seconds"]

    @property
    def tag(self):
        return self.image[:-4] if self.image.endswith(".sif") else self.image


class Experiment(object):
    def __init__(self, path, data, site):
        self.path = path
        self.data = data
        self.site = site
        self.name = os.path.splitext(os.path.basename(path))[0]
        self.account = data.get("account")

        d = data.get("defaults") or {}
        self.defaults = {
            "nodes": d.get("nodes", 1),
            "walltime": d.get("walltime", "00:30:00"),
            "queue": d.get("queue") or site.queue,
            "repeats": d.get("repeats", 1),
            "scale": d.get("scale", "node"),
            "target_seconds": d.get("target_seconds", 60),
            "allow_undersubscribed": bool(d.get("allow_undersubscribed", False)),
        }
        self.matrix = list(data["sweep"]["matrix"])
        self.per_job = list(data["sweep"].get("per_job") or [])

        # The queue's own limit, from the site description.  Caught here rather
        # than left to the scheduler because qsub rejects the whole submission:
        # a matrix of thirty jobs is refused on the first one, having already
        # written thirty results directories.
        limit = site.walltime_max
        if limit and _seconds(self.defaults["walltime"]) > _seconds(limit):
            raise BenchError(
                "walltime %s is longer than %s allows (%s)"
                % (self.defaults["walltime"], site.name, limit), EXIT_CONFIG,
                ["scheduler.walltime_max in sites/%s.yaml" % site.name,
                 "raise it there if the queue's limit has changed, or ask for less"])


def _seconds(hms):
    """HH:MM:SS to seconds.  The schema has already checked the shape."""
    try:
        h, m, s = (int(part) for part in str(hms).split(":"))
    except ValueError:
        return 0
    return h * 3600 + m * 60 + s


def resolve_path(name):
    """An experiment name, a path, or a path without its extension."""
    for candidate in (name,
                      name + ".yaml", name + ".json",
                      os.path.join(EXPERIMENT_DIR, name),
                      os.path.join(EXPERIMENT_DIR, name + ".yaml"),
                      os.path.join(EXPERIMENT_DIR, name + ".json")):
        if os.path.isfile(candidate):
            return candidate
    known = sorted(f for f in os.listdir(EXPERIMENT_DIR)
                   if f.endswith((".yaml", ".json"))) if os.path.isdir(EXPERIMENT_DIR) else []
    raise BenchError("no experiment %r" % name, EXIT_CONFIG,
                     ["known experiments in %s:" % EXPERIMENT_DIR] +
                     ["    " + os.path.splitext(k)[0] for k in known])


def load(name, site_name=None, start=None):
    path = resolve_path(name)
    try:
        data = yamlish.load(path)
    except yamlish.YamlError as exc:
        raise BenchError("%s does not parse" % path, EXIT_CONFIG, [str(exc)])
    if not isinstance(data, dict):
        raise BenchError("%s is not a mapping" % path, EXIT_CONFIG)

    problems = schema_mod.validate(data, "experiment")
    if problems:
        raise BenchError("%s fails bench/schema/experiment.json" % path,
                         EXIT_CONFIG, problems)

    site = site_mod.load(site_name or data["site"], start)
    exp = Experiment(path, data, site)
    _check_semantics(exp)
    return exp


def _check_semantics(exp):
    """The rules a JSON Schema cannot state, because they relate two fields."""
    problems = []
    images = exp.data["images"]
    if ("from_make" in images) == ("list" in images):
        problems.append("images: give exactly one of from_make or list")

    for axis in exp.per_job:
        if axis not in exp.matrix:
            problems.append("sweep.per_job: %r is not in sweep.matrix" % axis)
        if axis in JOB_ONLY_AXES:
            problems.append(
                "sweep.per_job: %r cannot vary inside one job -- a job builds one "
                "launcher, resolves one app contract and records one run.meta" % axis)

    # No silent caps: an axis with real choices in it must be crossed, or those
    # choices are dropped by omission and the sweep quietly measures less than
    # the file says.
    for axis in AXES:
        entries = exp.data.get(axis) or []
        if axis == "images":
            continue
        if len(entries) > 1 and axis not in exp.matrix:
            problems.append("sweep.matrix: %r has %d entries but is not crossed; "
                            "all but the first would be dropped silently"
                            % (axis, len(entries)))

    for axis in ("apps", "placements", "omp_variants"):
        seen = set()
        for entry in exp.data.get(axis) or []:
            label = entry.get("label") or entry["name"]
            if label in seen:
                problems.append("%s: two entries labelled %r -- give one a "
                                "distinct `label`" % (axis, label))
            seen.add(label)

    for name, profile in (exp.data.get("profiles") or {}).items():
        for field, axis, key in (("placement", "placements", "name"),
                                 ("omp", "omp_variants", "name"),
                                 ("app", "apps", "label")):
            want = profile.get(field)
            if want is None:
                continue
            have = [e.get("label") or e[key if key in e else "name"]
                    for e in exp.data.get(axis) or []]
            if want not in have:
                problems.append("profiles.%s.%s: %r is not one of %s"
                                % (name, field, want, ", ".join(have) or "(none)"))

    if problems:
        raise BenchError("%s is not a usable experiment" % exp.path,
                         EXIT_CONFIG, problems)


def image_list(exp):
    images = exp.data["images"]
    if "list" in images:
        return list(images["list"])
    return exp.site.make_images(images["from_make"])


def geometry_problem(exp, placement):
    """Why this placement's ranks x threads is not a legal product, or None."""
    cores = exp.site.cores_per_node
    smt = exp.site.smt or 1
    product = placement["ranks_per_node"] * placement["threads"]
    if product in (cores, cores * smt):
        return None
    if exp.defaults["allow_undersubscribed"]:
        return None
    how = "under" if product < cores else "over"
    return ("placement %r: %d ranks/node x %d threads = %d, which %ssubscribes a "
            "%d-core node (legal products: %d, or %d with SMT). --cpu-bind depth "
            "packs from core 0, so this crowds every rank onto the low chiplets "
            "rather than %s. Set defaults.allow_undersubscribed: true if that is "
            "the experiment."
            % (placement["name"], placement["ranks_per_node"], placement["threads"],
               product, how, cores, cores, cores * smt,
               "idling the spare cores" if how == "under" else "failing"))


def expand(exp, profile=None, images=None):
    """The jobs this experiment would submit, in submission order."""
    axes = _axis_values(exp, profile, images)

    problems = [geometry_problem(exp, p) for p in axes["placements"]]
    problems = [p for p in problems if p]
    if problems:
        raise BenchError("%s asks for a geometry this site cannot run" % exp.path,
                         EXIT_GEOMETRY, problems)

    job_axes = [a for a in exp.matrix if a not in exp.per_job]
    cell_axes = [a for a in exp.matrix if a in exp.per_job]

    # The job directory is named by its image, plus any OTHER job axis that
    # actually varies.  The image is always in the name because it is the thing
    # a results directory is about -- which is also why the six directories a
    # default sweep produces are exactly the six people already read today.
    # Anything constant across the sweep is stated once in job.env instead of
    # repeated down every path.
    naming = [a for a in job_axes if a != "images" and len(axes[a]) > 1]

    jobs = []
    for combo in _product([axes[a] for a in job_axes]):
        fixed = dict(zip(job_axes, combo))
        image = fixed.get("images", axes["images"][0])
        app = fixed.get("apps", axes["apps"][0])
        # More than one OMP variant inside a job means two cells can share a
        # placement name, which is a collision in every filename a cell writes.
        qualify_omp = ("omp_variants" in cell_axes and len(axes["omp_variants"]) > 1)
        cells = []
        for cell_combo in _product([axes[a] for a in cell_axes]):
            varying = dict(zip(cell_axes, cell_combo))
            cells.append(Cell(
                image=image, app=app,
                placement=varying.get("placements", axes["placements"][0]),
                omp=varying.get("omp_variants", axes["omp_variants"][0]),
                qualify_omp=qualify_omp))
        key = "-".join([_coord_name("images", image)] +
                       [_coord_name(a, fixed[a]) for a in naming])
        jobs.append(Job(key, image, app, cells, exp.defaults))
    return jobs


def _axis_values(exp, profile, images):
    values = {
        "images": images if images is not None else image_list(exp),
        "apps": list(exp.data["apps"]),
        "placements": list(exp.data["placements"]),
        "omp_variants": list(exp.data.get("omp_variants") or
                             [{"name": "default"}]),
    }
    if profile is None:
        return values

    named = (exp.data.get("profiles") or {}).get(profile)
    if named is None:
        known = sorted(exp.data.get("profiles") or {})
        raise BenchError("no profile %r in %s" % (profile, exp.path), EXIT_CONFIG,
                         ["profiles defined: " + (", ".join(known) or "(none)")])
    if named.get("images"):
        values["images"] = list(named["images"])
    for field, axis in (("placement", "placements"), ("omp", "omp_variants"),
                        ("app", "apps")):
        want = named.get(field)
        if want is not None:
            values[axis] = [e for e in values[axis]
                            if (e.get("label") or e["name"]) == want]
    for field in ("nodes", "repeats"):
        if field in named:
            exp.defaults[field] = named[field]
    return values


def _coord_name(axis, value):
    if axis == "images":
        return value[:-4] if value.endswith(".sif") else value
    return value.get("label") or value["name"]


def _product(pools):
    out = [[]]
    for pool in pools:
        out = [row + [item] for row in out for item in pool]
    return out
