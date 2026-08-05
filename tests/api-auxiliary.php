<?php
declare(strict_types=1);

$root = dirname(__DIR__);
$cli = $root . '/src/usr/local/emhttp/plugins/ci-runner-farm/include/api-auxiliary.php';
$tmp = sys_get_temp_dir() . '/crf-api-aux-' . bin2hex(random_bytes(6));
if (!mkdir($tmp, 0700, true) && !is_dir($tmp)) throw new RuntimeException('could not create temp directory');

function remove_tree(string $path): void {
    if (is_link($path) || is_file($path)) { @unlink($path); return; }
    if (!is_dir($path)) return;
    foreach (array_diff(scandir($path) ?: [], ['.', '..']) as $name) remove_tree($path . '/' . $name);
    @rmdir($path);
}
register_shutdown_function(static fn() => remove_tree($GLOBALS['tmp']));

function must(bool $condition, string $message): void {
    if (!$condition) throw new RuntimeException($message);
}

function write_raw(string $name, string $content, int $mode = 0600): string {
    $path = $GLOBALS['tmp'] . '/' . $name;
    file_put_contents($path, $content);
    chmod($path, $mode);
    return $path;
}

function write_json(string $name, mixed $value, int $mode = 0600): string {
    return write_raw($name, json_encode($value, JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES), $mode);
}

