<?php
/* CI Runner Farm - backend endpoint for the web UI.
   Guards every action with the Unraid CSRF token, then shells out to
   runner-farm.sh. Token writes go to a chmod-600 file, never ci-runner-farm.cfg. */
header('Content-Type: application/json');

$var = @parse_ini_file('/var/local/emhttp/var.ini');
$csrf = $var['csrf_token'] ?? '';
$given = $_REQUEST['csrf_token'] ?? '';
if (!$csrf || !hash_equals($csrf, $given)) {
  http_response_code(403);
  echo json_encode(['ok' => false, 'error' => 'csrf']);
  exit;
}

$PLUGIN  = 'ci-runner-farm';
$CFGDIR  = "/boot/config/plugins/$PLUGIN";
$SCRIPT  = "/usr/local/emhttp/plugins/$PLUGIN/include/runner-farm.sh";
$action  = $_REQUEST['action'] ?? 'status-json';
$method  = $_SERVER['REQUEST_METHOD'] ?? 'GET';

$readOnlyActions = ['status-json','queued-json','stats-json','cache-usage','image-info',
  'get-default-dockerfile','get-dockerfile','farm-log','build-log','runner-log','validate-pools'];
if ($method !== 'POST' && !in_array($action, $readOnlyActions, true)) {
  http_response_code(405);
  echo json_encode(['ok'=>false,'error'=>'POST required']);
  exit;
}

function run($cmd) { exec($cmd . ' 2>&1', $out, $rc); return [implode("\n", $out), $rc]; }
// For actions whose stdout is a JSON body the frontend parses: keep stderr OUT of
// it, so a stray docker/system warning can't corrupt the JSON (JSON.parse would
// throw and the consumer's .catch would silently freeze the panel). run() keeps
// 2>&1 for the action responses where the merged log IS the payload.
function run_json($cmd) { exec($cmd . ' 2>/dev/null', $out, $rc); return [implode("\n", $out), $rc]; }
// The last non-empty stdout line, if it is a JSON object — lets an emitter print
// progress logs then its {ok,error?} verdict as the final line and have us pass
// that verdict through with its specific reason intact.
function last_json($out) {
  $lines = array_values(array_filter(explode("\n", $out), fn($l) => trim($l) !== ''));
  $last = $lines ? trim(end($lines)) : '';
  return (strlen($last) && $last[0] === '{') ? $last : '';
}
function runner_name_valid($name) {
  return preg_match('/^ci-runner-(?:[0-9]+|[a-z](?:[a-z0-9-]{0,22}[a-z0-9])?-[0-9]+)$/', $name) === 1;
}
function bounded_request_string($value, $max, $trim = false) {
  if (!is_string($value) || strlen($value) > $max || str_contains($value, "\0")) return false;
  return $trim ? trim($value) : $value;
}

