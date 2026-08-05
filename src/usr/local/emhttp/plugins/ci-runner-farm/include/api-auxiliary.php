<?php
declare(strict_types=1);

const RUNNER_API_AUX_MAX_BYTES = 1048576;
const RUNNER_API_QUEUE_MAX_JOBS = 40;

function aux_fail(string $message, int $exitCode = 5): never {
    fwrite(STDERR, $message . PHP_EOL);
    exit($exitCode);
}

function aux_safe_string(mixed $value, string $name, int $maximum): string {
    if (!is_string($value) || strlen($value) > $maximum) aux_fail($name . ' is invalid');
    for ($i = 0, $length = strlen($value); $i < $length; ++$i) {
        $ord = ord($value[$i]);
        if ($ord < 32 || $ord === 127) aux_fail($name . ' contains control characters');
    }
    return $value;
}

function aux_int(mixed $value, string $name, int $minimum, int $maximum): int {
    if (!is_int($value) || $value < $minimum || $value > $maximum) aux_fail($name . ' is outside supported bounds');
    return $value;
}

function aux_decimal_string(mixed $value, string $name): string {
    if (is_int($value) && $value >= 0) return (string)$value;
    if (is_string($value) && preg_match('/^(0|[1-9][0-9]*)$/', $value)) return $value;
    aux_fail($name . ' must be a canonical non-negative integer');
}

function aux_positive_decimal_string(mixed $value, string $name): string {
    $normalized = aux_decimal_string($value, $name);
    if ($normalized === '0') aux_fail($name . ' must be positive');
    return $normalized;
}

function aux_decimal_leq(string $value, string $maximum): bool {
    $value = ltrim($value, '0');
    $maximum = ltrim($maximum, '0');
    if ($value === '') $value = '0';
    if ($maximum === '') $maximum = '0';
    if (strlen($value) !== strlen($maximum)) return strlen($value) < strlen($maximum);
    return strcmp($value, $maximum) <= 0;
}

function aux_exact_keys(array $value, array $keys, string $name): void {
    $actual = array_keys($value);
    sort($actual);
    sort($keys);
    if ($actual !== $keys) aux_fail($name . ' has unknown or missing fields');
}

function aux_private_json(string $path): array {
    if (!is_file($path) || is_link($path)) aux_fail('auxiliary source must be a regular non-symlink file');
    $size = filesize($path);
    $mode = fileperms($path);
    if (!is_int($size) || $size < 2) aux_fail('auxiliary source size is invalid');
    if ($size > RUNNER_API_AUX_MAX_BYTES) aux_fail('auxiliary source is too large', 7);
    if (!is_int($mode) || (($mode & 0777) !== 0600)) aux_fail('auxiliary source mode must be 0600');
    $raw = file_get_contents($path);
    if (!is_string($raw) || preg_match('//u', $raw) !== 1 || str_contains($raw, chr(0))) aux_fail('auxiliary source is not valid UTF-8');
    try {
        $decoded = json_decode($raw, true, 64, JSON_THROW_ON_ERROR | JSON_BIGINT_AS_STRING);
    } catch (JsonException) {
        aux_fail('auxiliary source is not valid JSON');
    }
    if (!is_array($decoded)) aux_fail('auxiliary source root must be an object');
    return $decoded;
}

function normalize_queue(array $value): array {
    aux_exact_keys($value, ['age', 'detail_complete', 'jobs', 'known_queued', 'partial', 'queued', 'truncated', 'workflow_runs'], 'queue');
    $queued = aux_int($value['queued'], 'queued', -1, RUNNER_API_QUEUE_MAX_JOBS);
    $known = aux_int($value['known_queued'], 'known_queued', 0, RUNNER_API_QUEUE_MAX_JOBS);
    $runs = aux_int($value['workflow_runs'], 'workflow_runs', -1, 1000000);
    $age = aux_int($value['age'], 'age', 0, 31536000);
    foreach (['partial', 'truncated', 'detail_complete'] as $key) if (!is_bool($value[$key])) aux_fail($key . ' must be boolean');
    if (!is_array($value['jobs']) || count($value['jobs']) > RUNNER_API_QUEUE_MAX_JOBS || count($value['jobs']) !== $known) aux_fail('queue jobs do not match known_queued');
    if ($value['detail_complete'] && ($value['partial'] || $value['truncated'] || $queued !== $known)) aux_fail('complete queue detail is inconsistent');
    $jobs = [];
    foreach ($value['jobs'] as $index => $job) {
        if (!is_array($job)) aux_fail('queue job is invalid');
        aux_exact_keys($job, ['created_at', 'job_id', 'labels', 'pool', 'reason', 'repo', 'run_id', 'url', 'workflow'], 'queue job');
        $runId = aux_positive_decimal_string($job['run_id'], 'run_id');
        $jobId = aux_positive_decimal_string($job['job_id'], 'job_id');
        if (!preg_match('~^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$~', (string)$job['repo'])) aux_fail('queue repository is invalid');
        $pool = aux_safe_string($job['pool'], 'pool', 24);
        if (!preg_match('/^[a-z](?:[a-z0-9-]{0,22}[a-z0-9])?$/', $pool)) aux_fail('queue pool is invalid');
        $labels = aux_safe_string($job['labels'], 'labels', 4096);
        $labelParts = $labels === '' ? [] : array_values(array_filter(array_map('trim', explode(',', $labels)), static fn(string $label): bool => $label !== ''));
        if (count($labelParts) > 64) aux_fail('queue labels exceed supported bounds');
        foreach ($labelParts as $label) aux_safe_string($label, 'label', 128);
        $jobs[] = [
            'run_id' => $runId,
            'job_id' => $jobId,
            'repo' => (string)$job['repo'],
            'workflow' => aux_safe_string($job['workflow'], 'workflow', 512),
            'labels' => $labels,
            'pool' => $pool,
            'reason' => aux_safe_string($job['reason'], 'reason', 256),
            'created_at' => aux_safe_string($job['created_at'], 'created_at', 64),
            'url' => aux_safe_string($job['url'], 'url', 2048),
        ];
    }
    $value['jobs'] = $jobs;
    $value['queued'] = $queued;
    $value['known_queued'] = $known;
    $value['workflow_runs'] = $runs;
    $value['age'] = $age;
    return $value;
}

