<?php
declare(strict_types=1);

const RUNNER_API_STATUS_MAX_BYTES = 1048576;
const RUNNER_API_STATUS_MAX_RUNNERS = 64;
const RUNNER_API_STATUS_MAX_POOLS = 64;

function status_fail(string $message, int $exitCode = 5): never {
    fwrite(STDERR, $message . PHP_EOL);
    exit($exitCode);
}

function private_json(string $path): array {
    if (!is_file($path) || is_link($path)) status_fail('status source must be a regular non-symlink file');
    $size = filesize($path);
    $mode = fileperms($path);
    if (!is_int($size) || $size < 2) status_fail('status source size is invalid');
    if ($size > RUNNER_API_STATUS_MAX_BYTES) status_fail('status source is too large', 7);
    if (!is_int($mode) || (($mode & 0777) !== 0600)) status_fail('status source mode must be 0600');
    $raw = file_get_contents($path);
    if (!is_string($raw) || preg_match('//u', $raw) !== 1 || str_contains($raw, chr(0))) status_fail('status source is not valid UTF-8');
    try {
        $decoded = json_decode($raw, true, 64, JSON_THROW_ON_ERROR | JSON_BIGINT_AS_STRING);
    } catch (JsonException) {
        status_fail('status source is not valid JSON');
    }
    if (!is_array($decoded)) status_fail('status source root must be an object');
    return $decoded;
}

function required_key(array $value, string $key): mixed {
    if (!array_key_exists($key, $value)) status_fail('missing status field ' . $key);
    return $value[$key];
}

function required_array(array $value, string $key): array {
    $child = required_key($value, $key);
    if (!is_array($child)) status_fail($key . ' must be an object or array');
    return $child;
}

function required_string(array $value, string $key): string {
    $child = required_key($value, $key);
    if (!is_string($child)) status_fail($key . ' must be a string');
    if (preg_match('/[\x00-\x1f\x7f]/', $child)) status_fail($key . ' contains control characters');
    return $child;
}

function required_int(array $value, string $key): int {
    $child = required_key($value, $key);
    if (!is_int($child)) status_fail($key . ' must be an integer');
    return $child;
}

function decimal_string(mixed $value, string $name, bool $nullable = false): ?string {
    if ($nullable && $value === null) return null;
    if (is_int($value)) {
        if ($value < 0) status_fail($name . ' must be non-negative');
        return (string)$value;
    }
    if (is_string($value) && preg_match('/^(0|[1-9][0-9]*)$/', $value)) return $value;
    status_fail($name . ' must be a canonical non-negative integer');
}

function validate_sha(string $value, string $name, bool $allowEmpty = false): void {
    if ($allowEmpty && $value === '') return;
    if (!preg_match('/^[0-9a-f]{64}$/', $value)) status_fail($name . ' must be lowercase sha256');
}

function decimal_leq(string $value, string $maximum): bool {
    $value = ltrim($value, '0');
    $maximum = ltrim($maximum, '0');
    if ($value === '') $value = '0';
    if ($maximum === '') $maximum = '0';
    if (strlen($value) !== strlen($maximum)) return strlen($value) < strlen($maximum);
    return strcmp($value, $maximum) <= 0;
}

function inventory_limits(string $path): array {
    if (!is_file($path) || is_link($path)) status_fail('inventory must be a regular non-symlink file');
    $size = filesize($path);
    $mode = fileperms($path);
    if (!is_int($size) || $size > RUNNER_API_STATUS_MAX_BYTES || !is_int($mode) || (($mode & 0777) !== 0600)) status_fail('inventory file is unsafe');
    $limits = [];
    foreach (file($path, FILE_IGNORE_NEW_LINES) ?: [] as $line) {
        if ($line === '') continue;
        $parts = explode('|', $line);
        if (count($parts) !== 13) status_fail('inventory row shape is invalid');
        [$name, , , $nanoCpus, $memory] = $parts;
        if (!preg_match('/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/', $name)) status_fail('inventory runner name is invalid');
        if (isset($limits[$name])) status_fail('inventory contains duplicate runner names');
        if (!preg_match('/^(0|[1-9][0-9]{0,17})$/', $nanoCpus) || !preg_match('/^(0|[1-9][0-9]{0,18})$/', $memory)) status_fail('inventory limits are invalid');
        if (!decimal_leq($nanoCpus, '256000000000') || !decimal_leq($memory, '1099511627776')) status_fail('inventory limits exceed supported bounds');
        $nano = (int)$nanoCpus;
        $memoryValue = (int)$memory;
        if ($nano % 1000000 !== 0) status_fail('inventory CPU limit is not exact millicores');
        $limits[$name] = [
            'cpu_milli' => $nano === 0 ? null : intdiv($nano, 1000000),
            'memory_bytes' => $memoryValue === 0 ? null : $memoryValue,
        ];
    }
    return $limits;
}

