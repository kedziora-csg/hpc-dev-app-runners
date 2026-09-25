"""checks the things that can only be answered by looking at the machine.

Parsing and schema live in yamlish/schema; the matrix and the geometry rule live
in experiment.  What is left is the world: is that .sif actually on disk, and
does it carry a contract for the app the experiment names?

BOTH ARE WORTH DOING BEFORE SUBMITTING

A missing .sif is a job that starts, prints one line and exits, having waited in
a queue to do it.  A missing app contract is worse: the job runs the placement
probe, then discovers there is nothing to benchmark.  Neither needs a compute
node to find out.

ONE GATE, TWO COMMANDS

`preflight` below is the whole verdict: which checks run, in what order, and
which exit code says so.  `bench validate` and `bench submit` both call it and
differ only in how they report it, so a green validate cannot be followed by a
submit that refuses.  A new check goes in there, never in a caller.

UNCHECKED IS NOT THE SAME AS MISSING

Looking inside an image needs apptainer, which a laptop and a CI container do
not have.  That case reports `unchecked` and does not fail: `bench validate`
has to be useful off-cluster, where it catches everything else, and saying
"missing" about something never looked at would be a lie that eventually gets
believed.
"""

import os
import subprocess

from . import EXIT_CONFIG, EXIT_CONTRACT, EXIT_IMAGE, EXIT_OK
from . import schema as schema_mod
from . import yamlish

APP_D = "/container/app.d"


class Result(object):
    """One check: ok, missing, or unchecked -- with why."""

    def __init__(self, subject, state, detail=""):
        self.subject = subject
        self.state = state              # "ok" | "missing" | "unchecked"
        self.detail = detail

    def __str__(self):
        return "%-9s %s%s" % (self.state, self.subject,
                              "   (%s)" % self.detail if self.detail else "")


def have_apptainer():
    return _which("apptainer") is not None


def _which(name):
    for d in os.environ.get("PATH", "").split(os.pathsep):
        candidate = os.path.join(d, name)
        if os.access(candidate, os.X_OK) and not os.path.isdir(candidate):
            return candidate
    return None


def images(cluster, names):
    out = []
    for sif in names:
        path = cluster.image_path(sif)
        if os.path.isfile(path):
            out.append(Result(sif, "ok", path))
        else:
            out.append(Result(sif, "missing", "no such file: %s" % path))
    return out


def contracts(cluster, pairs):
    """pairs: (sif, app_name).  An absolute app name is a bare executable."""
    if not have_apptainer():
        return [Result("%s in %s" % (app, sif), "unchecked",
                       "no apptainer on this host")
                for sif, app in sorted(set(pairs))]

    out = []
    for sif, app in sorted(set(pairs)):
        path = cluster.image_path(sif)
        if not os.path.isfile(path):
            continue                    # already reported by images()
        target = app if app.startswith("/") else "%s/%s/app.yaml" % (APP_D, app)
        test = "-x" if app.startswith("/") else "-f"
        try:
            rc = subprocess.call(["apptainer", "exec", path, "test", test, target],
                                 stdout=open(os.devnull, "w"),
                                 stderr=subprocess.STDOUT)
        except OSError as exc:
            out.append(Result("%s in %s" % (app, sif), "unchecked", str(exc)))
            continue
        if rc == 0:
            out.append(Result("%s in %s" % (app, sif), "ok", target))
        else:
            out.append(Result("%s in %s" % (app, sif), "missing",
                              "no %s in the image -- rebuild it with the app "
                              "layer, or point BENCH_APP_DIR at a contract on a "
                              "bound filesystem" % target))
    return out


def host_contract(app):
    """The app.yaml in this checkout, if there is one, for schema checking.

    Off-cluster this is the only copy of a contract there is, and it is the one
    a build_<app>.sh installs into the image -- so validating it here is what
    lets a broken contract fail in CI rather than three hours into a queue.
    """
    if app.startswith("/"):
        return None
    # benchlib/ -> bench/ -> deploy/ -> containers/ -> the checkout
    root = os.path.abspath(__file__)
    for _ in range(5):
        root = os.path.dirname(root)
    path = os.path.join(root, "scripts", "app.d", app, "app.yaml")
    return path if os.path.isfile(path) else None


def app_contracts(names):
    """Schema-check the app.yaml files that exist in this checkout.

    Returns (seen, problems); seen is (app, path) pairs, so a report can say
    which contracts were actually looked at rather than implying all of them.
    """
    problems, seen = [], []
    for app in sorted(set(names)):
        path = host_contract(app)
        if path is None:
            continue
        seen.append((app, path))
        try:
            data = yamlish.load(path)
        except yamlish.YamlError as exc:
            problems.append("%s: %s" % (path, exc))
            continue
        for problem in schema_mod.validate(data, "app"):
            problems.append("%s: %s" % (path, problem))
        # Cross-field: a primary_fom nothing declares cannot rank anything, and
        # bench/collect would silently fall back to wall_s.
        foms = data.get("figures_of_merit") or {}
        primary = data.get("primary_fom")
        if primary and primary not in foms:
            problems.append("%s: primary_fom %r is not in figures_of_merit (%s)"
                            % (path, primary, ", ".join(sorted(foms)) or "none"))
    return seen, problems


def missing(results):
    """The results that are definitely wrong.  `unchecked` is not one of them."""
    return [r for r in results if r.state == "missing"]


class Preflight(object):
    """Everything known about an expanded experiment before anything is queued.

    `code` is what a command exits with and `problems` is every finding at the
    failing stage, in the order the stages ran.
    """

    def __init__(self, images, contracts, app_contracts, app_problems,
                 problems, code):
        self.images = images
        self.contracts = contracts
        self.app_contracts = app_contracts      # (app, path) pairs looked at
        self.app_problems = app_problems        # findings from those files
        self.problems = problems
        self.code = code


def preflight(exp, jobs):
    """The gate both `bench validate` and `bench submit` apply.  See ONE GATE."""
    image_results = images(exp.cluster, sorted({j.image for j in jobs}))
    contract_results = contracts(exp.cluster,
                                 [(j.image, j.app["name"]) for j in jobs])
    seen, app_problems = app_contracts(j.app["name"] for j in jobs)

    # Lowest code wins, so the code names the earliest thing that is wrong --
    # see EXIT CODES in benchlib/__init__.py.
    problems, code = [], EXIT_OK
    if app_problems:
        problems += app_problems
        code = EXIT_CONFIG
    gone = missing(image_results)
    if gone and code == EXIT_OK:
        code = EXIT_IMAGE
    problems += ["image missing: %s (%s)" % (r.subject, r.detail) for r in gone]
    gone = missing(contract_results)
    if gone and code == EXIT_OK:
        code = EXIT_CONTRACT
    problems += ["app contract missing: %s (%s)" % (r.subject, r.detail)
                 for r in gone]

    return Preflight(image_results, contract_results, seen, app_problems,
                     problems, code)
