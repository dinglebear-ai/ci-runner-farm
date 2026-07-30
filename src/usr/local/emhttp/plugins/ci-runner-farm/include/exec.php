<?php
/* CI Runner Farm - backend endpoint for the web UI.
   Guards every action with the Unraid CSRF token, then shells out to
   runner-farm.sh. Token writes go to a chmod-600 file, never ci-runner-farm.cfg. */
header('Content-Type: application/json');

$method = $_SERVER['REQUEST_METHOD'] ?? '';
if ($method !== 'POST') {
  http_response_code(405);
  echo json_encode(['ok'=>false,'error'=>'POST required']);
  exit;
}

function post_scalar($key, $max, $required = false, $trim = false) {
  if (!array_key_exists($key, $_POST)) return $required ? false : '';
  $value = $_POST[$key];
  if (!is_string($value) || strlen($value) > $max || str_contains($value, "\0")) return false;
  return $trim ? trim($value) : $value;
}

$var = @parse_ini_file('/var/local/emhttp/var.ini');
$csrf = $var['csrf_token'] ?? '';
$given = post_scalar('csrf_token', 256, true);
if ($given === false) {
  http_response_code(400);
  echo json_encode(['ok' => false, 'error' => 'invalid csrf token']);
  exit;
}
if (!$csrf || !hash_equals($csrf, $given)) {
  http_response_code(403);
  echo json_encode(['ok' => false, 'error' => 'csrf']);
  exit;
}

