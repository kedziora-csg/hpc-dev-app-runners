"""sitefile -- read a site and a cluster description, merge them, render site.sh.

THE PROBLEM THIS SOLVES

A cluster's constants have several consumers and only some go through
bench/submit.  The generated jobs do; the hand-qsub entry point does not, and
neither does the factory's Placement_derecho.pbs, the three legacy PBS scripts,
or the off-cluster test suites.  So "bench/submit reads the YAML and writes the
values into job.env" would have left every other caller reading a literal
written into the shell, which is the duplication the contract exists to remove.

The one file all of those source is sites/<site>/<cluster>/cluster.sh.  So the
YAML is the authority and cluster.sh is generated FROM it, into a marked block;
the per-operator paths above the marker are never touched.  Every consumer keeps
sourcing one bash file, no compute node parses YAML, and there is no defensive
default anywhere -- a value exists once.

THREE LEVELS, TWO FILES

    site      NCAR            sites/ncar.yaml
    cluster   Derecho         sites/ncar/derecho.yaml
    node type the CPU nodes   subclusters: within the cluster file

The site holds what every cluster of it shares, which was sixteen values
duplicated between Derecho and Casper before this existed.  Both files are
checked against schema/cluster.json -- a site file is a partial cluster
description -- and are merged before anything is generated, so the flat block a
job sources is unchanged by the split.  The hierarchy is in how a machine is
DESCRIBED, not in what a job reads.

    scalars   the cluster's value wins
    lists     the site's entries first, then the cluster's, deduplicated
    maps      merged key by key, the cluster's value winning per key

There is deliberately no way to REMOVE an inherited value.  A site-level value
that some cluster must not have was never a site value, and moving it down is
the honest fix; a subtraction mechanism would let the two files disagree in a
way no reader could follow.

WHY GENERATED RATHER THAN COMPARED

The alternative was to keep cluster.sh hand-written and fail a test when it
disagreed with the YAML.  That is a real design with one advantage: nothing is
ever rewritten under the operator.  It also means every change is two edits, and
the test only tells you they diverged, never which one is right.  Generation
makes the question unaskable.  The precedent is here already: schema/README.md
is generated from the schemas by schemadoc, with --check failing the suite when
it is stale.

WHAT DOES NOT COME FROM THE YAML

The body of each MPI overlay recipe.  Which of Cray's two library directories
carries the MPICH ABI, and why OPAL_PREFIX must be pinned when the container
ships an Open MPI of its own, are arguments rather than data; they stay as code
in libexec/make_apptainer_launcher.sh.  The YAML names WHICH recipe a family
uses and supplies its binds, its library path and its environment.
"""

import os
import re

from . import BenchError, EXIT_CONFIG, EXIT_ERROR
from . import schema as schema_mod
from . import yamlish

BEGIN = "# >>> BEGIN GENERATED -- bench/sitegen"
END = "# <<< END GENERATED"

# Every value reaching the shell must be spellable inside a double-quoted bash
# assignment with no way out of it.  The schema patterns already exclude the
# dangerous characters; this is the backstop that makes that a property of the
# generator rather than of six separate regexes staying correct.
SAFE = re.compile(r"^[A-Za-z0-9 ._/:*,+=-]*$")

# ${NAME} is the one exception, and it is allowed for exactly one reason: a
# lib_dirs entry may name a directory that a module supplies.  It is checked
# against this and then emitted with the dollar ESCAPED, so the value the shell
# stores is the literal text `${NAME}` and not whatever that variable held when
# the profile was sourced -- which is usually nothing, because the module has
# not been loaded yet.  Expansion happens later and deliberately, by indirect
# reference in make_apptainer_launcher.sh.
VAR_REF = re.compile(r"\$\{[A-Za-z_][A-Za-z0-9_]*\}")

# The MPI families a container image can be built with.  Named here so an
# unknown family in a site file is a config error rather than a case arm that
# silently never matches.
FAMILIES = ("mpich", "mpich3", "openmpi")