function normalize_statistics(array $value): array {
    aux_exact_keys($value, ['age', 'cancel', 'fail', 'ok', 'other', 'total'], 'statistics');
    foreach (['ok', 'fail', 'cancel', 'other'] as $key) $value[$key] = aux_int($value[$key], $key, 0, 1000000);
    $value['total'] = aux_int($value['total'], 'total', -1, 4000000);
    $value['age'] = aux_int($value['age'], 'age', 0, 31536000);
    if ($value['total'] >= 0 && $value['total'] !== $value['ok'] + $value['fail'] + $value['cancel'] + $value['other']) aux_fail('statistics total is inconsistent');
    return $value;
}

function normalize_cache(array $value): array {
    aux_exact_keys($value, ['age', 'pkg', 'total'], 'cache usage');
    $total = $value['total'];
    if ($total === -1) $value['total'] = -1;
    else $value['total'] = aux_decimal_string($total, 'total');
    $value['pkg'] = aux_decimal_string($value['pkg'], 'pkg');
    $value['age'] = aux_int($value['age'], 'age', 0, 31536000);
    return $value;
}

function normalize_image(array $value): array {
    if (!array_key_exists('exists', $value) || !is_bool($value['exists'])) aux_fail('image exists must be boolean');
    $image = aux_safe_string($value['image'] ?? null, 'image', 512);
    $source = aux_safe_string($value['source'] ?? null, 'source', 16);
    if (!in_array($source, ['builtin', 'remote'], true)) aux_fail('image source is invalid');
    if ($value['exists'] === false) {
        return [
            'exists' => false,
            'image' => $image,
            'source' => $source,
            'image_id' => null,
            'created' => null,
            'size_bytes' => null,
            'base' => null,
            'in_use' => 0,
            'dockerfile' => null,
        ];
    }
    foreach (['image_id', 'created', 'size_bytes', 'base', 'in_use', 'dockerfile'] as $key) if (!array_key_exists($key, $value)) aux_fail('image field is missing: ' . $key);
    $imageId = aux_safe_string($value['image_id'], 'image_id', 71);
    if (!preg_match('/^sha256:[0-9a-f]{64}$/', $imageId)) aux_fail('image_id is invalid');
    $sizeBytes = aux_decimal_string($value['size_bytes'], 'size_bytes');
    if (!aux_decimal_leq($sizeBytes, '1099511627776')) aux_fail('image size exceeds supported bounds');
    $inUse = aux_int($value['in_use'], 'in_use', 0, 64);
    $dockerfile = aux_safe_string($value['dockerfile'], 'dockerfile', 4096);
    if (!str_starts_with($dockerfile, '/')) aux_fail('dockerfile path is invalid');
    return [
        'exists' => true,
        'image' => $image,
        'source' => $source,
        'image_id' => $imageId,
        'created' => aux_safe_string($value['created'], 'created', 64),
        'size_bytes' => $sizeBytes,
        'base' => aux_safe_string($value['base'], 'base', 512),
        'in_use' => $inUse,
        'dockerfile' => $dockerfile,
    ];
}

if ($argc !== 3) aux_fail('usage: api-auxiliary.php queue|statistics|cache|image file');
$mode = $argv[1];
$raw = aux_private_json($argv[2]);
$result = match ($mode) {
    'queue' => normalize_queue($raw),
    'statistics' => normalize_statistics($raw),
    'cache' => normalize_cache($raw),
    'image' => normalize_image($raw),
    default => aux_fail('unsupported auxiliary mode'),
};
try {
    $encoded = json_encode($result, JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES);
} catch (JsonException) {
    aux_fail('could not encode auxiliary result');
}
if (strlen($encoded) + 1 > RUNNER_API_AUX_MAX_BYTES) aux_fail('auxiliary result is too large', 7);
echo $encoded, PHP_EOL;