$PLUGIN  = 'ci-runner-farm';
$CFGDIR  = "/boot/config/plugins/$PLUGIN";
$SCRIPT  = "/usr/local/emhttp/plugins/$PLUGIN/include/runner-farm.sh";
$action = post_scalar('action', 64, true, true);
if ($action === false || !preg_match('/^[a-z][a-z0-9-]{0,63}$/', $action)) {
  http_response_code(400);
  echo json_encode(['ok'=>false,'error'=>'invalid action']);
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
function config_keys() {
  return [
    'GH_SCOPE','GH_OWNER','GH_REPOS','RUNNER_GROUP','RUNNER_COUNT','RUNNER_LABELS',
    'RUNNER_MODE','RUNNER_POOLS','POOL_BACKEND','RUNNER_CPUS','RUNNER_MEMORY',
    'CACHE_ROOT','WORK_TMPFS_SIZE','IMAGE_SOURCE','IMAGE','EPHEMERAL',
    'RESOURCE_CPU_BUDGET','RESOURCE_MEMORY_BUDGET','RESOURCE_CPU_RESERVE',
    'RESOURCE_MEMORY_RESERVE','RESOURCE_CPU_OVERCOMMIT','RESOURCE_MEMORY_SWAP',
    'RESOURCE_PIDS_LIMIT','RUN_AS_ROOT','REGISTRY_SERVER','REGISTRY_USERNAME',
    'CACHE_MOUNTS','SHARE_DOCKER_SOCK','DIND','SHARED_IMAGE_CACHE',
    'NETWORK_ISOLATION','RUNNER_NETWORK','MIRROR_PORT','AUTOSCALE','AUTOSCALE_MIN',
    'AUTOSCALE_MAX','AUTOSCALE_MIN_IDLE','AUTOSCALE_STEP','AUTOSCALE_INTERVAL',
    'AUTOSCALE_IDLE_GRACE','IMAGE_AUTOUPDATE','IMAGE_AUTOUPDATE_INTERVAL',
    'IMAGE_DRAIN_TIMEOUT','DASHBOARD_WIDGET_ENABLE'
  ];
}
function emit_error($status, $code, $message) {
  http_response_code($status);
  echo json_encode(['ok'=>false,'code'=>$code,'error'=>$message]);
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

  case 'begin-migration': case 'rollback-backend':
    $config = post_scalar('expected_config_revision', 64, true, true);
    $ownership = post_scalar('expected_ownership_revision', 64, true, true);
    $compatibility = post_scalar('expected_compatibility_record_id', 64, true, true);
    $transition = post_scalar('expected_transition_revision', 64, true, true);
    foreach ([$config,$ownership,$compatibility,$transition] as $revision) {
      if (!is_string($revision) || !preg_match('/^[0-9a-f]{64}$/', $revision)) {
        emit_error(400, 'invalid_revision', 'migration requires four exact revisions');
        break 2;
      }
    }
    [$out, $rc] = run_json(escapeshellarg($SCRIPT) . ' ' . escapeshellarg($action) . ' ' .
      escapeshellarg($config) . ' ' . escapeshellarg($ownership) . ' ' .
      escapeshellarg($compatibility) . ' ' . escapeshellarg($transition));
    if ($rc !== 0) http_response_code($rc === 3 ? 409 : 400);
    echo json_encode(['ok'=>$rc === 0,'action'=>$action,'log'=>$out]);
    break;

  case 'scale':
    $raw = post_scalar('n', 2, true);
    if (!is_string($raw) || !preg_match('/^(?:0|[1-9][0-9]?)$/', $raw) || (int)$raw > 64) {
      http_response_code(400); echo json_encode(['ok'=>false,'error'=>'scale target must be a canonical integer from 0 to 64']); break;
    }
    $pool = post_scalar('pool', 24);
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
    $mode = post_scalar('mode', 8, true);
    $pools = post_scalar('pools', 16384);
    $scope = post_scalar('scope', 4, true);
    $owner = post_scalar('owner', 255);
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

  case 'apply-config':
    $expected = post_scalar('expected_config_revision', 64, true, true);
    $snapshotJson = post_scalar('settings', 65536, true);
    if ($expected === false || !preg_match('/^[0-9a-f]{64}$/', $expected)) {
      emit_error(400, 'invalid_revision', 'invalid expected config revision');
      break;
    }
    if ($snapshotJson === false) {
      emit_error(400, 'invalid_snapshot', 'settings snapshot is missing or too large');
      break;
    }
    $snapshot = json_decode($snapshotJson, true);
    if (!is_array($snapshot) || array_is_list($snapshot)) {
      emit_error(400, 'invalid_snapshot', 'settings must be a JSON object');
      break;
    }
    $keys = config_keys();
    $expectedKeys = array_fill_keys($keys, true);
    if (count($snapshot) !== count($keys) || array_diff_key($snapshot, $expectedKeys) ||
        array_diff_key($expectedKeys, $snapshot)) {
      emit_error(400, 'invalid_snapshot', 'settings snapshot does not match the server allowlist');
      break;
    }
    $lines = [];
    $invalidKey = '';
    foreach ($keys as $key) {
      $value = $snapshot[$key];
      $limit = $key === 'RUNNER_POOLS' ? 16384 : ($key === 'CACHE_MOUNTS' ? 16384 : 4096);
      if (!is_string($value) || strlen($value) > $limit ||
          preg_match('/[\x00\r\n"\\\\]/', $value)) {
        $invalidKey = $key;
        break;
      }
      $lines[] = $key . '="' . $value . '"';
    }
    if ($invalidKey !== '') {
      emit_error(400, 'invalid_field', "invalid value for $invalidKey");
      break;
    }
    @mkdir($CFGDIR, 0755, true);
    $staged = tempnam($CFGDIR, '.apply.');
    if ($staged === false) {
      emit_error(500, 'stage_failed', 'could not create a same-directory staging file');
      break;
    }
    $handle = @fopen($staged, 'wb');
    $body = implode("\n", $lines) . "\n";
    $written = false;
    if ($handle !== false && chmod($staged, 0600)) {
      $written = fwrite($handle, $body);
      if ($written === strlen($body) && fflush($handle)) {
        if (function_exists('fsync')) $written = fsync($handle) ? $written : false;
      } else {
        $written = false;
      }
      fclose($handle);
    } elseif ($handle !== false) {
      fclose($handle);
    }
    if ($written === false) {
      @unlink($staged);
      emit_error(500, 'stage_failed', 'could not durably stage configuration');
      break;
    }
    [$out, $rc] = run_json(escapeshellarg($SCRIPT) . ' apply-config ' .
      escapeshellarg($expected) . ' ' . escapeshellarg($staged));
    @unlink($staged);
    $reply = last_json($out);
    if ($reply === '') {
      emit_error(500, 'backend_failed', 'configuration backend returned no result');
      break;
    }
    $decoded = json_decode($reply, true);
    if ($rc !== 0) {
      http_response_code(($decoded['code'] ?? '') === 'stale_config' ? 409 : 400);
    }
    echo $reply;
    break;

  case 'set-token':
    $tok = bounded_request_string(post_scalar('token', 255, true), 255, true);
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
    $tok = bounded_request_string(post_scalar('token', 4096, true), 4096, true);
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
    $content = bounded_request_string(post_scalar('dockerfile', 1048576, true), 1048576);
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
    $n = post_scalar('name', 64, true);
    if (!is_string($n) || !runner_name_valid($n)) { echo json_encode(['ok'=>false,'error'=>'bad name']); break; }
    [$out, $rc] = run_json(escapeshellarg($SCRIPT) . ' recycle ' . escapeshellarg($n));
    // cmd_recycle emits progress logs then its {ok,error?} verdict as the final
    // stdout line; pass it through so the specific reason (removed-not-recreated,
    // preflight-aborted, no-token …) reaches the UI, else fall back to exit code.
    $j = last_json($out);
    echo $j !== '' ? $j : json_encode(['ok' => $rc === 0, 'action' => 'recycle']);
    break;

  case 'runner-log':
    $n = post_scalar('name', 64, true);
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