class ClusterFile(object):
    """One cluster, as described by a site file and a cluster file together."""

    def __init__(self, path, site_path, data):
        self.path = path                # the cluster file
        self.site_path = site_path      # the site file it inherited from
        self.data = data                # the merged description
        self.name = data["cluster"]
        self.site = data["site"]

    @property
    def verified(self):
        return self.data.get("verified", True)


def sites_dir(start=None):
    """The nearest `sites/` above `start`, or above this code if there is none.

    The second is what lets the tools run from any directory: they know which
    checkout they belong to even when nobody is standing in it.
    """
    from_here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    for origin in (start or os.getcwd(), from_here):
        here = os.path.abspath(origin)
        while True:
            candidate = os.path.join(here, "sites")
            if os.path.isdir(candidate):
                return candidate
            parent = os.path.dirname(here)
            if parent == here:
                break
            here = parent
    raise BenchError("no sites/ directory above %s or %s"
                     % (start or os.getcwd(), from_here), EXIT_CONFIG)


def find(name, start=None):
    """sites/<site>/<cluster>.yaml, searched across every site.

    Globbed rather than requiring the caller to name the site, because an
    experiment names the cluster it wants and repeating the site in every
    experiment would be one more thing to keep in step.  Two sites owning a
    cluster of the same name is possible and is refused by name rather than
    resolved by guessing.
    """
    root = sites_dir(start)
    found = []
    for site in sorted(os.listdir(root)):
        candidate = os.path.join(root, site, name + ".yaml")
        if os.path.isfile(candidate):
            found.append(candidate)
    if len(found) == 1:
        return found[0]
    if not found:
        known = []
        for site in sorted(os.listdir(root)):
            d = os.path.join(root, site)
            if os.path.isdir(d):
                known += ["%s/%s" % (site, f[:-5])
                          for f in sorted(os.listdir(d)) if f.endswith(".yaml")]
        raise BenchError(
            "no description for cluster %r" % name, EXIT_CONFIG,
            ["looked for sites/*/%s.yaml under %s" % (name, root),
             "clusters described here: " + (", ".join(known) or "none")])
    raise BenchError(
        "cluster %r is described by more than one site" % name, EXIT_CONFIG,
        ["    " + p for p in found] +
        ["cluster names must be unique across sites, because an experiment",
         "names only the cluster.  Rename one of them."])


def load(name_or_path, start=None):
    """Load a cluster, merge its site into it, and check the result.

    Checking happens twice for a reason: each file alone must have no unknown
    keys, which catches a typo in the file it was made in; and the merged
    description must be complete, which neither file could satisfy on its own.
    """
    path = name_or_path
    if not os.path.isfile(path):
        path = find(name_or_path, start)
    cluster = _read(path)

    if "cluster" not in cluster:
        raise BenchError("%s describes no cluster" % path, EXIT_CONFIG,
                         ["a cluster file needs a `cluster:` key naming itself;",
                          "without one this is a site file, and site files are",
                          "loaded through the cluster that names them"])

    site_name = cluster.get("site")
    if not site_name:
        raise BenchError("%s names no site" % path, EXIT_CONFIG,
                         ["add `site: <name>`, and put what every cluster of",
                          "that site shares in sites/<name>.yaml"])

    site_path = os.path.join(sites_dir(os.path.dirname(path)), site_name + ".yaml")
    if not os.path.isfile(site_path):
        raise BenchError("%s names site %r, which has no description"
                         % (path, site_name), EXIT_CONFIG,
                         ["expected " + site_path])
    site = _read(site_path)
    if site.get("cluster"):
        raise BenchError("%s has a `cluster:` key" % site_path, EXIT_CONFIG,
                         ["that key is what marks a file as describing ONE",
                          "cluster, so a site file must not carry it"])

    data = merge(site, cluster)
    problems = complete_checks(data, path, site_path)
    problems.extend(cross_checks(data))
    if problems:
        raise BenchError("%s (merged with %s) is not a usable description"
                         % (path, site_path), EXIT_CONFIG, problems)
    return ClusterFile(path, site_path, data)


