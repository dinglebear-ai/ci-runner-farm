#!/usr/bin/env bash
# Queue refresh must recognize configured routing labels without GitHub's legacy
# self-hosted label and sample queued runs fairly across configured repositories.
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib/assert.sh

engine=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

sed -n '/^cmd_queued_refresh()/,/^}/p' "$engine" > "$tmp/queue-function.sh"
# shellcheck disable=SC1090
. "$tmp/queue-function.sh"

RUNDIR="$tmp/runtime"
mkdir -p "$RUNDIR"
GH_REPOS='acme/one acme/two'
ACCESS_TOKEN=test-token
RUNNER_LABELS='self-hosted,default'

# The unit fixture replaces every external GitHub interaction. The production
# function still exercises its manifest selection, pool mapping, job filtering,
# snapshot completeness, permissions, and atomic publish path.
github_api_token_load(){ return 0; }
gh_fetch_all(){
  local outdir="$2"
  cat > "$outdir/1" <<'JSON'
{"total_count":2,"workflow_runs":[
  {"id":101,"run_number":11,"name":"One first","created_at":"2026-08-05T20:00:00Z"},
  {"id":102,"run_number":12,"name":"One second","created_at":"2026-08-05T20:01:00Z"}
]}
JSON
  cat > "$outdir/2" <<'JSON'
{"total_count":1,"workflow_runs":[
  {"id":201,"run_number":21,"name":"Two first","created_at":"2026-08-05T20:02:00Z"}
]}
JSON
}
pool_mode_enabled(){ return 0; }
pool_records(){ printf 'rust|fixture
system|fixture
'; }
pool_routing_label(){
  case "$1" in
    rust) printf 'ci-pool-rust
' ;;
    system) printf 'ci-pool-system
' ;;
    *) return 1 ;;
  esac
}
curl(){
  local url='' arg
  while [ "$#" -gt 0 ]; do arg="$1"; shift; case "$arg" in https://*) url="$arg" ;; esac; done
  while IFS= read -r _; do :; done
  case "$url" in
    */actions/runs/101/jobs*) cat <<'JSON'
{"jobs":[
  {"id":1001,"name":"rust-a","status":"queued","labels":["ci-pool-rust"],"created_at":"2026-08-05T20:00:00Z"},
  {"id":1002,"name":"done","status":"completed","labels":["ci-pool-rust"]}
]}
JSON
      ;;
    */actions/runs/102/jobs*) cat <<'JSON'
{"jobs":[{"id":1003,"name":"rust-b","status":"queued","labels":["ci-pool-rust"],"created_at":"2026-08-05T20:01:00Z"}]}
JSON
      ;;
    */actions/runs/201/jobs*) cat <<'JSON'
{"jobs":[{"id":2001,"name":"system-a","status":"queued","labels":["ci-pool-system"],"created_at":"2026-08-05T20:02:00Z"}]}
JSON
      ;;
    *) printf '{"jobs":[]}
' ;;
  esac
}

cmd_queued_refresh
snapshot="$RUNDIR/queued.snapshot.json"
[ -f "$snapshot" ] || crf_fail 'queue refresh did not publish a snapshot'
crf_assert_file_mode "$snapshot" 600

php -r '
  $d=json_decode((string)file_get_contents($argv[1]),true);
  if (!is_array($d)) { fwrite(STDERR,"snapshot is not JSON
"); exit(1); }
  if (($d["queued"]??null)!==3 || ($d["known_queued"]??null)!==3) exit(2);
  if (($d["workflow_runs"]??null)!==3 || !empty($d["partial"]) || !empty($d["truncated"]) || empty($d["detail_complete"])) exit(3);
  $ids=array_map(fn($job)=>(int)($job["run_id"]??0),$d["jobs"]??[]);
  if ($ids!==[101,201,102]) exit(4);
  $pools=array_map(fn($job)=>(string)($job["pool"]??""),$d["jobs"]??[]);
  if ($pools!==["rust","system","rust"]) exit(5);
  foreach ($d["jobs"] as $job) if (str_contains((string)($job["labels"]??""),"self-hosted")) exit(6);
' "$snapshot" || crf_fail 'queue snapshot rejected custom-only routing labels or lost fair repo sampling'

echo 'queue-refresh: OK'
