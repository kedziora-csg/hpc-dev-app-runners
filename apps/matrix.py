#!/usr/bin/env python3
"""matrix.py -- the app images a cluster runs, as a GitHub Actions matrix.

    apps/matrix.py derecho                       every app image derecho runs
    apps/matrix.py casper --apps hpcg            one app
    apps/matrix.py derecho --compilers gcc14 --mpis openmpi
    apps/matrix.py derecho --table               the same, for a person
    apps/matrix.py derecho --tag-suffix pbase    every tag ends -pbase

The workflow's only view of the machine descriptions.  The images: block of
sites/<site>/<cluster>.yaml already says which OS, compilers, MPI families and
apps a cluster runs, and the target and flags they are built for; this turns it
into one matrix entry per app image, so the images a workflow builds and the
images `make <cluster>-<app>` in sif/ expects are one list, not two that drift.

The filters narrow that list and never widen it: naming a compiler the cluster
does not run is an error, not a new image.  The output is {"include": [...]},
which a job expands with fromJSON -- so no static axis exists for an include:
entry to fail to merge into (the matrix gotcha in CLAUDE.md).
"""

import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "hpcrun"))

from benchlib import BenchError, sitefile     # noqa: E402


def narrow(entries, key, wanted):
    if not wanted:
        return entries
    wanted = [w for w in wanted.replace(",", " ").split() if w]
    have = sorted({e[key] for e in entries})
    unknown = [w for w in wanted if w not in have]
    if unknown:
        raise BenchError("not in this cluster's images: %s %s"
                         % (key, ", ".join(unknown)), 2,
                         ["it runs: %s" % ", ".join(have)])
    return [e for e in entries if e[key] in wanted]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("cluster")
    ap.add_argument("--apps", default="")
    ap.add_argument("--compilers", default="")
    ap.add_argument("--mpis", default="")
    ap.add_argument("--tag-suffix", default="",
                    help="append -SUFFIX to every app tag: a build that must not "
                         "take the regular tag, because one tag means one build")
    ap.add_argument("--table", action="store_true",
                    help="print a table rather than the JSON matrix")
    args = ap.parse_args()

    sf = sitefile.load(args.cluster)
    entries = sitefile.app_builds(sf)
    if not entries:
        raise BenchError("cluster %s states no apps in its images: block"
                         % args.cluster, 2)
    entries = narrow(entries, "app", args.apps)
    entries = narrow(entries, "compiler", args.compilers)
    entries = narrow(entries, "mpi", args.mpis)
    suffix = args.tag_suffix.strip()
    if suffix:
        if not suffix.replace("_", "").isalnum() or suffix != suffix.lower():
            raise BenchError("--tag-suffix %r: lower-case letters, digits and _ "
                             "only" % suffix, 2)
        for e in entries:
            e["tag"] += "-" + suffix

    if args.table:
        for e in entries:
            print("%-40s from %-24s %s" % (e["tag"], e["base_tag"],
                                           e["march"] or "(base image's flags)"))
        return 0
    json.dump({"include": entries}, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BenchError as exc:
        print("error: %s" % exc, file=sys.stderr)
        for line in exc.detail:
            print("  " + line, file=sys.stderr)
        sys.exit(exc.code or 1)