def _read(path):
    """Parse one description file and check its SHAPE, not its completeness."""
    try:
        data = yamlish.load(path)
    except (yamlish.YamlError, OSError) as exc:
        raise BenchError("cannot read %s" % path, EXIT_CONFIG, [str(exc)])
    if not isinstance(data, dict):
        raise BenchError("%s is not a mapping" % path, EXIT_CONFIG)
    problems = schema_mod.validate(data, "cluster")
    if problems:
        raise BenchError("%s does not satisfy bench/schema/cluster.json" % path,
                         EXIT_CONFIG, problems)
    return data


def merge(site, cluster):
    """The site's description with the cluster's laid over it.

    Scalars: the cluster wins.  Lists: the site's entries then the cluster's,
    deduplicated, order preserved -- so a bind list reads as "what NCAR mounts,
    then what this machine adds".  Maps: merged key by key, recursively.
    """
    out = dict(site)
    for key, value in cluster.items():
        if key not in out:
            out[key] = value
        elif isinstance(out[key], dict) and isinstance(value, dict):
            out[key] = merge(out[key], value)
        elif isinstance(out[key], list) and isinstance(value, list):
            seen, joined = set(), []
            for item in list(out[key]) + list(value):
                marker = repr(item)
                if marker not in seen:
                    seen.add(marker)
                    joined.append(item)
            out[key] = joined
        else:
            out[key] = value
    return out


# What a description must have once both halves are in hand.  Kept here rather
# than in the schema because the schema checks each file alone, where neither
# could satisfy this.
REQUIRED = (
    ("schema", None),
    ("site", None),
    ("cluster", None),
    ("scheduler", ("kind", "submit", "queue")),
    ("modules", ("bootstrap",)),
    ("node", ("cores", "smt")),
    ("container", ("runtime", "binds")),
    ("mpi", None),
)


def complete_checks(data, cluster_path, site_path):
    """Keys that must exist after merging, and where each could have come from."""
    out = []
    for key, subkeys in REQUIRED:
        if key not in data:
            out.append("no %s: -- state it in %s or in %s"
                       % (key, os.path.basename(cluster_path),
                          os.path.basename(site_path)))
            continue
        for subkey in subkeys or ():
            if subkey not in (data[key] or {}):
                out.append("no %s.%s: -- state it in %s or in %s"
                           % (key, subkey, os.path.basename(cluster_path),
                              os.path.basename(site_path)))
    if data.get("mpi") is not None and not data["mpi"]:
        out.append("mpi: is empty, so this cluster can host no container at all")
    return out


