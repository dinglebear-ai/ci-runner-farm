#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
. tests/lib/assert.sh
ENGINE=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
tmp="$(mktemp -d)"
TEST_ROOT="$tmp"
trap 'rm -rf "$TEST_ROOT"' EXIT

awk '
  /^build_candidate_tag_valid\(\)/ {copy=1}
  /^# Called from the plugin install step/ {copy=0}
  copy {print}
' "$ENGINE" > "$tmp/functions.sh"
# shellcheck disable=SC1091
. "$tmp/functions.sh"

CFGDIR="$tmp/cfg"
RUNDIR="$tmp/run"
mkdir -p "$CFGDIR" "$RUNDIR" "$tmp/images"
BUILD_CANDIDATE_FILE="$CFGDIR/build-candidate.state"
PROMOTED_IMAGE_FILE="$CFGDIR/promoted-image.state"
BUILTIN_IMAGE='ci-runner-farm-runner:latest'
log() { printf '%s\n' "$*" >> "$TEST_ROOT/log"; }
err() { printf '%s\n' "$*" >> "$TEST_ROOT/error"; }
json_escape() { sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
resource_uint_valid() { [[ "${1:-}" =~ ^(0|[1-9][0-9]*)$ ]] && [ "$1" -le "${2:-9000000000000000000}" ]; }
resource_positive_uint_valid() { resource_uint_valid "${1:-}" "${2:-9000000000000000000}" && [ "$1" != 0 ]; }
image_path() { printf '%s/images/%s\n' "$TEST_ROOT" "$(printf '%s' "$1" | sha256sum | awk '{print $1}')"; }
mkdir -p "$tmp/bin"
cat > "$tmp/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -u
root="${CRF_IMAGE_TEST_DIR:?}"
image_path() { printf '%s/images/%s\n' "$root" "$(printf '%s' "$1" | sha256sum | awk '{print $1}')"; }
printf '%q ' "$@" >> "$root/docker.calls"; printf '\n' >> "$root/docker.calls"
case "${1:-}" in
  build)
    [ "${2:-}" = -t ] || exit 1
    printf 'sha256:%064d\n' 0 | tr '0' 'a' > "$(image_path "$3")"
    ;;
  image)
    [ "${2:-}" = inspect ] || exit 1
    path="$(image_path "$3")"; [ -f "$path" ] || exit 1
    [ "${4:-}" != --format ] || cat "$path"
    ;;
  tag)
    cp "$(image_path "$2")" "$(image_path "$3")"
    ;;
  *) exit 1 ;;
esac
DOCKER
chmod +x "$tmp/bin/docker"
export CRF_IMAGE_TEST_DIR="$TEST_ROOT"
PATH="$tmp/bin:$PATH"

snapshot="$RUNDIR/build.Dockerfile.test"
printf 'FROM scratch\nLABEL test=immutable-candidate\n' > "$snapshot"
chmod 0600 "$snapshot"
build_rc=0
cmd_build_image "$snapshot" || build_rc=$?
crf_assert_eq 0 "$build_rc" "candidate build result"

[ ! -e "$(image_path "$BUILTIN_IMAGE")" ] || crf_fail "build overwrote the production image tag"
! grep -Fq "build -t $BUILTIN_IMAGE" "$TEST_ROOT/docker.calls" || crf_fail "build targeted production latest"
build_candidate_state_load || crf_fail "verified candidate metadata was not written"
build_candidate_tag_valid "$BUILD_CANDIDATE_TAG" || crf_fail "candidate tag is not immutable-shaped"
crf_assert_eq "$(sha256sum "$snapshot" | awk '{print $1}')" "$BUILD_CANDIDATE_DOCKERFILE_SHA" "candidate Dockerfile identity"
crf_assert_file_mode "$BUILD_CANDIDATE_FILE" 600

wrong="sha256:$(printf 'b%.0s' {1..64})"
if cmd_promote_image "$BUILD_CANDIDATE_TAG" "$wrong" >/dev/null 2>&1; then
  crf_fail "promotion accepted the wrong expected image id"
fi
[ ! -e "$(image_path "$BUILTIN_IMAGE")" ] || crf_fail "failed promotion changed production tag"

candidate_tag="$BUILD_CANDIDATE_TAG"
candidate_image_id="$BUILD_CANDIDATE_IMAGE_ID"
promoted="$(cmd_promote_image "$candidate_tag" "$candidate_image_id")"
grep -Fq '"ok":true' <<<"$promoted" || crf_fail "verified promotion did not report success"
crf_assert_eq "$candidate_image_id" "$(cat "$(image_path "$BUILTIN_IMAGE")")" "production image identity"
crf_assert_file_mode "$PROMOTED_IMAGE_FILE" 600
[ ! -e "$BUILD_CANDIDATE_FILE" ] || crf_fail "successful promotion left candidate metadata reusable"

printf '%s\n' "$wrong" > "$(image_path "$candidate_tag")"
if cmd_promote_image "$candidate_tag" "$candidate_image_id" >/dev/null 2>&1; then
  crf_fail "promotion reused retired candidate metadata"
fi
crf_assert_eq "$candidate_image_id" "$(cat "$(image_path "$BUILTIN_IMAGE")")" "production tag after replay refusal"

echo 'image-promotion: OK'
