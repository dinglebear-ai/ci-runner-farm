<?php
declare(strict_types=1);

const CRF_ADAPTER_MAX_BYTES = 131072;

function fail_request(): never { exit(2); }
function exact_keys(array $value, array $expected): bool {
    $keys = array_keys($value);
    sort($keys, SORT_STRING);
    sort($expected, SORT_STRING);
    return $keys === $expected;
}
function id_valid(mixed $value): bool {
    return is_string($value) && preg_match('/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/D', $value) === 1;
}
function pool_valid(mixed $value): bool {
    return is_string($value) && preg_match('/^[a-z](?:[a-z0-9-]{0,22}[a-z0-9])?$/D', $value) === 1;
}
function positive_int_bounded(mixed $value, int $max): bool {
    return is_int($value) && $value > 0 && $value <= $max;
}
function descriptor_valid(mixed $value): bool {
    return is_string($value) && strlen($value) >= 1 && strlen($value) <= 65536
        && preg_match('/^[A-Za-z0-9._+\/=-]+$/D', $value) === 1;
}

$raw = stream_get_contents(STDIN, CRF_ADAPTER_MAX_BYTES + 1);
if ($raw === false || strlen($raw) === 0 || strlen($raw) > CRF_ADAPTER_MAX_BYTES) fail_request();
try {
    $root = json_decode($raw, true, 16, JSON_THROW_ON_ERROR);
} catch (Throwable) {
    fail_request();
}
if (!is_array($root) || !exact_keys($root, ['schema_version', 'payload']) || ($root['schema_version'] ?? null) !== 1) fail_request();
$payload = $root['payload'];
if (!is_array($payload) || !isset($payload['action']) || !is_string($payload['action'])) fail_request();

$fields = array_fill(0, 9, '');
$fields[0] = $payload['action'];
switch ($payload['action']) {
case 'start':
    if (!exact_keys($payload, ['action','placement_id','command_id','pool_id','runner_name','resources','jit_config'])) fail_request();
    if (!id_valid($payload['placement_id']) || !id_valid($payload['command_id']) || !pool_valid($payload['pool_id']) || !id_valid($payload['runner_name']) || !descriptor_valid($payload['jit_config'])) fail_request();
    $resources = $payload['resources'];
    if (!is_array($resources) || !exact_keys($resources, ['cpu_millis','memory_bytes'])
        || !positive_int_bounded($resources['cpu_millis'] ?? null, 256000)
        || !positive_int_bounded($resources['memory_bytes'] ?? null, 1099511627776)) fail_request();
    $fields[1] = $payload['placement_id'];
    $fields[2] = $payload['command_id'];
    $fields[3] = $payload['pool_id'];
    $fields[4] = $payload['runner_name'];
    $fields[5] = (string)$resources['cpu_millis'];
    $fields[6] = (string)$resources['memory_bytes'];
    $fields[7] = $payload['jit_config'];
    break;
case 'inspect':
case 'cancel':
    if (!exact_keys($payload, ['action','placement_id','expected_id']) || !id_valid($payload['placement_id'])) fail_request();
    if ($payload['expected_id'] !== null && !id_valid($payload['expected_id'])) fail_request();
    $fields[1] = $payload['placement_id'];
    $fields[8] = $payload['expected_id'] ?? '';
    break;
default:
    fail_request();
}
foreach ($fields as $field) {
    fwrite(STDOUT, $field . "\0");
}