def cross_checks(data):
    """Rules that hold between keys, which a schema cannot state.

    Each one is a way for the file to be individually well-formed and still
    describe a machine no job could run on.
    """
    out = []
    if not isinstance(data.get("cluster"), str):
        return out                          # the schema already said so

    mpi = data.get("mpi") or {}
    mpi_map = (data.get("modules") or {}).get("mpi_map") or {}
    for family in sorted(mpi):
        if family not in mpi_map:
            out.append(
                "mpi.%s has no modules.mpi_map entry. An absent entry is not the "
                "same as an empty one: empty means the host MPI is already in the "
                "default environment, absent means nobody decided." % family)

    for family in sorted(mpi_map):
        if family not in mpi:
            out.append(
                "modules.mpi_map.%s names a module for a family mpi: does not "
                "list, so no launcher or overlay would ever be chosen for it"
                % family)

    for family, spec in sorted(mpi.items()):
        overlay = spec.get("overlay")
        launcher = spec.get("launcher")
        if overlay == "cray-mpich-abi" and launcher != "pals":
            out.append(
                "mpi.%s uses the Cray MPICH ABI shim but launcher: %s. The shim "
                "displaces the container's libmpi with Cray's, which bootstraps "
                "through PALS; another launcher would leave every rank to "
                "singleton-initialise." % (family, launcher))
        if overlay == "host-openmpi" and launcher == "pals":
            out.append(
                "mpi.%s runs the host Open MPI under the PALS launcher. Open MPI "
                "bootstraps over PMIx and spells every placement flag "
                "differently; use launcher: openmpi." % family)

    node = data.get("node") or {}
    cores, smt = node.get("cores"), node.get("smt")
    for key in ("cores_per_l3", "cores_per_numa"):
        value = node.get(key)
        if isinstance(value, int) and isinstance(cores, int) and value > cores:
            out.append("node.%s is %d, more than node.cores (%d)"
                       % (key, value, cores))
    stride = node.get("smt_stride")
    if isinstance(stride, int) and isinstance(cores, int) and isinstance(smt, int):
        if smt > 1 and stride != cores:
            out.append(
                "node.smt_stride is %d but node.cores is %d. Under the block "
                "layout the stride IS the core count; a different value means "
                "an interleaved layout, which the stride does not describe."
                % (stride, cores))

    for family in sorted(set(mpi) | set(mpi_map)):
        if family not in FAMILIES:
            out.append("unknown MPI family %r (expected %s)"
                       % (family, ", ".join(FAMILIES)))

    select = (data.get("node") or {}).get("select") or ""
    for clause in select.split(":"):
        if clause.startswith("place="):
            out.append(
                "node.select carries %r. `place` is a job-wide directive, not a "
                "per-chunk resource, so inside select= it would be read as a "
                "chunk resource of that name and quietly do nothing. Use "
                "scheduler.place." % clause)

    binds = (data.get("container") or {}).get("binds") or []
    bind_map = (data.get("container") or {}).get("bind_map") or {}
    for host_path in sorted(bind_map):
        if host_path in binds:
            out.append(
                "container.bind_map remaps %s, which container.binds also binds "
                "at its own name. The unconditional bind would land on top of "
                "the container's own tree." % host_path)
    return out


#-------------------------------------------------------------------------------
# Rendering
#-------------------------------------------------------------------------------

def _safe(value, where):
    """The text, checked but not yet quoted for any particular context.

    ${NAME} is allowed through; anything else carrying a dollar, a quote, a
    backtick or a backslash is refused rather than quoted, because a generator
    that tries to quote arbitrary text is a generator that eventually gets it
    wrong in a file every job sources.
    """
    text = "1" if value is True else "0" if value is False else str(value)
    if not SAFE.match(VAR_REF.sub("", text)):
        raise BenchError(
            "%s cannot be put into a shell assignment: %r" % (where, text),
            EXIT_CONFIG,
            ["a site value may hold letters, digits, space and . _ / : * , + = -",
             "plus ${NAME} to refer to a variable a module sets",
             "anything else would need quoting rules the generated block does "
             "not have"])
    return text


def _assign(name, value, where):
    """[ -n "${X+set}" ] || X='value' -- an environment override still wins.

    site.sh has always advertised that every setting honours an existing value,
    which is what makes `qsub -v BENCH_QUEUE=develop ...` work for a one-off, so
    a plain assignment would quietly take that away.

    `${X+set}` and not `${X:-}`, because those differ on the case that matters:
    a variable SET TO EMPTY.  With `-n` an empty value reads as absent and the
    default is applied anyway, so an operator could change an optional setting
    from the environment but never switch it OFF -- `BENCH_PLACE= submit ...`
    would silently keep emitting the site's place directive.  `+set` is true for
    a variable that exists at all, so an empty one means exactly what it looks
    like.  It is also the honest reading of what the header has always claimed:
    an exported empty variable is a value already in the environment.

    Written this way rather than as X="${X:-value}" because the default there is
    inside a parameter expansion, and a value containing ${NAME} -- which a
    lib_dirs entry may -- closes it at the wrong brace:

        BENCH_LIB_DIRS="${BENCH_LIB_DIRS:-a ${B}/c}"   ->   a ${B/c}

    Escaping the dollar does not help, since it is the BRACE that ends the
    expansion.  Single quotes take no expansion at all, so the stored text is
    exactly what the YAML said and the only forbidden character is the single
    quote itself, which _safe already refuses.
    """
    return "[ -n \"${%s+set}\" ] || %s='%s'" % (name, name, _safe(value, where))


