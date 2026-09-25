"""benchlib -- the host side of the benchmark runner.

Small, single-purpose modules on purpose (plan section 6): five short files with
a header comment each beat one long script, for review, for testing, and for any
reader -- human or model -- working with a limited amount of context at a time.

    yamlish     read the YAML we write, with or without PyYAML
    schema      validate against bench/schema/*.json
    cluster     read sites/<site>/<cluster>/cluster.sh the way a job does
    sitefile    merge a site and a cluster description, generate cluster.sh
    experiment  load an experiment, expand its matrix into jobs and cells
    jobfile     render a job script, job.env and job.json

EXIT CODES

The interface of `bench validate`, and the reason it has one.  A script and an
agent both need to know WHICH kind of wrong a config is without reading prose,
and prose is the one thing neither can parse reliably.

The codes below are numbered in the order the checks run, so "the lowest code
found wins" and "the earliest thing that is wrong" are the same rule.  That
matters because the later checks are only meaningful once the earlier ones pass:
a config that does not parse has no image list to look for, and a placement the
site cannot run is wrong whether or not its .sif exists.  Reporting the later
problem would send the reader after the wrong thing.

All problems found at the failing stage are printed; the exit code names the
stage.
"""

EXIT_OK = 0
EXIT_ERROR = 1          # something unexpected: I/O, a broken site profile
EXIT_USAGE = 2          # bad command line (argparse's own convention)
EXIT_CONFIG = 3         # the YAML does not parse, or fails its schema
EXIT_GEOMETRY = 4       # a placement's ranks x threads is not a legal product
EXIT_IMAGE = 5          # a .sif named by the experiment is not on disk
EXIT_CONTRACT = 6       # an app has no /container/app.d/<app>/app.yaml

EXIT_NAMES = {
    EXIT_OK: "ok",
    EXIT_ERROR: "error",
    EXIT_USAGE: "usage",
    EXIT_CONFIG: "config-invalid",
    EXIT_GEOMETRY: "geometry-rejected",
    EXIT_IMAGE: "image-missing",
    EXIT_CONTRACT: "app-contract-missing",
}


class BenchError(Exception):
    """A problem with a definite kind.  `code` is what the tool exits with."""

    def __init__(self, message, code=EXIT_ERROR, detail=()):
        Exception.__init__(self, message)
        self.code = code
        self.detail = list(detail)
