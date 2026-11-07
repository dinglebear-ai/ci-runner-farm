#!/usr/bin/env bash
set -euo pipefail
# Engine configuration and Docker mock state are consumed through dynamic scope.
# shellcheck disable=SC2034
cd "$(dirname "$0")/.."
test_root="$(mktemp -d)"; trap 'rm -rf "$test_root"' EXIT
export CRF_CFGDIR="$test_root/config" CRF_RUNDIR="$test_root/run"
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR" "$test_root/images"
CFGDIR="$CRF_CFGDIR"
RUNDIR="$CRF_RUNDIR"
BUILD_CANDIDATE_FILE="$CFGDIR/build-candidate.state"
PROMOTED_IMAGE_FILE="$CFGDIR/promoted-image.state"
KACHE_ENDPOINT_FILE="$CFGDIR/kache-endpoint"
BUILTIN_IMAGE=ci-runner-farm-runner:latest
ENGINE=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
awk '/^build_candidate_tag_valid\(\)/ {copy=1} /^# Called from the plugin install step/ {copy=0} copy {print}' "$ENGINE" > "$test_root/functions.sh"
# shellcheck source=/dev/null
source "$test_root/functions.sh"
json_escape() { sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
resource_positive_uint_valid() { [[ "${1:-}" =~ ^[1-9][0-9]*$ ]] && [ "$1" -le "$2" ]; }
id="sha256:$(printf 'a%.0s' {1..64})"
fail_build=false
collision=false
inspect_mismatch=false
fail_publish=false
fail_stage=false
mktemp() { [ "$fail_stage" = false ] || return 1; command mktemp "$@"; }
mv() { [ "$fail_publish" = false ] || [ "${!#}" != "$PROMOTED_IMAGE_FILE" ] || return 1; command mv "$@"; }
log() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }
docker() {
  case "$1 $2" in
    'build -t')
      printf '%s\n' "$@" > "$test_root/argv"
      local context="${!#}" tag="$3"
      find "$context" -maxdepth 1 -type f -printf '%f\n' | sort > "$test_root/context"
      cp "$context/Dockerfile" "$test_root/built-dockerfile"
      printf 'RUN endpoint=%s\n' "${KACHE_REMOTE_ENDPOINT:-}"
      [ "$fail_build" = false ] || return 42
      printf '%s' "$id" > "$test_root/images/${tag//\//_}"
      ;;
    'image inspect')
      [ "$collision" = false ] || return 0
      if [ "$inspect_mismatch" = true ]; then printf 'sha256:%064d\n' 0; return; fi
      [ -f "$test_root/images/${3//\//_}" ] || return 1
      cat "$test_root/images/${3//\//_}"
      ;;
    'image rm') rm "$test_root/images/${BUILTIN_IMAGE//\//_}" ;;
    'tag '*)
      printf '%s\n' "$2" > "$test_root/tag-source"
      [[ "$2" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
      printf '%s' "$2" > "$test_root/images/${3//\//_}"
      ;;
    *) echo "unexpected Docker call: $1 $2" >&2; return 99 ;;
  esac
}
cat > "$CFGDIR/Dockerfile" <<'DF'
FROM scratch
COPY endpoint-validation.sh /usr/local/libexec/ci-runner-farm/endpoint-validation.sh
COPY kache-supervise.sh /usr/local/bin/kache-supervise.sh
ARG KACHE_REMOTE_ENDPOINT
DF
printf '#!/bin/sh\nexit 0\n' > "$CFGDIR/endpoint-validation.sh"
cp "$CFGDIR/endpoint-validation.sh" "$CFGDIR/kache-supervise.sh"
printf 'https://cache.internal:443/cache\n' > "$KACHE_ENDPOINT_FILE"; chmod 600 "$KACHE_ENDPOINT_FILE"
printf 'DO NOT COPY' > "$CFGDIR/token"
cmd_build_image > "$test_root/log" 2>&1 || { cat "$test_root/log"; exit 1; }
printf '%s\n' Dockerfile endpoint-validation.sh kache-supervise.sh > "$test_root/expected"
cmp "$test_root/expected" "$test_root/context"
if grep -Fq 'https://cache.internal' "$test_root/log"; then exit 1; fi
if grep -Fq 'https://cache.internal' "$test_root/argv"; then exit 1; fi
grep -Fxq KACHE_REMOTE_ENDPOINT "$test_root/argv"
[ ! -e "$test_root/tag-source" ]
[ "$(stat -c %a "$BUILD_CANDIDATE_FILE")" = 600 ]
build_candidate_state_load
candidate="$BUILD_CANDIDATE_TAG"
[ "$BUILD_CANDIDATE_IMAGE_ID" = "$id" ]
cp "$BUILD_CANDIDATE_FILE" "$test_root/receipt"
# Exact image ID and saved tag bind promotion. Invalid attempts leave production untouched.
if cmd_promote_image "$candidate" "sha256:$(printf 'b%.0s' {1..64})" >/dev/null 2>&1; then exit 1; fi
inspect_mismatch=true
if cmd_promote_image "$candidate" "$id" >/dev/null 2>&1; then exit 1; fi
inspect_mismatch=false
[ ! -e "$test_root/tag-source" ]
# Receipt staging failure cannot touch the production alias.
fail_stage=true
if cmd_promote_image "$candidate" "$id" >/dev/null 2>&1; then exit 1; fi
[ ! -e "$test_root/tag-source" ]
fail_stage=false
mkdir "$PROMOTED_IMAGE_FILE"
if cmd_promote_image "$candidate" "$id" >/dev/null 2>&1; then exit 1; fi
[ ! -e "$test_root/tag-source" ]
rmdir "$PROMOTED_IMAGE_FILE"
ln -s "$test_root/unused-target" "$PROMOTED_IMAGE_FILE"
if cmd_promote_image "$candidate" "$id" >/dev/null 2>&1; then exit 1; fi
[ ! -e "$test_root/tag-source" ]; [ ! -e "$test_root/unused-target" ]
rm "$PROMOTED_IMAGE_FILE"
# Failed receipt publication rolls back an absent alias, then an existing alias.
fail_publish=true
if cmd_promote_image "$candidate" "$id" >/dev/null 2>&1; then exit 1; fi
[ ! -e "$test_root/images/${BUILTIN_IMAGE//\//_}" ]
previous="sha256:$(printf 'b%.0s' {1..64})"
printf '%s' "$previous" > "$test_root/images/${BUILTIN_IMAGE//\//_}"
printf 'prior receipt' > "$PROMOTED_IMAGE_FILE"
if cmd_promote_image "$candidate" "$id" >/dev/null 2>&1; then exit 1; fi
[ "$(cat "$test_root/images/${BUILTIN_IMAGE//\//_}")" = "$previous" ]
[ "$(cat "$PROMOTED_IMAGE_FILE")" = 'prior receipt' ]
[ -f "$BUILD_CANDIDATE_FILE" ]
fail_publish=false
cmd_promote_image "$candidate" "$id" > "$test_root/promotion"
[ "$(cat "$test_root/tag-source")" = "$id" ]
[ "$(stat -c %a "$PROMOTED_IMAGE_FILE")" = 600 ]
[ ! -e "$BUILD_CANDIDATE_FILE" ]
grep -Fxq schema=2 "$PROMOTED_IMAGE_FILE"
# Unsafe candidate receipt destinations fail before building or claiming readiness.
rm "$test_root/argv"
mkdir "$BUILD_CANDIDATE_FILE"
if cmd_build_image > "$test_root/log" 2>&1; then exit 1; fi
[ ! -e "$test_root/argv" ]
if grep -q 'candidate verified' "$test_root/log"; then exit 1; fi
rmdir "$BUILD_CANDIDATE_FILE"
ln -s "$test_root/receipt" "$BUILD_CANDIDATE_FILE"
if cmd_build_image > "$test_root/log" 2>&1; then exit 1; fi
[ ! -e "$test_root/argv" ]
rm "$BUILD_CANDIDATE_FILE"
# Unsafe private files and missing/symlinked companions fail before Docker starts.
rm -f "$test_root/argv"
chmod 644 "$KACHE_ENDPOINT_FILE"
if cmd_build_image > "$test_root/log" 2>&1; then exit 1; fi
[ ! -e "$test_root/argv" ]; chmod 600 "$KACHE_ENDPOINT_FILE"
for endpoint in 'https://user:pass@cache.internal/' 'https://cache.internal/?token=secret' 'https://cache.internal/#secret' 'https://cache.internal/%61'; do
  printf '%s\n' "$endpoint" > "$KACHE_ENDPOINT_FILE"
  if cmd_build_image > "$test_root/log" 2>&1; then exit 1; fi
  [ ! -e "$test_root/argv" ]
done
printf 'https://cache.internal/cache\n' > "$KACHE_ENDPOINT_FILE"
mv "$CFGDIR/kache-supervise.sh" "$test_root/companion"
ln -s "$test_root/companion" "$CFGDIR/kache-supervise.sh"
if cmd_build_image >/dev/null 2>&1; then exit 1; fi
[ ! -e "$test_root/argv" ]
rm "$CFGDIR/kache-supervise.sh"; mv "$test_root/companion" "$CFGDIR/kache-supervise.sh"
# Failed builds publish no candidate metadata and retain prior promoted identity.
fail_build=true
if cmd_build_image > "$test_root/log" 2>&1; then exit 1; else [ "$?" = 42 ]; fi
[ ! -e "$BUILD_CANDIDATE_FILE" ]
fail_build=false; collision=true
if cmd_build_image >/dev/null 2>&1; then exit 1; fi
collision=false
# Direct and async entrypoints cannot race promotion or another direct build.
( exec 8> "$RUNDIR/image-candidate.lock"; flock 8
  if cmd_build_image >/dev/null 2>&1; then exit 1; fi
  if cmd_promote_image "$candidate" "$id" >/dev/null 2>&1; then exit 1; fi
)
echo 'image-candidate-safety: PASS'
