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
from .sitefile import GPU_VENDOR

APP_D = "/container/app.d"


class Result(object):
    """One check: ok, missing, wrong, or unchecked -- with why."""

    def __init__(self, subject, state, detail=""):
        self.subject = subject
        self.state = state              # "ok" | "missing" | "wrong" | "unchecked"
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
    """Each image is on disk, and an app image was built for this node type.

    The target comes from the image's hpcdev.target label, and from its name
    for an image older than the labels.  A portable image -- a base image, or
    an app image built at the base's own flags -- names none and runs anywhere.
    A tuned image runs only on a node type built for that target, which a node
    type of portable builds is not.  A description with no images: block
    states nothing to hold an image to, so a new cluster can try any image.
    """
    want = cluster.image_target()
    want_runtime, want_gpu = cluster.gpu_target()
    out = []
    for sif in names:
        path = cluster.image_path(sif)
        if not os.path.isfile(path):
            out.append(Result(sif, "missing", "no such file: %s" % path))
            continue
        # An empty label is an answer -- a portable build -- and the name is
        # read only when there is no label to ask: a portable build with a
        # tag suffix, leap-gcc14-openmpi-heffte-pbase, would otherwise be
        # taken for one built for "pbase".
        built = _label(path, "hpcdev.target")
        if built is None:
            built = _target_in_name(sif)
        where = cluster.name + ("/" + cluster.subcluster if cluster.subcluster else "")
        if want is not None and built and built != want:
            out.append(Result(sif, "wrong", "built for %s, but %s's app images "
                              "are %s" % (built, where, want or "portable")))
            continue
        # A GPU image needs the node type's GPUs; a GPU target, the node type's.
        # The other way round is legal: a GPU node type may run a CPU image.
        runtime = _label(path, "hpcdev.gpu")
        if runtime is None:
            runtime = _gpu_in_name(sif)
        if runtime and cluster.gpu_vendor != GPU_VENDOR.get(runtime):
            out.append(Result(sif, "wrong", "a %s image, but %s has %s"
                              % (runtime, where,
                                 "%s GPUs" % cluster.gpu_vendor
                                 if cluster.gpu_vendor else "no GPUs")))
            continue
        gpu_built = _label(path, "hpcdev.gpu_target") or ""
        if gpu_built and want_gpu and gpu_built != want_gpu:
            out.append(Result(sif, "wrong", "device code built for %s, but %s's "
                              "GPUs are %s" % (gpu_built, where, want_gpu)))
            continue
        out.append(Result(sif, "ok", path))
    return out


_LABELS = {}


def _label(path, key):
    """One label of a .sif, possibly "", or None when it cannot be read: no
    apptainer to ask, or an image older than the label.  Each image is
    inspected once a run."""
    if not have_apptainer():
        return None
    if path not in _LABELS:
        labels = {}
        try:
            text = subprocess.check_output(["apptainer", "inspect", "--labels", path],
                                           stderr=open(os.devnull, "w"))
            for line in text.decode("utf-8", "replace").splitlines():
                name, _, value = line.partition(":")
                labels[name.strip()] = value.strip()
        except (OSError, subprocess.CalledProcessError):
            labels = None
        _LABELS[path] = labels
    labels = _LABELS[path]
    return None if labels is None else labels.get(key)


def _target_in_name(sif):
    """The target of <os>-<compiler>-<mpi>-<app>-<target>[-<suffix>].sif.

    No word of the name before it holds a dash, so it is always the fifth; a
    base image's name has three words and no target.  A GPU base's runtime word
    (leap-nvhpc-mpich-cuda-<app>-<target>) is not counted.
    """
    words = os.path.basename(sif)[:-len(".sif")].split("-")
    if len(words) > 3 and words[3] in GPU_VENDOR:
        del words[3]
    return words[4] if len(words) > 4 else ""


def _gpu_in_name(sif):
    """The GPU runtime of <os>-<compiler>-<mpi>-cuda[...].sif, or ""."""
    words = os.path.basename(sif)[:-len(".sif")].split("-")
    return words[3] if len(words) > 3 and words[3] in GPU_VENDOR else ""


