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

WHERE THE VALUES COME FROM NOW

Everything below the hand-edited paths is generated into site.sh from
sites/<site>.yaml by bench/sitegen -- see benchlib/sitefile.py for why that
direction and not the other.  So this module has no constants of its own: it
reads what the profile exports, and a profile that exports nothing is an error
rather than an occasion to assume Derecho.  The host used to keep its own copy
of the node geometry, which meant three files stating 128 cores and nothing
comparing them.
"""

import os
import subprocess

from . import BenchError, EXIT_ERROR

# Read back after sourcing.  Every one is exported by site.sh itself, so adding
# a name to this list is not enough -- the profile has to export it, which for
# everything except the four paths means adding it to sitefile.render.
EXPORTED = ("BENCH_SITE", "NCAR_HPC_ROOT", "BENCH_IMAGE_DIR",
            "BENCH_RESULTS_ROOT", "BENCH_SCRATCH", "BENCH_ROOT",
            "BENCH_SCHEDULER", "BENCH_SUBMIT", "BENCH_QUEUE",
            "BENCH_WALLTIME_MAX", "BENCH_CORES_PER_NODE", "BENCH_SMT",
            "BENCH_TARGET_ARCH", "BENCH_TOPOLOGY_MODE", "BENCH_NODE_SELECT",
            "BENCH_PLACE")


class Site(object):
    def __init__(self, name, conf, values):
        self.name = values.get("BENCH_SITE") or name
        self.conf = conf
        self.root = values.get("NCAR_HPC_ROOT", "")
        self.image_dir = values.get("BENCH_IMAGE_DIR", "")
        self.results_root = values.get("BENCH_RESULTS_ROOT", "")
        self.scratch = values.get("BENCH_SCRATCH", "")
        self.bench_root = values.get("BENCH_ROOT", "")
        self.scheduler = values.get("BENCH_SCHEDULER") or ""
        self.submit_cmd = values.get("BENCH_SUBMIT") or ""
        self.queue = values.get("BENCH_QUEUE") or ""
        self.walltime_max = values.get("BENCH_WALLTIME_MAX") or ""
        self.target_arch = values.get("BENCH_TARGET_ARCH") or ""
        self.topology_mode = values.get("BENCH_TOPOLOGY_MODE") or "probe"
        self.node_select = values.get("BENCH_NODE_SELECT") or ""
        self.place = values.get("BENCH_PLACE") or ""

        self.cores_per_node = _int(values.get("BENCH_CORES_PER_NODE"))
        self.smt = _int(values.get("BENCH_SMT"))
        # The profile is where these live now, so an unset one means the block
        # was never generated -- almost always a ~/.config/hpcdev/site.sh copied
        # before sitegen existed.  Assuming Derecho here is exactly the silent
        # wrong answer the generated block was introduced to remove: it would
        # accept a 128-core geometry on a machine that has 36.
        if not self.cores_per_node or not self.smt:
            raise BenchError(
                "%s does not describe the node" % conf, EXIT_ERROR,
                ["BENCH_CORES_PER_NODE=%s BENCH_SMT=%s"
                 % (values.get("BENCH_CORES_PER_NODE") or "<unset>",
                    values.get("BENCH_SMT") or "<unset>"),
                 "these come from the generated block of site.sh, written from",
                 "sites/%s.yaml by bench/sitegen.  A profile without one is" % self.name,
                 "either older than sitegen or a hand-made copy:",
                 "    bench/sitegen %s --write        regenerate it" % self.name,
                 "    cp sites/%s/site.sh ~/.config/hpcdev/   refresh your copy"
                 % self.name])
        self.node_source = self.conf

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


def profile_site(conf):
    """The site a profile names, or "" if it cannot be read.

    Cheap enough to do while searching: the profile only assigns and defines, so
    sourcing it costs one subshell and no `module` command runs.
    """
    try:
        return _exported(conf, ("BENCH_SITE",)).get("BENCH_SITE", "")
    except (OSError, subprocess.CalledProcessError):
        return ""


def find_conf(name, start=None):
    """The site profile, looked for the same three places a PBS script looks.

    $BENCH_SITE_CONF, then ~/.config/hpcdev/site.sh, then sites/<site>/site.sh
    walking up from `start`.  Keeping the order identical to the one inlined in
    the PBS scripts is the point: the host and the job must never disagree about
    which profile is in force.

    THE ~/.config COPY HOLDS ONE SITE

    That path has no site in it, so a copy made for one machine used to answer a
    request for another -- and because a Site takes its name from the profile it
    read, an experiment saying `site: casper` would run Derecho's core count,
    paths and MPI recipe without a word.  So the copy is now accepted only if it
    names the site being asked for, and is otherwise skipped so the search falls
    through to the checkout's own profile.  Working on two machines needs no
    setup beyond having both described.
    """
    named = os.environ.get("BENCH_SITE_CONF")
    if named and os.path.isfile(named):
        return named

    home = os.environ.get("XDG_CONFIG_HOME") or os.path.join(
        os.path.expanduser("~"), ".config")
    candidate = os.path.join(home, "hpcdev", "site.sh")
    if os.path.isfile(candidate) and profile_site(candidate) in (name, ""):
        return candidate

    # Walking up from where you are, then from where THIS CODE is.
    #
    # The second is what lets `/path/to/checkout/bench/submit` work from any
    # directory on the machine: the tool knows which checkout it belongs to, so
    # standing somewhere else is not a reason to fail.  It is tried second, not
    # first, so a person working inside a checkout still gets that checkout's
    # profile even when they invoked another one's script.
    from_here = os.path.dirname(os.path.abspath(__file__))
    for origin in (start or os.getcwd(), from_here):
        found = _walk_up(name, origin)
        if found:
            return found

    raise BenchError(
        "cannot find a site profile for %r" % name, EXIT_ERROR,
        ["looked for: $BENCH_SITE_CONF, "
         "${XDG_CONFIG_HOME:-$HOME/.config}/hpcdev/site.sh,",
         "            sites/%s/site.sh above %s" % (name, start or os.getcwd()),
         "            and sites/%s/site.sh above %s" % (name, from_here),
         "a ~/.config copy for a DIFFERENT site is skipped, not used"])


def _walk_up(name, origin):
    """sites/<name>/site.sh in `origin` or any directory above it, or None."""
    here = os.path.abspath(origin)
    while True:
        candidate = os.path.join(here, "sites", name, "site.sh")
        if os.path.isfile(candidate):
            return candidate
        parent = os.path.dirname(here)
        if parent == here:
            return None
        here = parent


def load(name, start=None):
    # Absolute from here on.  A generated job script names this path outright
    # and PBS runs it from its own spool directory, so a relative $BENCH_SITE_CONF
    # -- which is how anyone would type it on a login node -- would resolve to
    # nothing once the job started, three hours later.
    conf = os.path.abspath(find_conf(name, start))
    try:
        values = _exported(conf, EXPORTED)
    except (OSError, subprocess.CalledProcessError):
        raise BenchError("cannot source the site profile %s" % conf, EXIT_ERROR,
                         ["it must be sourceable on a login node: only "
                          "assignments and function definitions,",
                          "no `module` calls at the top level"])

    # The last line of defence, and the one that covers $BENCH_SITE_CONF: naming
    # a profile explicitly is allowed to override where it is found, never which
    # machine it describes.  Running Derecho's core count and bind list under a
    # Casper experiment produces results that are wrong in a way no reader could
    # detect afterwards, so it is refused rather than reported.
    found = values.get("BENCH_SITE") or ""
    if found and found != name:
        raise BenchError(
            "%s describes %r, but %r was asked for" % (conf, found, name),
            EXIT_ERROR,
            ["this profile was found via $BENCH_SITE_CONF" if
             os.environ.get("BENCH_SITE_CONF") else
             "this profile was found by searching upwards",
             "point BENCH_SITE_CONF at sites/%s/site.sh, or unset it and let" % name,
             "the search find the checkout's own profile"])

    site = Site(name, conf, values)
    if not site.root or not os.path.isdir(os.path.join(site.root, "libexec")):
        raise BenchError("%s does not point NCAR_HPC_ROOT at a checkout with "
                         "libexec/" % conf, EXIT_ERROR,
                         ["NCAR_HPC_ROOT=%s" % (site.root or "<unset>")])
    return site


def _exported(conf, names):
    """Source `conf` in a subshell and read back `names`.

    Sourcing rather than parsing, because the profile is bash and the host must
    read exactly what a job will.  Safe: it only assigns and defines, and
    bench_site_modules is declared there and never called, so no `module`
    command runs on the login node.
    """
    script = ". %s >/dev/null 2>&1 || exit 1\n" % _quote(conf)
    script += "".join('printf "%%s\\n" "%s=${%s-}"\n' % (v, v) for v in names)
    out = subprocess.check_output(["bash", "-c", script])
    values = {}
    for line in out.decode().splitlines():
        if "=" in line:
            key, _, value = line.partition("=")
            values[key] = value
    return values


def _quote(text):
    return "'" + text.replace("'", "'\\''") + "'"
