#!/usr/bin/env bash
set -euo pipefail

tag="${1:-}"
expected_commit="${2:-}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "release tag must be an exact stable vMAJOR.MINOR.PATCH tag" >&2
  exit 1
}
[[ "$expected_commit" =~ ^[0-9a-f]{40}$ ]] || {
  echo "expected commit must be a full lowercase Git object ID" >&2
  exit 1
}

mapfile -t remote_refs < <(git -C "$root" ls-remote origin "refs/tags/$tag" "refs/tags/$tag^{}")
(( ${#remote_refs[@]} >= 1 && ${#remote_refs[@]} <= 2 )) || {
  echo "release tag $tag is missing or ambiguous on origin" >&2
  exit 1
}
remote_commit="${remote_refs[-1]%%[[:space:]]*}"
[[ "$remote_commit" == "$expected_commit" ]] || {
  echo "release tag $tag moved from $expected_commit to $remote_commit" >&2
  exit 1
}

local_commit="$(git -C "$root" rev-parse HEAD)"
[[ "$local_commit" == "$expected_commit" ]] || {
  echo "checkout $local_commit does not match validated commit $expected_commit" >&2
  exit 1
}
version="$(tr -d '[:space:]' < "$root/VERSION")"
[[ "v$version" == "$tag" ]] || {
  echo "VERSION $version does not match $tag" >&2
  exit 1
}

