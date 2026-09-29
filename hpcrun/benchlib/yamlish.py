"""yamlish -- read the YAML we write, with or without PyYAML.

We require human readability of an experiment. PyYAML is used whenever it is
importable and is the authority on what a file means.

The fallback exists because `bench validate` has to run in the two places PyYAML
is least likely to be installed -- a bare login node and a CI container -- and
those are exactly the places where "did I write this correctly?" needs an answer
in a second.  A validator you cannot run is not a validator.

WHAT THE FALLBACK ACCEPTS

Only the subset our own two formats use, and it is deliberately strict about the
rest so it fails rather than guesses:

    key: value                  scalars: int, float, true/false/null, quoted
    key:                        nested block, by indentation
    key: |                      block scalar (notes:)
    - scalar                    sequences
    - {a: 1, b: two}            flow mappings, as the placements list uses
    - name: x                   block mappings inside a sequence
    [a, b, c]                   flow sequences, as sweep.matrix uses
    # comment                   to end of line, outside quotes

Not accepted, on purpose: anchors, aliases, tags, multiple documents, complex
keys.  None appear in our files; each is a way for the fallback and PyYAML to
disagree about the same bytes, which is the only real risk here.  test_bench.sh
parses every shipped .yaml both ways and asserts the results are identical, so
that risk is checked rather than hoped about.
"""

import json
import os

try:                                    # PyYAML is the authority when present
    import yaml as _pyyaml
except ImportError:                     # pragma: no cover - depends on the host
    _pyyaml = None

HAVE_PYYAML = _pyyaml is not None


class YamlError(Exception):
    """A file we could not read.  Carries a line number where there is one."""


def load(path):
    """Parse a .yaml or .json file into plain Python data."""
    with open(path) as fh:
        text = fh.read()
    if path.endswith(".json"):
        try:
            return json.loads(text)
        except ValueError as exc:
            raise YamlError("%s: %s" % (path, exc))
    return loads(text, where=os.path.basename(path))


def loads(text, where="<string>"):
    if _pyyaml is not None:
        try:
            return _pyyaml.safe_load(text)
        except _pyyaml.YAMLError as exc:
            raise YamlError("%s: %s" % (where, exc))
    return _Fallback(text, where).parse()


#-------------------------------------------------------------------------------
# The fallback parser
#-------------------------------------------------------------------------------

def _split_outside(text, wanted):
    """Index of `wanted` at nesting depth 0 and outside quotes, or -1.

    One scan serves both jobs that need it: finding the `:` that ends a key, and
    finding the `#` that starts a comment.  Doing it by regex would get
    `binary: /container/bin/x  # note` right and `note: "a: b"` wrong.
    """
    depth, quote, i = 0, "", 0
    while i < len(text):
        ch = text[i]
        if quote:
            if ch == quote:
                quote = ""
        elif ch in "\"'":
            quote = ch
        elif depth == 0 and text.startswith(wanted, i):
            # Tested BEFORE the bracket arms, or a `}` could never be `wanted`:
            # it would decrement the depth it is being looked for at.
            return i
        elif ch in "[{":
            depth += 1
        elif ch in "]}":
            depth -= 1
        i += 1
    return -1


def _strip_comment(text):
    """Drop a trailing `# ...`, which YAML requires be preceded by a space."""
    i = 0
    while True:
        j = _split_outside(text[i:], "#")
        if j < 0:
            return text.rstrip()
        j += i
        if j == 0 or text[j - 1] in " \t":
            return text[:j].rstrip()
        i = j + 1


def _scalar(text):
    """One scalar, or a flow collection.  Returns the parsed value."""
    text = text.strip()
    if not text:
        return None
    if text[0] in "[{":
        value, rest = _flow(text)
        if rest.strip():
            raise YamlError("trailing junk after flow collection: %r" % rest)
        return value
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "\"'":
        return text[1:-1]
    low = text.lower()
    if low in ("true", "yes"):
        return True
    if low in ("false", "no"):
        return False
    if low in ("null", "~", ""):
        return None
    try:
        return int(text)
    except ValueError:
        pass
    try:
        return float(text)
    except ValueError:
        pass
    return text


def _flow(text):
    """Parse one flow collection off the front; return (value, remainder)."""
    close = "]" if text[0] == "[" else "}"
    is_map = close == "}"
    out = {} if is_map else []
    body = text[1:]
    while True:
        body = body.lstrip()
        if not body:
            raise YamlError("unterminated flow collection")
        if body[0] == close:
            return out, body[1:]
        if body[0] == ",":
            body = body[1:]
            continue
        # One element, up to the next comma or the closing bracket at depth 0.
        end = len(body)
        for want in (",", close):
            at = _split_outside(body, want)
            if at >= 0:
                end = min(end, at)
        item, body = body[:end].strip(), body[end:]
        if is_map:
            at = _split_outside(item, ":")
            if at < 0:
                raise YamlError("flow mapping entry without a colon: %r" % item)
            out[_scalar(item[:at])] = _scalar(item[at + 1:])
        else:
            out.append(_scalar(item))