switch ($action) {
  case 'status-json':
    [$out, $rc] = run_json(escapeshellarg($SCRIPT) . ' status-json');
    // runner-farm.sh already emits JSON; pass it through verbatim. Empty stdout means
    // the backend script itself failed (missing/non-executable/crash) — not a real
    // empty fleet — so on a non-zero exit surface an HTTP error, which makes crfPost
    // reject and the UI show "lost connection" instead of a misleading "No managed
    // runners" card.
    if      ($out !== '') { echo $out; }
    elseif  ($rc === 0)   { echo json_encode(['count'=>0,'runners'=>[]]); }
    else                  { http_response_code(500); echo json_encode(['ok'=>false,'error'=>'backend unavailable']); }
    break;

  case 'start': case 'stop': case 'restart': case 'validate':
    [$out, $rc] = run(escapeshellarg($SCRIPT) . ' ' . escapeshellarg($action));
    echo json_encode(['ok' => $rc === 0, 'action' => $action, 'log' => $out]);
    break;

  case 'scale':
    $raw = $_REQUEST['n'] ?? '';
    if (!is_string($raw) || !preg_match('/^(?:0|[1-9][0-9]?)$/', $raw) || (int)$raw > 64) {
      http_response_code(400); echo json_encode(['ok'=>false,'error'=>'scale target must be a canonical integer from 0 to 64']); break;
    }
    $pool = $_REQUEST['pool'] ?? '';
    if ($pool !== '' && (!is_string($pool) || !preg_match('/^[a-z](?:[a-z0-9-]{0,22}[a-z0-9])?$/', $pool))) {
      http_response_code(400); echo json_encode(['ok'=>false,'error'=>'bad pool']); break;
    }
    if ($pool !== '' && $raw === '0') {
      http_response_code(400); echo json_encode(['ok'=>false,'error'=>'runner pools cannot scale to zero']); break;
    }
    $cmd = escapeshellarg($SCRIPT) . ' scale ';
    if ($pool !== '') $cmd .= escapeshellarg($pool) . ' ';
    $cmd .= escapeshellarg($raw);
    [$out, $rc] = run($cmd);
    echo json_encode(['ok' => $rc === 0, 'action' => $pool === '' ? "scale $raw" : "scale $pool $raw", 'log' => $out]);
    break;

  case 'validate-pools':
    $mode = $_REQUEST['mode'] ?? 'single';
    $pools = $_REQUEST['pools'] ?? '';
    $scope = $_REQUEST['scope'] ?? 'repo';
    $owner = $_REQUEST['owner'] ?? '';
    if (!is_string($mode) || !in_array($mode, ['single','pools'], true) ||
        !is_string($scope) || !in_array($scope, ['repo','org'], true) ||
        !is_string($pools) || strlen($pools) > 4096 ||
        !is_string($owner) || strlen($owner) > 255) {
      http_response_code(400); echo json_encode(['ok'=>false,'error'=>'invalid pool validation request']); break;
    }
    [$out, $rc] = run_json(escapeshellarg($SCRIPT) . ' validate-pools ' .
      escapeshellarg($mode) . ' ' . escapeshellarg($pools) . ' ' . escapeshellarg($scope) . ' ' .
      escapeshellarg($owner));
    if ($out !== '') echo $out;
    else { http_response_code(400); echo json_encode(['ok'=>false,'error'=>'pool validation failed']); }
    break;

  case 'set-token':
    $tok = bounded_request_string($_REQUEST['token'] ?? '', 255, true);
    if ($tok === false) { http_response_code(400); echo json_encode(['ok'=>false,'error'=>'invalid GitHub token value']); break; }
    if ($tok === '') { echo json_encode(['ok'=>false,'error'=>'empty']); break; }
    // Shape-check the PAT: every GitHub token form (ghp_/gho_/ghs_/ghr_/github_pat_
    // + classic 40-char hex) is [A-Za-z0-9_] only. Rejecting anything else keeps a
    // stray quote/newline/backslash out of the curl `--config` header the engine
    // builds from this value (where it could break or inject curl directives).
    if (!preg_match('/^[A-Za-z0-9_]{20,255}$/', $tok)) {
      echo json_encode(['ok'=>false,'error'=>'that does not look like a GitHub token (expected letters, digits, and underscores only)']); break;
    }
    @mkdir($CFGDIR, 0755, true);
    file_put_contents("$CFGDIR/token", $tok);
    chmod("$CFGDIR/token", 0600);
    echo json_encode(['ok' => true, 'action' => 'set-token']);
    break;

  case 'clear-token':
    @unlink("$CFGDIR/token");
    echo json_encode(['ok' => true, 'action' => 'clear-token']);
    break;

  case 'set-registry-token':
    $tok = bounded_request_string($_REQUEST['token'] ?? '', 4096, true);
    if ($tok === false) { http_response_code(400); echo json_encode(['ok'=>false,'error'=>'registry token is too large or invalid']); break; }
    if ($tok === '') { echo json_encode(['ok'=>false,'error'=>'empty']); break; }
    @mkdir($CFGDIR, 0755, true);
    file_put_contents("$CFGDIR/registry-token", $tok);
    chmod("$CFGDIR/registry-token", 0600);
    echo json_encode(['ok' => true, 'action' => 'set-registry-token']);
    break;

  case 'clear-registry-token':
    @unlink("$CFGDIR/registry-token");
    echo json_encode(['ok' => true, 'action' => 'clear-registry-token']);
    break;

  case 'get-dockerfile':
    $df = "$CFGDIR/Dockerfile";
    if (!is_file($df)) $df = "/usr/local/emhttp/plugins/$PLUGIN/default.Dockerfile";
    echo json_encode(['ok' => true, 'dockerfile' => is_file($df) ? file_get_contents($df) : '']);
    break;

  case 'save-dockerfile':
    $content = bounded_request_string($_REQUEST['dockerfile'] ?? '', 1048576);
    if ($content === false) { http_response_code(400); echo json_encode(['ok'=>false,'error'=>'Dockerfile is too large or invalid']); break; }
    if (trim($content) === '') { echo json_encode(['ok'=>false,'error'=>'empty']); break; }
    @mkdir($CFGDIR, 0755, true);
    file_put_contents("$CFGDIR/Dockerfile", $content);
    echo json_encode(['ok' => true, 'action' => 'save-dockerfile']);
    break;

  case 'build-image':
    // The engine owns the flock/launch state machine (build-async verb); thin shim.
    [$out, $rc] = run_json(escapeshellarg($SCRIPT) . ' build-async');
    echo $out !== '' ? $out : json_encode(['ok'=>false,'error'=>'build launch failed']);
    break;

  case 'queued-json':
    [$out, $rc] = run_json(escapeshellarg($SCRIPT) . ' queued-json');
    echo $out !== '' ? $out : json_encode(['queued' => -1]);
    break;

  case 'stats-json':
    [$out, $rc] = run_json(escapeshellarg($SCRIPT) . ' stats-json');
    echo $out !== '' ? $out : json_encode(['total' => -1]);
    break;

  case 'cache-usage':
    [$out, $rc] = run_json(escapeshellarg($SCRIPT) . ' cache-usage-json');
    echo $out !== '' ? $out : json_encode(['total' => -1]);
    break;

  case 'cache-clear':
    [$out, $rc] = run_json(escapeshellarg($SCRIPT) . ' cache-clear-pkg');
    // cmd_cache_clear_pkg emits its {ok,error?} verdict as the final stdout line;
    // pass it through so a specific reason (unsafe root / could not remove N dirs)
    // reaches the UI, else fall back to the exit-code envelope.
    $j = last_json($out);
    echo $j !== '' ? $j : json_encode(['ok' => $rc === 0, 'action' => 'cache-clear']);
    break;

  case 'recycle':
    $n = $_REQUEST['name'] ?? '';
    if (!is_string($n) || !runner_name_valid($n)) { echo json_encode(['ok'=>false,'error'=>'bad name']); break; }
    [$out, $rc] = run_json(escapeshellarg($SCRIPT) . ' recycle ' . escapeshellarg($n));
    // cmd_recycle emits progress logs then its {ok,error?} verdict as the final
    // stdout line; pass it through so the specific reason (removed-not-recreated,
    // preflight-aborted, no-token …) reaches the UI, else fall back to exit code.
    $j = last_json($out);
    echo $j !== '' ? $j : json_encode(['ok' => $rc === 0, 'action' => 'recycle']);
    break;

  case 'runner-log':
    $n = $_REQUEST['name'] ?? '';
    if (!is_string($n) || !runner_name_valid($n)) { echo json_encode(['ok'=>false,'error'=>'bad name']); break; }
    [$out, $rc] = run(escapeshellarg($SCRIPT) . ' logs-tail ' . escapeshellarg($n) . ' 150');
    echo json_encode(['ok' => true, 'log' => $out]);
    break;

  case 'image-info':
    [$out, $rc] = run_json(escapeshellarg($SCRIPT) . ' image-info-json');
    echo $out !== '' ? $out : json_encode(['exists' => false]);
    break;

  case 'get-default-dockerfile':
    $df = "/usr/local/emhttp/plugins/$PLUGIN/default.Dockerfile";
    echo json_encode(['ok' => true, 'dockerfile' => is_file($df) ? file_get_contents($df) : '']);
    break;

  case 'farm-log':
    // engine owns the source selection + filtering (farm-log verb); thin shim.
    [$out, $rc] = run_json(escapeshellarg($SCRIPT) . ' farm-log');
    echo $out !== '' ? $out : json_encode(['ok'=>true,'log'=>'']);
    break;

  case 'build-log':
    // engine owns the liveness/rc/log parsing (build-status verb); thin shim.
    [$out, $rc] = run_json(escapeshellarg($SCRIPT) . ' build-status');
    echo $out !== '' ? $out : json_encode(['ok'=>true,'running'=>false,'rc'=>null,'log'=>'']);
    break;

  default:
    http_response_code(400);
    echo json_encode(['ok' => false, 'error' => 'unknown action']);
}