def image_mpi(cluster, sif):
    """The MPI family an image was built with: its hpcdev.mpi label, else the
    third word of its name."""
    family = _label(cluster.image_path(sif), "hpcdev.mpi")
    if family:
        return family
    words = os.path.basename(sif)[:-len(".sif")].split("-")
    return words[2] if len(words) > 2 else ""


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
        try:
            if app.startswith("/"):
                rc = subprocess.call(["apptainer", "exec", path, "test", "-x", target],
                                     stdout=open(os.devnull, "w"),
                                     stderr=subprocess.STDOUT)
            else:
                rc = 0 if _image_contract(path, app) is not None else 1
        except OSError as exc:
            out.append(Result("%s in %s" % (app, sif), "unchecked", str(exc)))
            continue
        if rc == 0:
            out.append(Result("%s in %s" % (app, sif), "ok", target))
        else:
            out.append(Result("%s in %s" % (app, sif), "missing",
                              "no %s in the image -- rebuild it with the app "
                              "layer, or point HPCRUN_APP_DIR at a contract on a "
                              "bound filesystem" % target))
    return out


_CONTRACTS = {}


def _image_contract(path, app):
    """The text of an image's /container/app.d/<app>/app.yaml, or None.  Read
    once a run: contracts() and app_requires() both want it."""
    key = (path, app)
    if key not in _CONTRACTS:
        try:
            text = subprocess.check_output(
                ["apptainer", "exec", path, "cat", "%s/%s/app.yaml" % (APP_D, app)],
                stderr=open(os.devnull, "w"))
            _CONTRACTS[key] = text.decode("utf-8", "replace") or None
        except subprocess.CalledProcessError:
            _CONTRACTS[key] = None
    return _CONTRACTS[key]


def app_requires(cluster, sif, app):
    """An app's requires: block, from the image's contract, or from this
    checkout's copy when there is no apptainer to ask.  {} when it states none,
    None when there is no contract to read."""
    if app.startswith("/"):
        return {}
    text = None
    path = cluster.image_path(sif)
    if have_apptainer() and os.path.isfile(path):
        try:
            text = _image_contract(path, app)
        except OSError:
            text = None
    if text is not None:
        try:
            data = yamlish.loads(text, "%s:%s/%s/app.yaml" % (sif, APP_D, app))
        except yamlish.YamlError:
            return None
    else:
        local = host_contract(app)
        if local is None:
            return None
        try:
            data = yamlish.load(local)
        except yamlish.YamlError:
            return None
    return dict(data.get("requires") or {})


def requirements(cluster, pairs):
    """What an app's contract requires of the node type: (results, requires),
    where requires maps (sif, app) to its requires: block.

    pairs: (sif, app_name).  A GPU app needs the node type's GPUs, and a
    host_software name needs the cluster's install of it, at the path the
    image's MPI family selects.  A path a module's variable names is checked by
    the launcher, where the variable has a value.
    """
    from .sitefile import VAR_REF
    out, found = [], {}
    software = None
    for sif, app in sorted(set(pairs)):
        req = app_requires(cluster, sif, app)
        if req is None:
            continue                    # contracts() says why
        found[(sif, app)] = req
        where = cluster.name + ("/" + cluster.subcluster if cluster.subcluster else "")
        gpu = req.get("gpu")
        if gpu:
            subject = "%s needs a %s GPU" % (app, gpu)
            if cluster.gpu_vendor != GPU_VENDOR.get(gpu):
                out.append(Result(subject, "wrong", "%s has %s" % (
                    where, "%s GPUs" % cluster.gpu_vendor if cluster.gpu_vendor
                    else "none -- choose a GPU node type with --subcluster")))
            else:
                out.append(Result(subject, "ok", "%s x %s"
                                  % (cluster.gpus_per_node, cluster.gpu_model or gpu)))
        for name in req.get("host_software") or []:
            subject = "%s needs host software %s (%s)" % (app, name, sif)
            if name not in cluster.host_software:
                out.append(Result(subject, "missing",
                                  "%s declares no host_software.%s" % (cluster.name, name)))
                continue
            if software is None:
                software = cluster._description().data.get("host_software") or {}
            spec = (software.get(name) or {}).get("path", "")
            host = spec.replace("${mpi}", image_mpi(cluster, sif))
            if VAR_REF.search(host):
                out.append(Result(subject, "unchecked",
                                  "%s is expanded in the job, once its module is loaded"
                                  % host))
            elif os.path.isdir(host):
                out.append(Result(subject, "ok", host))
            else:
                out.append(Result(subject, "missing", "no such directory: %s" % host))
    return out, found