class _Fallback(object):
    def __init__(self, text, where):
        self.where = where
        # (indent, content, lineno).  Blank and comment-only lines are dropped
        # here; block scalars re-read the raw text, which is why it is kept.
        self.raw = text.splitlines()
        self.lines = []
        for lineno, line in enumerate(self.raw):
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            self.lines.append((len(line) - len(line.lstrip()),
                               _strip_comment(line.strip()), lineno))

    def fail(self, lineno, msg):
        raise YamlError("%s:%d: %s" % (self.where, lineno + 1, msg))

    def parse(self):
        if not self.lines:
            return None
        value, at = self.block(0, self.lines[0][0])
        if at != len(self.lines):
            self.fail(self.lines[at][2], "unexpected indentation")
        return value

    def block(self, at, indent):
        if self.lines[at][1].startswith("-"):
            return self.sequence(at, indent)
        return self.mapping(at, indent)

    def sequence(self, at, indent):
        out = []
        while at < len(self.lines):
            ind, content, lineno = self.lines[at]
            if ind < indent:
                break
            if ind > indent or not content.startswith("-"):
                self.fail(lineno, "expected a `- ` item at indent %d" % indent)
            rest = content[1:].strip()
            at += 1
            if not rest:                       # the item's body is the next block
                if at < len(self.lines) and self.lines[at][0] > indent:
                    value, at = self.block(at, self.lines[at][0])
                else:
                    value = None
            elif rest[0] in "[{" or _split_outside(rest, ": ") < 0:
                value = _scalar(rest)          # plain scalar or a flow collection
            else:
                # `- name: x` and any continuation lines below it: one mapping
                # whose first entry happens to share the dash's line.
                value, at = self.inline_mapping(rest, lineno, at, indent)
            out.append(value)
        return out, at

    def inline_mapping(self, first, lineno, at, indent):
        key, value, at = self.entry(first, lineno, at, indent + 2)
        out = {key: value}
        # Continuation lines sit at the column the first key started in, which
        # is anything deeper than the dash.
        if at < len(self.lines) and self.lines[at][0] > indent:
            rest, at = self.mapping(at, self.lines[at][0])
            out.update(rest)
        return out, at

    def mapping(self, at, indent):
        out = {}
        while at < len(self.lines):
            ind, content, lineno = self.lines[at]
            if ind < indent:
                break
            if ind > indent:
                self.fail(lineno, "unexpected indentation (want %d)" % indent)
            at += 1
            key, value, at = self.entry(content, lineno, at, indent)
            if key in out:
                self.fail(lineno, "duplicate key %r" % key)
            out[key] = value
        return out, at

    def entry(self, content, lineno, at, indent):
        """One `key: ...` entry; `at` already points past its first line."""
        cut = _split_outside(content, ":")
        if cut < 0:
            self.fail(lineno, "expected `key: value`, got %r" % content)
        key = _scalar(content[:cut])
        rest = content[cut + 1:].strip()

        if rest[:1] in ("|", ">"):
            return key, self.block_scalar(lineno, rest), self.skip_block(at, indent)
        if rest:
            return key, _scalar(rest), at
        if at < len(self.lines) and self.lines[at][0] > indent:
            value, at = self.block(at, self.lines[at][0])
            return key, value, at
        return key, None, at

    def block_scalar(self, lineno, marker):
        """Gather the indented raw lines under a `|` or `>` marker.

        Read from self.raw, not self.lines: a `#` inside a block scalar is text,
        and a blank line inside one is a paragraph break, so neither may have
        been filtered out.
        """
        body, base = [], None
        for line in self.raw[lineno + 1:]:
            if not line.strip():
                body.append("")
                continue
            ind = len(line) - len(line.lstrip())
            if base is None:
                base = ind
            elif ind < base:
                break
            body.append(line[base:])
        while body and not body[-1]:
            body.pop()
        joined = "\n".join(body)
        if marker.startswith(">"):
            joined = " ".join(x for x in joined.split() if x)
        return joined + ("" if marker.endswith("-") else "\n")

    def skip_block(self, at, indent):
        while at < len(self.lines) and self.lines[at][0] > indent:
            at += 1
        return at
