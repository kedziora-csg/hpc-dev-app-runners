#!/bin/bash
#-------------------------------------------------------------------------------
# pin_image_digest.sh -- resolve a mutable registry tag to an immutable digest,
# and pin an Apptainer definition file to it.
#
#     ./pin_image_digest.sh --resolve ghcr.io/org/repo:tag
#     ./pin_image_digest.sh --pin <deffile> ghcr.io/org/repo:tag
#
# WHY
#
# `apptainer build` flattens the OCI layers into one SquashFS, so a finished
# .sif has no layer identity and no way to say which image build produced it.
# Both Deffiles bootstrap from a `-latest` tag, which is mutable: two SIFs built
# a week apart from the same tag are different content with nothing to tell them
# apart, and a benchmark result that names the tag names nothing reproducible.
#
# --pin fixes both halves at once:
#
#   1. rewrites `From: <repo>:<tag>` to `From: <repo>@sha256:...`, so the build
#      itself is immutable and the tag cannot move underneath it;
#   2. fills the `%labels` digest, so `apptainer inspect` -- and therefore
#      libexec/provenance.sh:sif_digest, and therefore every results.jsonl row
#      -- can name the exact artifact that was measured.
#
# Doing only (2) would leave a race: the tag could move between resolving it and
# building from it, and the label would then be a confident lie.
#
# WHEN IT CANNOT RESOLVE
#
# The .def keeps the tag and the label reads `unknown`.  The build still works;
# the results just record that the digest is not knowable, which is the honest
# answer and is exactly what a `null` digest in results.jsonl means.
#
# HOW IT RESOLVES
#
# skopeo and `docker buildx imagetools` if either is installed, otherwise the
# registry HTTP API with plain curl -- which is the case that matters, because
# an HPC login node has curl and generally has neither of the other two.  The
# curl path is written for ghcr.io's anonymous-pull token flow; another registry
# needs skopeo or an arm here.
#-------------------------------------------------------------------------------
set -u

usage () { sed -n '2,/^#---/p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; }

#-------------------------------------------------------------------------------
# resolve_digest <ref>   -- print sha256:... on success, nothing on failure
#-------------------------------------------------------------------------------
resolve_digest () {
    local ref="$1" d="" registry path tag token

    if command -v skopeo >/dev/null 2>&1; then
        d="$(skopeo inspect --format '{{.Digest}}' "docker://${ref}" 2>/dev/null)"
        [ -n "${d}" ] && { printf '%s' "${d}"; return 0; }
    fi

    if command -v docker >/dev/null 2>&1; then
        d="$(docker buildx imagetools inspect --format '{{.Manifest.Digest}}' "${ref}" 2>/dev/null)"
        [ -n "${d}" ] && { printf '%s' "${d}"; return 0; }
    fi

    command -v curl >/dev/null 2>&1 || return 1

    registry="${ref%%/*}"
    path="${ref#*/}"; path="${path%:*}"
    tag="${ref##*:}"
    [ "${registry}" = "ghcr.io" ] || return 1

    token="$(curl -sSL --max-time 30 \
        "https://${registry}/token?scope=repository:${path}:pull&service=${registry}" 2>/dev/null \
        | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')"
    [ -n "${token}" ] || return 1

    # Ask for every manifest type: a multi-arch image answers with an index and
    # a single-arch one with a manifest, and the digest we want is whichever the
    # tag actually points at.
    d="$(curl -sSI --max-time 30 -H "Authorization: Bearer ${token}" \
        -H 'Accept: application/vnd.oci.image.index.v1+json' \
        -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
        -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
        -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
        "https://${registry}/v2/${path}/manifests/${tag}" 2>/dev/null \
        | tr -d '\r' | sed -n 's/^[Dd]ocker-[Cc]ontent-[Dd]igest:[[:space:]]*//p' | head -1)"

    case "${d}" in
        sha256:*) printf '%s' "${d}"; return 0 ;;
        *)        return 1 ;;
    esac
}

#-------------------------------------------------------------------------------
# pin_deffile <deffile> <ref>
#-------------------------------------------------------------------------------
pin_deffile () {
    local def="$1" ref="$2" digest repo tmp
    [ -f "${def}" ] || { echo "pin_image_digest: no such file: ${def}" >&2; return 1; }

    repo="${ref%:*}"
    tmp="${def}.pin.$$"

    if digest="$(resolve_digest "${ref}")" && [ -n "${digest}" ]; then
        sed -e "s|^From:.*|From: ${repo}@${digest}|" \
            -e "s|<PLACEHOLDER_BASE_DIGEST>|${digest}|g" "${def}" > "${tmp}" \
            && mv "${tmp}" "${def}"
        echo "  pinned ${ref} -> ${digest}"
    else
        sed -e "s|<PLACEHOLDER_BASE_DIGEST>|unknown|g" "${def}" > "${tmp}" \
            && mv "${tmp}" "${def}"
        echo "  WARNING: could not resolve ${ref} to a digest;" >&2
        echo "           building from the mutable tag, digest recorded as unknown" >&2
    fi
    rm -f "${tmp}"
    return 0
}

case "${1:-}" in
    --resolve) [ $# -eq 2 ] || { usage >&2; exit 2; }
               d="$(resolve_digest "$2")" && [ -n "${d}" ] || exit 1
               echo "${d}" ;;
    --pin)     [ $# -eq 3 ] || { usage >&2; exit 2; }
               pin_deffile "$2" "$3" ;;
    -h|--help) usage ;;
    *)         usage >&2; exit 2 ;;
esac