function run_aux(string $mode, string $path): array {
    $pipes = [];
    $process = proc_open(
        [PHP_BINARY, $GLOBALS['cli'], $mode, $path],
        [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']],
        $pipes
    );
    must(is_resource($process), 'could not launch api-auxiliary.php');
    fclose($pipes[0]);
    $stdout = stream_get_contents($pipes[1]);
    $stderr = stream_get_contents($pipes[2]);
    fclose($pipes[1]);
    fclose($pipes[2]);
    return [proc_close($process), $stdout, $stderr];
}

function expect_failure(string $label, string $mode, string $path, int $exitCode = 5): void {
    [$rc, $stdout] = run_aux($mode, $path);
    must($rc === $exitCode, $label . ' exited ' . $rc . ' instead of ' . $exitCode);
    must($stdout === '', $label . ' wrote to stdout');
}

$queue = [
    'queued' => 1,
    'known_queued' => 1,
    'workflow_runs' => 1,
    'partial' => false,
    'truncated' => false,
    'detail_complete' => true,
    'jobs' => [[
        'run_id' => '9007199254740993',
        'job_id' => '9007199254740995',
        'repo' => 'owner/repo',
        'workflow' => '#42 · Build',
        'labels' => 'self-hosted, rust, linux',
        'pool' => 'rust',
        'reason' => 'waiting for runner',
        'created_at' => '2026-08-05T18:00:00Z',
        'url' => 'https://github.example/jobs/1',
    ]],
    'age' => 12,
];
[$rc, $stdout, $stderr] = run_aux('queue', write_json('queue.json', $queue));
must($rc === 0 && $stderr === '', 'valid queue failed: ' . $stderr);
$strictQueue = json_decode($stdout, true, 64, JSON_THROW_ON_ERROR);
must($strictQueue['jobs'][0]['run_id'] === '9007199254740993', 'queue run ID was truncated');
must($strictQueue['jobs'][0]['job_id'] === '9007199254740995', 'queue job ID was truncated');
must($strictQueue['detail_complete'] === true && $strictQueue['queued'] === 1, 'queue completeness changed');

$numericQueue = $queue;
$numericQueue['jobs'][0]['run_id'] = 42;
$numericQueue['jobs'][0]['job_id'] = 43;
[$rc, $stdout] = run_aux('queue', write_json('queue-numeric.json', $numericQueue));
$strictNumericQueue = json_decode($stdout, true, 64, JSON_THROW_ON_ERROR);
must($rc === 0 && $strictNumericQueue['jobs'][0]['run_id'] === '42' && $strictNumericQueue['jobs'][0]['job_id'] === '43', 'numeric queue IDs were not stringified');

$unavailableQueue = [
    'queued' => -1,
    'known_queued' => 0,
    'workflow_runs' => -1,
    'partial' => false,
    'truncated' => false,
    'detail_complete' => false,
    'jobs' => [],
    'age' => 999999,
];
[$rc, $stdout] = run_aux('queue', write_json('queue-unavailable.json', $unavailableQueue));
$strictUnavailableQueue = json_decode($stdout, true, 64, JSON_THROW_ON_ERROR);
must($rc === 0 && $strictUnavailableQueue['queued'] === -1 && $strictUnavailableQueue['workflow_runs'] === -1, 'queue unavailable sentinels changed');

$zeroIdQueue = $queue;
$zeroIdQueue['jobs'][0]['run_id'] = '0';
expect_failure('zero queue run ID', 'queue', write_json('queue-zero-id.json', $zeroIdQueue));

$inconsistentQueue = $queue;
$inconsistentQueue['partial'] = true;
expect_failure('inconsistent complete queue', 'queue', write_json('queue-inconsistent.json', $inconsistentQueue));

$unknownQueueField = $queue;
$unknownQueueField['extra'] = true;
expect_failure('unknown queue field', 'queue', write_json('queue-extra.json', $unknownQueueField));

$controlQueue = $queue;
$controlQueue['jobs'][0]['workflow'] = "bad
workflow";
expect_failure('queue control character', 'queue', write_json('queue-control.json', $controlQueue));

$statistics = ['ok' => 7, 'fail' => 2, 'cancel' => 1, 'other' => 0, 'total' => 10, 'age' => 15];
[$rc, $stdout] = run_aux('statistics', write_json('statistics.json', $statistics));
$strictStatistics = json_decode($stdout, true, 64, JSON_THROW_ON_ERROR);
must($rc === 0 && $strictStatistics['total'] === 10, 'valid statistics failed');

$unavailableStatistics = ['ok' => 0, 'fail' => 0, 'cancel' => 0, 'other' => 0, 'total' => -1, 'age' => 999999];
[$rc, $stdout] = run_aux('statistics', write_json('statistics-unavailable.json', $unavailableStatistics));
$strictUnavailableStatistics = json_decode($stdout, true, 64, JSON_THROW_ON_ERROR);
must($rc === 0 && $strictUnavailableStatistics['total'] === -1, 'statistics unavailable sentinel changed');

$badStatistics = $statistics;
$badStatistics['total'] = 11;
expect_failure('inconsistent statistics total', 'statistics', write_json('statistics-bad-total.json', $badStatistics));

$cache = ['total' => 1099511627776, 'pkg' => 536870912, 'age' => 9];
[$rc, $stdout] = run_aux('cache', write_json('cache.json', $cache));
$strictCache = json_decode($stdout, true, 64, JSON_THROW_ON_ERROR);
must($rc === 0 && $strictCache['total'] === '1099511627776' && $strictCache['pkg'] === '536870912', 'cache bytes were not stringified exactly');

$unavailableCache = ['total' => -1, 'pkg' => 0, 'age' => 999999];
[$rc, $stdout] = run_aux('cache', write_json('cache-unavailable.json', $unavailableCache));
$strictUnavailableCache = json_decode($stdout, true, 64, JSON_THROW_ON_ERROR);
must($rc === 0 && $strictUnavailableCache['total'] === -1, 'cache unavailable sentinel changed');

$badCache = $cache;
$badCache['pkg'] = -1;
expect_failure('negative package cache', 'cache', write_json('cache-negative.json', $badCache));

$image = [
    'exists' => true,
    'image' => 'ci-runner-farm-runner:latest',
    'source' => 'builtin',
    'id' => '0123456789ab',
    'image_id' => 'sha256:' . str_repeat('a', 64),
    'created' => '2026-08-05T17:00:00Z',
    'size_mb' => 3072,
    'size_bytes' => 3221225472,
    'base' => 'ubuntu:24.04',
    'in_use' => 3,
    'dockerfile' => '/boot/config/plugins/ci-runner-farm/Dockerfile',
];
[$rc, $stdout, $stderr] = run_aux('image', write_json('image.json', $image));
must($rc === 0 && $stderr === '', 'valid image failed: ' . $stderr);
$strictImage = json_decode($stdout, true, 64, JSON_THROW_ON_ERROR);
must($strictImage['image_id'] === 'sha256:' . str_repeat('a', 64), 'full image ID changed');
must($strictImage['size_bytes'] === '3221225472', 'exact image bytes were not stringified');
must(!array_key_exists('id', $strictImage) && !array_key_exists('size_mb', $strictImage), 'coarse image fields leaked into strict result');

$missingImage = ['exists' => false, 'image' => 'missing:latest', 'source' => 'remote'];
[$rc, $stdout] = run_aux('image', write_json('image-missing.json', $missingImage));
$strictMissingImage = json_decode($stdout, true, 64, JSON_THROW_ON_ERROR);
must($rc === 0 && $strictMissingImage['exists'] === false && $strictMissingImage['image_id'] === null && $strictMissingImage['size_bytes'] === null && $strictMissingImage['in_use'] === 0, 'missing image defaults changed');

$badImage = $image;
$badImage['image_id'] = 'sha256:short';
expect_failure('short image ID', 'image', write_json('image-short-id.json', $badImage));

$overImage = $image;
$overImage['size_bytes'] = '1099511627777';
expect_failure('over-bound image size', 'image', write_json('image-too-large.json', $overImage));

expect_failure('unsafe auxiliary mode', 'queue', write_json('queue-mode.json', $queue, 0644));
expect_failure('malformed auxiliary JSON', 'queue', write_raw('malformed.json', '{'));
expect_failure('oversized auxiliary JSON', 'queue', write_raw('oversized.json', str_repeat(' ', 1048577)), 7);
expect_failure('unknown auxiliary mode', 'unknown', write_json('unknown-mode.json', $queue));

printf("api-auxiliary: OK
");