function normalize_compatibility(array &$status): void {
    $compatibility = required_array($status, 'compatibility');
    if (array_key_exists('runner_group_id', $compatibility) && $compatibility['runner_group_id'] !== null) {
        $compatibility['runner_group_id'] = decimal_string($compatibility['runner_group_id'], 'runner_group_id');
    }
    $status['compatibility'] = $compatibility;
}

function normalize_operation(array &$status): void {
    $operation = required_key($status, 'operation');
    if ($operation === null) return;
    if (!is_array($operation)) status_fail('operation must be an object or null');
    $keys = array_keys($operation);
    sort($keys);
    $expected = ['code', 'config_revision', 'created_at', 'finished_at', 'kind', 'message', 'operation_id', 'output', 'schema_version', 'state', 'updated_at'];
    sort($expected);
    if ($keys !== $expected) status_fail('operation has unknown or missing fields');
    if (required_int($operation, 'schema_version') !== 1) status_fail('operation schema is unsupported', 6);
    $id = required_string($operation, 'operation_id');
    if (!preg_match('/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/', $id)) status_fail('operation id is invalid');
    $kind = required_string($operation, 'kind');
    if (!in_array($kind, ['compatibility_test', 'provisioning_validation', 'image_build'], true)) status_fail('operation kind is invalid');
    $state = required_string($operation, 'state');
    if (!in_array($state, ['queued', 'running', 'succeeded', 'failed', 'cancelled'], true)) status_fail('operation state is invalid');
    foreach (['code' => 128, 'message' => 4096] as $field => $maximum) {
        $value = required_string($operation, $field);
        if ($value === '' || strlen($value) > $maximum) status_fail('operation ' . $field . ' is invalid');
    }
    $configRevision = required_string($operation, 'config_revision');
    validate_sha($configRevision, 'operation.config_revision');
    $created = required_string($operation, 'created_at');
    $updated = required_string($operation, 'updated_at');
    $finished = required_key($operation, 'finished_at');
    $createdEpoch = strtotime($created);
    $updatedEpoch = strtotime($updated);
    if ($createdEpoch === false || $updatedEpoch === false || $updatedEpoch < $createdEpoch) status_fail('operation timestamps are invalid');
    $terminal = in_array($state, ['succeeded', 'failed', 'cancelled'], true);
    if ($finished === null) {
        if ($terminal) status_fail('terminal operation requires finished_at');
    } else {
        if (!is_string($finished) || preg_match('/[\x00-\x1f\x7f]/', $finished)) status_fail('operation finished_at is invalid');
        $finishedEpoch = strtotime($finished);
        if (!$terminal || $finishedEpoch === false || $finishedEpoch < $updatedEpoch) status_fail('operation finished_at is inconsistent');
    }
    $output = required_array($operation, 'output');
    if (count($output) > 20) status_fail('operation output has too many lines');
    $bytes = 0;
    foreach ($output as $index => $line) {
        if (!is_string($line) || strlen($line) > 512 || preg_match('/[\x00-\x1f\x7f]/', $line)) status_fail('operation output line is invalid');
        $bytes += strlen($line) + ($index === 0 ? 0 : 1);
    }
    if ($bytes > 4096) status_fail('operation output is too large');
    $status['operation'] = $operation;
}

