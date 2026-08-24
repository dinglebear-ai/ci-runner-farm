#!/usr/bin/env bash
set -euo pipefail

image="${1:-}"
tag="${2:-}"
actor="${3:-}"
token="${4:-}"

[[ "$image" =~ ^ghcr\.io/([a-z0-9_.-]+)/([a-z0-9_.-]+)$ ]] || {
  echo "image must be a lowercase two-segment ghcr.io path" >&2
  exit 1
}
repository="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
[[ "$tag" =~ ^sha-[0-9a-f]{40}$ ]] || {
  echo "image tag must be sha- followed by a full commit ID" >&2
  exit 1
}
[[ -n "$actor" && -n "$token" ]] || {
  echo "registry actor and token are required" >&2
  exit 1
}

registry_token="$(
  curl --fail --silent --show-error --user "$actor:$token" \
    "https://ghcr.io/token?scope=repository:$repository:pull" |
    jq -er '.token'
)"
headers="$(mktemp)"
trap 'rm -f "$headers"' EXIT
status="$(
  curl --silent --show-error --output /dev/null --dump-header "$headers" \
    --write-out '%{http_code}' \
    --header "Authorization: Bearer $registry_token" \
    --header 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
    "https://ghcr.io/v2/$repository/manifests/$tag"
)"

case "$status" in
  404)
    printf 'absent\n'
    ;;
  200)
    digest="$(sed -n 's/^[Dd]ocker-[Cc]ontent-[Dd]igest:[[:space:]]*\(sha256:[0-9a-f]\{64\}\)\r\{0,1\}$/\1/p' "$headers")"
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
      echo "registry returned 200 without one valid Docker-Content-Digest" >&2
      exit 1
    }
    printf '%s\n' "$digest"
    ;;
  *)
    echo "registry manifest lookup failed with HTTP $status" >&2
    exit 1
    ;;
esac
