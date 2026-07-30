#!/usr/bin/env bash
# Security contracts for web action validation.
set -euo pipefail
cd "$(dirname "$0")/.."
EXEC="src/usr/local/emhttp/plugins/ci-runner-farm/include/exec.php"
CORE="src/usr/local/emhttp/plugins/ci-runner-farm/include/crf-core.php"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
need() { grep -Fq -- "$1" "$EXEC" || fail "exec.php lacks: $1"; }

need "'POST required'"
need "preg_match('/^(?:0|[1-9][0-9]?)$/'"
need '(int)$raw > 64'
need "case 'validate-pools':"
need 'strlen($pools) > 4096'
need 'runner_name_valid($n)'
need "http_response_code(405)"
need "http_response_code(400)"
need "escapeshellarg(\$pool)"
need "escapeshellarg(\$raw)"
need "'runner pools cannot scale to zero'"
need "escapeshellarg(\$owner)"
need 'bounded_request_string($_REQUEST['
grep -Fq 'json_encode($crf_csrf' "$CORE" || fail 'CSRF token is interpolated into JavaScript without JSON encoding'

# The old coercion turned arbitrary junk into destructive scale-to-zero.
if grep -Fq '(int)($_REQUEST[' "$EXEC"; then fail 'raw request values are still coerced directly to integers'; fi

# Execute the actual request-string validator extracted from exec.php. Array
# payloads must be rejected before trim/strlen, avoiding an uncontrolled PHP 8
# TypeError for token[]=x or dockerfile[]=x requests.
php -r '
  $src = file_get_contents($argv[1]);
  if (!preg_match("/function bounded_request_string\\([^}]+\\}/s", $src, $m)) exit(2);
  eval($m[0]);
  if (bounded_request_string(["x"], 4096, true) !== false) exit(3);
  if (bounded_request_string(["FROM scratch"], 1048576) !== false) exit(4);
  if (bounded_request_string(" value ", 4096, true) !== "value") exit(5);
' "$EXEC" || fail 'bounded request-string validator failed array-payload execution test'

echo 'php-actions: OK'