def host_contract(app):
    """The app.yaml in this checkout, if there is one, for schema checking.

    Off-cluster this is the only copy of a contract there is, and it is the one
    a build_<app>.sh installs into the image -- so validating it here is what
    lets a broken contract fail in CI rather than three hours into a queue.
    """
    if app.startswith("/"):
        return None
    # checks.py -> benchlib/ -> hpcrun/ -> the checkout
    root = os.path.abspath(__file__)
    for _ in range(3):
        root = os.path.dirname(root)
    path = os.path.join(root, "apps", app, "app.d", "app.yaml")
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
        problems.extend("%s: %s" % (path, p) for p in contract_problems(data))
    return seen, problems


def contract_problems(data):
    """What is wrong with one parsed app.yaml: its schema, and the rules
    between keys that a schema cannot state."""
    problems = list(schema_mod.validate(data, "app"))
    # A primary_fom nothing declares cannot rank anything, and hpcrun/collect
    # would silently fall back to wall_s.
    foms = data.get("figures_of_merit") or {}
    primary = data.get("primary_fom")
    if primary and primary not in foms:
        problems.append("primary_fom %r is not in figures_of_merit (%s)"
                        % (primary, ", ".join(sorted(foms)) or "none"))
    requires = data.get("requires") or {}
    if requires.get("gpu_aware_mpi") and not requires.get("gpu"):
        problems.append("requires.gpu_aware_mpi without requires.gpu: device "
                        "buffers need a GPU to live on")
    return problems


def missing(results):
    """The results that are definitely wrong.  `unchecked` is not one of them."""
    return [r for r in results if r.state in ("missing", "wrong")]


class Preflight(object):
    """Everything known about an expanded experiment before anything is queued.

    `code` is what a command exits with and `problems` is every finding at the
    failing stage, in the order the stages ran.
    """

    def __init__(self, images, contracts, app_contracts, app_problems,
                 problems, code, requirements=(), requires=None):
        self.images = images
        self.contracts = contracts
        self.requirements = list(requirements)
        self.requires = requires or {}          # (sif, app) -> requires: block
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
    req_results, requires = requirements(exp.cluster,
                                         [(j.image, j.app["name"]) for j in jobs])

    # Lowest code wins, so the code names the earliest thing that is wrong --
    # see EXIT CODES in benchlib/__init__.py.
    problems, code = [], EXIT_OK
    if app_problems:
        problems += app_problems
        code = EXIT_CONFIG
    gone = missing(image_results)
    if gone and code == EXIT_OK:
        code = EXIT_IMAGE
    problems += ["image %s: %s (%s)" % (r.state, r.subject, r.detail) for r in gone]
    gone = missing(contract_results)
    if gone and code == EXIT_OK:
        code = EXIT_CONTRACT
    problems += ["app contract missing: %s (%s)" % (r.subject, r.detail)
                 for r in gone]
    # What the app needs of the node type is a property of where it runs, like
    # an image built for another target, and fails with the same code.
    gone = missing(req_results)
    if gone and code in (EXIT_OK, EXIT_CONTRACT):
        code = EXIT_IMAGE
    problems += ["requirement %s: %s (%s)" % (r.state, r.subject, r.detail)
                 for r in gone]

    return Preflight(image_results, contract_results, seen, app_problems,
                     problems, code, req_results, requires)
