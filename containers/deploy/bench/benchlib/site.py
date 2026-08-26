"""site -- read sites/<site>/site.sh the way a job reads it.

The site profile is bash, and it stays bash: it is sourced by every PBS script
before anything else, and it carries one function as well as its settings.  So
the host side sources it too, in a subshell, and reads the exported values back.
That is a deliberate choice over re-declaring the same paths in Python:

  - there is one definition of where the images are, where results go, and where
    the harness is.  A submitter that disagreed with its own jobs about any of
    those would produce results in places nobody looks;
  - sourcing exercises the same file the job will, so a broken profile fails at
    submit time rather than after a queue wait.

Sourcing is safe: site.sh only assigns and defines.  `bench_site_modules` is
declared there, never called, so no `module` command runs on the host.

The declarative half of the site contract -- scheduler dialect, queue, bind
list, topology fallbacks -- is sites/<site>.yaml at phase 4 of the plan, and is
deliberately still unwritten.  Until it exists, the few things the HOST needs to
know before a job runs are read from site.sh, which already carries the rest.
"""

import os
import subprocess

from . import BenchError, EXIT_ERROR

# Read back after sourcing.  Every one is exported by site.sh itself, so this
# list adding a name is not enough -- the profile has to export it.
EXPORTED = ("BENCH_SITE", "NCAR_HPC_ROOT", "BENCH_IMAGE_DIR",
            "BENCH_RESULTS_ROOT", "BENCH_SCRATCH", "BENCH_ROOT",
            "BENCH_QUEUE", "BENCH_CORES_PER_NODE", "BENCH_SMT")

# What the host assumes when the profile does not say.  Deliberately the same
# numbers probe_topology.sh falls back to, and labelled the same way: a fallback
# must never be mistaken for a measurement.  The job re-derives all of this from
# lscpu on the compute node and its answer is the one that ends up in
# topology.json; this is only what can be known BEFORE the job runs, which is
# when a bad geometry is still cheap to reject.
FALLBACK_CORES_PER_NODE = 128
FALLBACK_SMT = 2
FALLBACK_SOURCE = "fallback:derecho-milan"


class Site(object):
    def __init__(self, name, conf, values):
        self.name = values.get("BENCH_SITE") or name
        self.conf = conf
        self.root = values.get("NCAR_HPC_ROOT", "")
        self.image_dir = values.get("BENCH_IMAGE_DIR", "")
        self.results_root = values.get("BENCH_RESULTS_ROOT", "")
        self.scratch = values.get("BENCH_SCRATCH", "")
        self.bench_root = values.get("BENCH_ROOT", "")
        self.queue = values.get("BENCH_QUEUE") or "main"

        self.cores_per_node = _int(values.get("BENCH_CORES_PER_NODE"))
        self.smt = _int(values.get("BENCH_SMT"))
        self.node_source = self.conf
        if not self.cores_per_node:
            self.cores_per_node, self.node_source = FALLBACK_CORES_PER_NODE, FALLBACK_SOURCE
            self.smt = self.smt or FALLBACK_SMT
        self.smt = self.smt or 1

    def image_path(self, sif):
        return os.path.join(self.image_dir, sif)

    def make_images(self, target):
        """Ask libexec/Makefile for a named image set.

        The Makefile is where "the six" is defined -- which OS, which compilers,
        which MPIs, and why -- so the experiment names the target rather than
        listing files that would drift out of step with it.
        """
        libexec = os.path.join(self.root, "libexec")
        try:
            out = subprocess.check_output(
                ["make", "--no-print-directory", "echo-" + target],
                cwd=libexec, stderr=subprocess.PIPE)
        except (OSError, subprocess.CalledProcessError) as exc:
            raise BenchError(
                "libexec/Makefile has no image list for %r" % target,
                EXIT_ERROR,
                ["ran: make echo-%s in %s" % (target, libexec),
                 "     %s" % exc,
                 "images.from_make must name a Makefile target that has a "
                 "matching echo- rule (derecho, derecho-hpcg, ...);",
                 "or list the .sif files explicitly with images.list"])
        return out.decode().split()


def _int(text):
    try:
        return int(str(text).strip())
    except (TypeError, ValueError):
        return 0


def find_conf(name, start=None):
    """The site profile, looked for the same three places a PBS script looks.

    $BENCH_SITE_CONF, then ~/.config/hpcdev/site.sh, then sites/<site>/site.sh
    walking up from `start`.  Keeping the order identical to the one inlined in
    the PBS scripts is the point: the host and the job must never disagree about
    which profile is in force.
    """
    named = os.environ.get("BENCH_SITE_CONF")
    if named and os.path.isfile(named):
        return named

    home = os.environ.get("XDG_CONFIG_HOME") or os.path.join(
        os.path.expanduser("~"), ".config")
    candidate = os.path.join(home, "hpcdev", "site.sh")
    if os.path.isfile(candidate):
        return candidate

    here = os.path.abspath(start or os.getcwd())
    while True:
        candidate = os.path.join(here, "sites", name, "site.sh")
        if os.path.isfile(candidate):
            return candidate
        parent = os.path.dirname(here)
        if parent == here:
            raise BenchError(
                "cannot find a site profile for %r" % name, EXIT_ERROR,
                ["looked for: $BENCH_SITE_CONF, "
                 "${XDG_CONFIG_HOME:-$HOME/.config}/hpcdev/site.sh,",
                 "            and sites/%s/site.sh above %s" % (name, start or os.getcwd())])
        here = parent


def load(name, start=None):
    conf = find_conf(name, start)
    script = ". %s >/dev/null 2>&1 || exit 1\n" % _quote(conf)
    script += "".join('printf "%%s\\n" "%s=${%s-}"\n' % (v, v) for v in EXPORTED)
    try:
        out = subprocess.check_output(["bash", "-c", script])
    except (OSError, subprocess.CalledProcessError):
        raise BenchError("cannot source the site profile %s" % conf, EXIT_ERROR,
                         ["it must be sourceable on a login node: only "
                          "assignments and function definitions,",
                          "no `module` calls at the top level"])

    values = {}
    for line in out.decode().splitlines():
        if "=" in line:
            key, _, value = line.partition("=")
            values[key] = value
    site = Site(name, conf, values)
    if not site.root or not os.path.isdir(os.path.join(site.root, "libexec")):
        raise BenchError("%s does not point NCAR_HPC_ROOT at a checkout with "
                         "libexec/" % conf, EXIT_ERROR,
                         ["NCAR_HPC_ROOT=%s" % (site.root or "<unset>")])
    return site


def _quote(text):
    return "'" + text.replace("'", "'\\''") + "'"