def _case(fname, mapping, families, default="", comment=None):
    """A lookup function.  A case statement reads better than N variables and
    survives a family name that is not a legal identifier."""
    lines = []
    if comment:
        lines.extend("# " + line for line in comment.strip().splitlines())
    lines.append("%s () {" % fname)
    lines.append("    case \"$1\" in")
    for key in families:
        if key not in mapping:
            continue
        value = mapping[key]
        if isinstance(value, list):
            value = " ".join(str(v) for v in value)
        lines.append("        %-8s) echo '%s' ;;"
                     % (key, _safe(value, "%s.%s" % (fname, key))))
    lines.append("        %-8s) echo '%s' ;;" % ("*", default))
    lines.append("    esac")
    lines.append("}")
    return lines


def source_label(sf):
    """How the block names the files it came from.

    One definition because the label is INSIDE the generated text: sitegen and
    validate rendering it differently would make every profile look stale to one
    of them.
    """
    return "sites/%s.yaml + sites/%s/%s.yaml" % (sf.site, sf.site, sf.name)


def render(sf, source_rel=None):
    """The generated block, marker to marker, ending in a newline."""
    source_rel = source_rel or source_label(sf)
    d = sf.data
    sched, mods = d["scheduler"], d["modules"]
    node, cont, mpi = d["node"], d["container"], d["mpi"]

    out = [BEGIN,
           "#",
           "# Written from %s.  Do not edit between the markers: the next" % source_rel,
           "# `bench/sitegen %s --write` overwrites it, and bench/test_bench.sh" % sf.name,
           "# fails while it is stale.  Change the YAML instead.",
           "#",
           "# Every setting below honours a value already in the environment, so a",
           "# one-off `BENCH_QUEUE=develop bench/submit ...` wins over the file.",
           "# An EMPTY value counts: `BENCH_PLACE= bench/submit ...` switches an",
           "# optional setting off, which is not the same as leaving it unset."]
    if d.get("description"):
        out += ["#", "# " + d["description"]]
    if not sf.verified:
        out += ["#",
                "# UNVERIFIED: nothing here has been confirmed by a job that ran.",
                "# Treat every value as a hypothesis until one has."]
    out.append("")

    out.append("#-- identity and scheduler " + "-" * 47)
    # Two names, because there are two levels.  BENCH_SITE is the organisation
    # whose conventions the module names and GLADE belong to; BENCH_CLUSTER is
    # the machine.  Both reach every result row, so a row can be grouped either
    # way without anyone having to know that `derecho` implies NCAR.
    out.append(_assign("BENCH_SITE", d["site"], "site"))
    out.append(_assign("BENCH_CLUSTER", d["cluster"], "cluster"))
    out.append(_assign("BENCH_SCHEDULER", sched["kind"], "scheduler.kind"))
    out.append(_assign("BENCH_SUBMIT", sched["submit"], "scheduler.submit"))
    out.append(_assign("BENCH_QUEUE", sched["queue"], "scheduler.queue"))
    if sched.get("walltime_max"):
        out.append(_assign("BENCH_WALLTIME_MAX", sched["walltime_max"],
                           "scheduler.walltime_max"))
    if sched.get("place"):
        out.append("# Job-wide placement policy, its own directive rather than part of the")
        out.append("# select chunk.  Only stated where the queue's default is not what this")
        out.append("# site wants.")
        out.append(_assign("BENCH_PLACE", sched["place"], "scheduler.place"))
    out.append("")

    out.append("#-- node geometry: fallbacks, never measurements " + "-" * 26)
    out.append("# The job probes lscpu and topology.json carries THAT answer.  These")
    out.append("# are what can be known before there is a node to ask, which is when")
    out.append("# an illegal ranks x threads is still cheap to reject.")
    for key, var in (("cores", "BENCH_CORES_PER_NODE"),
                     ("smt", "BENCH_SMT"),
                     ("sockets", "BENCH_SOCKETS"),
                     ("smt_stride", "BENCH_SMT_STRIDE"),
                     ("cores_per_l3", "BENCH_CORES_PER_L3"),
                     ("cores_per_numa", "BENCH_CORES_PER_NUMA")):
        if node.get(key) is not None:
            out.append(_assign(var, node[key], "node." + key))
    out.append(_assign("BENCH_TOPOLOGY_MODE", node.get("topology", "probe"),
                       "node.topology"))
    if node.get("select"):
        out.append("")
        out.append("# How to ask the scheduler for THIS node type.  Appended to the select")
        out.append("# directive by bench/submit.  Without it a job takes whatever the pool")
        out.append("# offers, which is how the first Casper run measured hardware this file")
        out.append("# did not describe.")
        out.append(_assign("BENCH_NODE_SELECT", node["select"], "node.select"))
    if node.get("target_arch"):
        out.append("")
        out.append("# What this hardware runs, in report_cpu_features' spelling.  Checked")
        out.append("# against the app binary once at job start: a mismatch costs one line")
        out.append("# before the first cell instead of a SIGILL on every rank, three hours")
        out.append("# into a queue, with no output and exit 132.")
        out.append(_assign("BENCH_TARGET_ARCH", node["target_arch"],
                           "node.target_arch"))
    out.append("")

    out.append("#-- the container " + "-" * 56)
    out.append(_assign("BENCH_CONTAINER_RUNTIME", cont["runtime"],
                       "container.runtime"))
    out.append(_assign("BENCH_BINDS", " ".join(cont["binds"]), "container.binds"))
    out.append("# Bound only where the directory exists: apptainer treats a missing bind")
    out.append("# SOURCE as fatal, so an unconditional bind of a filesystem this machine")
    out.append("# may lack turns 'that mount is absent' into 'the job will not start'.")
    out.append(_assign("BENCH_BINDS_IF_PRESENT",
                       " ".join(cont.get("binds_if_present") or []),
                       "container.binds_if_present"))
    out.append("# host:container pairs, for a directory that must NOT land on top of the")
    out.append("# container's own tree.")
    out.append(_assign("BENCH_BIND_MAP",
                       " ".join("%s:%s" % (k, v)
                                for k, v in sorted((cont.get("bind_map") or {}).items())),
                       "container.bind_map"))
    out.append("# LD_LIBRARY_PATH inside the container, in order, after whatever the MPI")
    out.append("# overlay prepends.  A * entry is a glob and takes its newest match.")
    out.append(_assign("BENCH_LIB_DIRS", " ".join(cont.get("lib_dirs") or []),
                       "container.lib_dirs"))
    out.append("")

    out.append("#-- host modules " + "-" * 57)
    out += _case("bench_site_compiler_module", mods.get("compiler_map") or {},
                 sorted(mods.get("compiler_map") or {}),
                 comment="Container compiler tag to host module.  The host MPI that\n"
                         "displaces the container's must be built with a compatible\n"
                         "compiler, and the tag in the image name is what names which.")
    out.append("")
    out += _case("bench_site_mpi_module", mods.get("mpi_map") or {}, FAMILIES,
                 comment="Container MPI family to host module.  Empty means the host MPI is\n"
                         "already in the default environment and there is nothing to load.")
    out.append("")
    out += _case("bench_site_mpi_unload", mods.get("unload_when") or {}, FAMILIES,
                 comment="Modules to drop first, because one left loaded by a previous image\n"
                         "would put its own mpiexec and libraries ahead of this family's.")
    out.append("")

    out.append("#-- the host-MPI recipe, per container MPI family " + "-" * 25)
    out += _case("bench_site_mpi_launcher",
                 dict((f, s["launcher"]) for f, s in mpi.items()), FAMILIES,
                 comment="Which mpiexec dialect emits this family's placement flags.")
    out.append("")
    out += _case("bench_site_mpi_overlay",
                 dict((f, s["overlay"]) for f, s in mpi.items()), FAMILIES,
                 comment="Which recipe in libexec/make_apptainer_launcher.sh swaps the host\n"
                         "MPI in.  A name, not a description: the recipe body encodes\n"
                         "reasoning, and reasoning does not belong in a data file.")
    out.append("")
    out += _case("bench_site_mpi_env",
                 dict((f, ["%s=%s" % (k, v)
                           for k, v in sorted((s.get("env") or {}).items())])
                      for f, s in mpi.items()),
                 FAMILIES,
                 comment="NAME=VALUE, space separated, set inside the container for this\n"
                         "family.  Where a workaround specific to this machine goes.")
    out.append("")

    out.append("#-- the module environment every job starts from " + "-" * 26)
    out.append("# Order is the content, so this is a list rather than one command.")
    out.append("# Silenced because Lmod narrates every step; a failure still comes back")
    out.append("# through the return status, and modules.txt records the result anyway.")
    out.append("bench_site_modules () {")
    out.append("    {")
    steps = list(mods["bootstrap"])
    for i, step in enumerate(steps):
        joiner = " && \\" if i < len(steps) - 1 else ""
        out.append("        %s%s" % (_safe(step, "modules.bootstrap"), joiner))
    out.append("    } >/dev/null 2>&1")
    out.append("}")
    out.append("")

    out.append("export BENCH_SITE BENCH_CLUSTER BENCH_SCHEDULER BENCH_SUBMIT BENCH_QUEUE")
    out.append("export BENCH_CORES_PER_NODE BENCH_SMT BENCH_TOPOLOGY_MODE")
    out.append("export BENCH_CONTAINER_RUNTIME BENCH_BINDS BENCH_BINDS_IF_PRESENT")
    out.append("export BENCH_BIND_MAP BENCH_LIB_DIRS")
    optional = [("BENCH_WALLTIME_MAX", sched.get("walltime_max")),
                ("BENCH_SOCKETS", node.get("sockets")),
                ("BENCH_SMT_STRIDE", node.get("smt_stride")),
                ("BENCH_CORES_PER_L3", node.get("cores_per_l3")),
                ("BENCH_CORES_PER_NUMA", node.get("cores_per_numa")),
                ("BENCH_TARGET_ARCH", node.get("target_arch")),
                ("BENCH_NODE_SELECT", node.get("select")),
                ("BENCH_PLACE", sched.get("place"))]
    present = [name for name, value in optional if value is not None]
    if present:
        out.append("export " + " ".join(present))
    out.append(END)
    return "\n".join(out) + "\n"


#-------------------------------------------------------------------------------
# Splicing the block into site.sh
#-------------------------------------------------------------------------------

def split(text):
    """(before, generated, after).  `generated` is None when there is no block."""
    start = text.find(BEGIN)
    if start < 0:
        return text, None, ""
    end = text.find(END, start)
    if end < 0:
        raise BenchError(
            "site.sh has a %s marker with no %s" % (BEGIN.strip("# >"), END.strip("# <")),
            EXIT_ERROR,
            ["the generated block is not closed, so there is no way to tell",
             "what is generated and what somebody wrote by hand"])
    end = text.index("\n", end + len(END)) + 1
    return text[:start], text[start:end], text[end:]


def splice(text, block):
    before, generated, after = split(text)
    if generated is None:
        if before and not before.endswith("\n\n"):
            before = before.rstrip("\n") + "\n\n"
        return before + block
    return before + block + after
