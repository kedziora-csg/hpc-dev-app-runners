"""schema -- check a parsed config against bench/schema/*.json.

WHY A SCHEMA AT ALL

It turns "did I write this correctly?" into a check that runs in a second,
instead of a build failure three hours into a queue.  It also gives an editor
autocomplete, and gives anything authoring these files -- a person on their
second experiment, or eventually a local model -- a target it can check itself
against without a cluster.

WHY A VALIDATOR IN HERE

`jsonschema` is the right library and is used whenever it imports.  It is also
not installed on a bare login node, and a check you cannot run where you write
the file is not a check.  The fallback covers the keywords our own two schemas
use and refuses anything else outright, so a schema cannot silently grow a
keyword that only one of the two validators enforces.
"""

import json
import os
import re

try:
    import jsonschema as _jsonschema
except ImportError:                     # pragma: no cover - depends on the host
    _jsonschema = None

HAVE_JSONSCHEMA = _jsonschema is not None

SCHEMA_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                          "schema")

# Everything the fallback implements.  A keyword outside this set in one of our
# schemas is a bug in the schema, not a gap to be tolerated -- see _check_known.
_HANDLED = {
    "type", "required", "properties", "patternProperties", "additionalProperties",
    "items", "minItems", "uniqueItems", "enum", "const", "minimum", "maximum",
    "minLength", "pattern", "minProperties", "anyOf", "oneOf", "$ref",
}
_IGNORED = {"$schema", "$id", "$defs", "title", "description", "default",
            "examples", "deprecated"}

_TYPES = {
    "object": dict, "array": list, "string": str, "boolean": bool,
    "number": (int, float), "integer": int, "null": type(None),
}


def load_schema(name):
    with open(os.path.join(SCHEMA_DIR, name + ".json")) as fh:
        return json.load(fh)


def validate(data, schema_name):
    """Return a list of human-readable problems; empty means valid."""
    schema = load_schema(schema_name)
    if _jsonschema is not None:
        validator = _jsonschema.Draft202012Validator(schema)
        return ["%s: %s" % (_where(err.absolute_path), err.message)
                for err in sorted(validator.iter_errors(data), key=str)]
    _check_known(schema)
    problems = []
    _validate(data, schema, schema, [], problems)
    return problems


def _where(path):
    return "$" + "".join("[%d]" % p if isinstance(p, int) else "." + str(p)
                         for p in path) if list(path) else "$"


def _check_known(node, seen=None):
    """Refuse a schema using a keyword the fallback would silently ignore."""
    seen = seen if seen is not None else set()
    if id(node) in seen or not isinstance(node, dict):
        return
    seen.add(id(node))
    for key, value in node.items():
        if key in _HANDLED or key in _IGNORED:
            pass
        else:
            raise ValueError("schema uses unsupported keyword %r; either add it "
                             "to benchlib/schema.py or drop it" % key)
        if isinstance(value, dict):
            if key in ("properties", "patternProperties", "$defs"):
                for sub in value.values():
                    _check_known(sub, seen)
            else:
                _check_known(value, seen)
        elif isinstance(value, list) and key in ("anyOf", "oneOf"):
            for sub in value:
                _check_known(sub, seen)


def _type_ok(value, want):
    for name in ([want] if isinstance(want, str) else want):
        expect = _TYPES[name]
        if name == "integer" and isinstance(value, bool):
            continue                    # bool is an int in Python; not in JSON
        if name in ("number", "integer") and isinstance(value, bool):
            continue
        if isinstance(value, expect):
            return True
    return False


def _validate(value, node, root, path, out):
    def bad(msg):
        out.append("%s: %s" % (_where(path), msg))

    if "$ref" in node:
        ref = node["$ref"]
        if not ref.startswith("#/"):
            raise ValueError("only local $ref is supported, got %r" % ref)
        target = root
        for part in ref[2:].split("/"):
            target = target[part]
        node = dict(target, **{k: v for k, v in node.items() if k != "$ref"})

    for combiner in ("anyOf", "oneOf"):
        if combiner in node:
            hits = 0
            for sub in node[combiner]:
                probe = []
                _validate(value, sub, root, path, probe)
                hits += not probe
            if (combiner == "anyOf" and hits < 1) or (combiner == "oneOf" and hits != 1):
                bad("matches %d of the %d alternatives in %s" %
                    (hits, len(node[combiner]), combiner))

    if "const" in node and value != node["const"]:
        bad("must be %r, got %r" % (node["const"], value))
    if "enum" in node and value not in node["enum"]:
        bad("must be one of %s, got %r" % (", ".join(map(repr, node["enum"])), value))
    if "type" in node and not _type_ok(value, node["type"]):
        bad("must be %s, got %s" % (node["type"], type(value).__name__))
        return                          # nothing below can be meaningful

    if isinstance(value, str):
        if "pattern" in node and not re.search(node["pattern"], value):
            bad("must match /%s/, got %r" % (node["pattern"], value))
        if "minLength" in node and len(value) < node["minLength"]:
            bad("must be at least %d characters" % node["minLength"])

    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in node and value < node["minimum"]:
            bad("must be >= %s, got %s" % (node["minimum"], value))
        if "maximum" in node and value > node["maximum"]:
            bad("must be <= %s, got %s" % (node["maximum"], value))

    if isinstance(value, list):
        if "minItems" in node and len(value) < node["minItems"]:
            bad("needs at least %d item(s)" % node["minItems"])
        if node.get("uniqueItems") and len(value) != len(set(map(repr, value))):
            bad("entries must be unique")
        if "items" in node:
            for i, item in enumerate(value):
                _validate(item, node["items"], root, path + [i], out)

    if isinstance(value, dict):
        if "minProperties" in node and len(value) < node["minProperties"]:
            bad("needs at least %d key(s)" % node["minProperties"])
        for key in node.get("required", []):
            if key not in value:
                bad("missing required key %r" % key)
        props = node.get("properties", {})
        patterns = node.get("patternProperties", {})
        extra = node.get("additionalProperties", True)
        for key, sub in value.items():
            if key in props:
                _validate(sub, props[key], root, path + [key], out)
                continue
            matched = [s for p, s in patterns.items() if re.search(p, str(key))]
            if matched:
                for s in matched:
                    _validate(sub, s, root, path + [key], out)
            elif extra is False:
                bad("unknown key %r (known: %s)" %
                    (key, ", ".join(sorted(props)) or "none"))
            elif isinstance(extra, dict):
                _validate(sub, extra, root, path + [key], out)
