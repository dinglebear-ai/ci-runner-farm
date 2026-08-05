#!/usr/bin/env bash
# Security contracts for web action validation.
# The quoted PHP/source fragments below are intentionally literal.
# shellcheck disable=SC2016
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
need 'post_scalar('\''pools'\'', 16384)'
need "post_scalar('backend', 16, true)"
need "post_scalar('runner_cpus', 32, true)"
need "post_scalar('runner_memory', 32, true)"
need 'runner_name_valid($n)'
need "http_response_code(405)"
need "http_response_code(400)"
need "escapeshellarg(\$pool)"
need "escapeshellarg(\$raw)"
need "'runner pools cannot scale to zero'"
need "escapeshellarg(\$owner)"
need "escapeshellarg(\$backend)"
need "escapeshellarg(\$runnerCpus)"
need "escapeshellarg(\$runnerMemory)"
need 'bounded_request_string(post_scalar('
need "case 'apply-config':"
need "expected_config_revision"
need "settings snapshot contains no allowed fields or includes an unknown field"
need "tempnam(\$CFGDIR, '.apply.')"
need "function_exists('fsync')"
need 'function github_pat_validate($token)'
need 'CURLOPT_CONNECTTIMEOUT_MS => 3000'
need 'CURLOPT_TIMEOUT_MS => 8000'
need 'CURLOPT_MAXFILESIZE => 65536'
need 'CURLOPT_WRITEFUNCTION => function($handle, $chunk)'
need 'github_pat_body_append($body, $tooLarge, $chunk)'
need 'write_private_atomic("$CFGDIR/token", $tok)'
need "'dockerfile_sha' => \$dockerfileSha"
need "post_scalar('dockerfile_sha', 64, true, true)"
need "build-async ' . escapeshellarg(\$dockerfileSha)"
need '$_POST[$key]'
if grep -Fq '$_REQUEST' "$EXEC"; then fail 'exec.php still reads the mixed GET/POST request bag'; fi
grep -Fq 'json_encode($crf_csrf' "$CORE" || fail 'CSRF token is interpolated into JavaScript without JSON encoding'

# Unraid's global local_prepend.php validates csrf_token and then unsets it from
# $_POST before the plugin endpoint begins. The endpoint must recognize that
# completed gate and continue to its own action validation.
reply="$(php -d auto_prepend_file=tests/fixtures/unraid-csrf-prepend.php "$EXEC")"
[ "$reply" = '{"ok":false,"error":"unknown action"}' ] ||
  fail "endpoint rejected Unraid's already-validated POST: $reply"

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

# Exercise the pure interpretation of GitHub's live validation response without
# sending a credential or depending on the network in this test.
php -r '
  $src=file_get_contents($argv[1]);
  if (!preg_match("/function github_pat_validation_result.*?(?=\\nfunction github_pat_validate)/s",$src,$m)) exit(2);
  eval($m[0]);
  $ok=github_pat_validation_result(200,"{\"login\":\"octocat\",\"id\":1}",0);
  if (!($ok["ok"]??false) || ($ok["login"]??"")!=="octocat") exit(3);
  $bad=github_pat_validation_result(401,"{}",0);
  if (($bad["code"]??"")!=="invalid_github_token" || !str_contains($bad["error"]??"","existing token was kept")) exit(4);
  $offline=github_pat_validation_result(0,false,28);
  if (($offline["code"]??"")!=="github_unreachable") exit(5);
' "$EXEC" || fail 'GitHub PAT validation response handling failed'

# Content-Length is optional and compressed/chunked bodies can expand beyond
# CURLOPT_MAXFILESIZE. Exercise the actual write callback helper to prove the
# retained body aborts at 64 KiB without appending the overflowing chunk.
php -r '
  $src=file_get_contents($argv[1]);
  if (!preg_match("/function github_pat_body_append.*?(?=\\nfunction github_pat_validation_result)/s",$src,$m)) exit(2);
  eval($m[0]);
  $body="";$tooLarge=false;
  if (github_pat_body_append($body,$tooLarge,str_repeat("a",65535))!==65535) exit(3);
  if (github_pat_body_append($body,$tooLarge,"b")!==1 || strlen($body)!==65536 || $tooLarge) exit(4);
  if (github_pat_body_append($body,$tooLarge,"c")!==0 || !$tooLarge || strlen($body)!==65536) exit(5);
' "$EXEC" || fail 'GitHub PAT validation response body is not hard-capped at 64 KiB'

echo 'php-actions: OK'