function normalize_status(array $status, string $inventoryPath): array {
    if (required_int($status, 'schema_version') !== 2) status_fail('unsupported status schema', 6);
    $configRevision = required_string($status, 'config_revision');
    $inventoryRevision = required_string($status, 'inventory_revision');
    validate_sha($configRevision, 'config_revision');
    validate_sha($inventoryRevision, 'inventory_revision');
    if (required_int($status, 'observed_at') <= 0) status_fail('observed_at is invalid');
    required_array($status, 'backend');
    normalize_compatibility($status);
    normalize_operation($status);
    if (($status['compatibility']['reason'] ?? '') === 'inventory_unavailable' || required_string($status, 'config_error') === 'Docker inventory unavailable') {
        status_fail('inventory is unavailable', 8);
    }
    $resources = required_array($status, 'resources');
    if (!is_bool($resources['available'] ?? null)) status_fail('resources.available must be boolean');
    if ($resources['available'] === true && ($resources['reason'] ?? null) !== null) status_fail('available resources must have null reason');
    if ($resources['available'] === false) {
        $reason = $resources['reason'] ?? null;
        if (!is_string($reason) || $reason === '' || preg_match('/[\x00-\x1f\x7f]/', $reason)) status_fail('unavailable resources require a safe reason');
    }
    foreach (['cpu_milli', 'memory_bytes'] as $quantityName) {
        $quantity = $resources[$quantityName] ?? null;
        if (!is_array($quantity)) status_fail('resource quantity is invalid');
        foreach (['budget', 'reserve', 'reserved', 'admissible'] as $field) decimal_string($quantity[$field] ?? null, $quantityName . '.' . $field);
    }
    $status['resources'] = $resources;
    $pools = required_array($status, 'pools');
    $runners = required_array($status, 'runners');
    if (count($pools) > RUNNER_API_STATUS_MAX_POOLS || count($runners) > RUNNER_API_STATUS_MAX_RUNNERS) status_fail('status arrays exceed supported bounds', 7);
    foreach ($pools as &$pool) {
        if (!is_array($pool)) status_fail('pool entry is invalid');
        if (array_key_exists('remote_scale_set_id', $pool) && $pool['remote_scale_set_id'] !== null) {
            $pool['remote_scale_set_id'] = decimal_string($pool['remote_scale_set_id'], 'remote_scale_set_id');
        }
    }
    unset($pool);
    $limits = inventory_limits($inventoryPath);
    $actualInventoryRevision = hash_file('sha256', $inventoryPath);
    if (!is_string($actualInventoryRevision) || $actualInventoryRevision !== $inventoryRevision) status_fail('inventory revision does not match the augmented snapshot');
    foreach ($runners as &$runner) {
        if (!is_array($runner)) status_fail('runner entry is invalid');
        $name = required_string($runner, 'name');
        if (!array_key_exists($name, $limits)) status_fail('runner is missing from inventory snapshot');
        $runner['cpu_milli'] = $limits[$name]['cpu_milli'];
        $runner['memory_bytes'] = $limits[$name]['memory_bytes'];
        if (array_key_exists('run_id', $runner) && $runner['run_id'] !== '') $runner['run_id'] = decimal_string($runner['run_id'], 'run_id');
    }
    unset($runner);
    $recent = required_array($status, 'recent_activity');
    foreach ($recent as &$activity) {
        if (!is_array($activity)) status_fail('recent activity entry is invalid');
        $activity['work_handle'] = decimal_string($activity['work_handle'] ?? null, 'work_handle');
    }
    unset($activity);
    $status['pools'] = $pools;
    $status['runners'] = $runners;
    $status['recent_activity'] = $recent;
    return $status;
}

function normalize_readiness(array $status): array {
    if (required_int($status, 'schema_version') !== 2) status_fail('unsupported readiness schema', 6);
    required_array($status, 'backend');
    normalize_compatibility($status);
    normalize_operation($status);
    $count = required_key($status, 'count');
    if ($count !== null && (!is_int($count) || $count < 0 || $count > RUNNER_API_STATUS_MAX_RUNNERS)) status_fail('readiness count is invalid');
    return $status;
}

if ($argc < 3) status_fail('usage: api-status.php status raw inventory | readiness raw');
$mode = $argv[1];
$raw = private_json($argv[2]);
if ($mode === 'status' && $argc === 4) $result = normalize_status($raw, $argv[3]);
elseif ($mode === 'readiness' && $argc === 3) $result = normalize_readiness($raw);
else status_fail('invalid api-status invocation');
try {
    $encoded = json_encode($result, JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES);
} catch (JsonException) {
    status_fail('could not encode strict status');
}
if (strlen($encoded) + 1 > RUNNER_API_STATUS_MAX_BYTES) status_fail('strict status is too large', 7);
echo $encoded, PHP_EOL;
