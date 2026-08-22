<?php
declare(strict_types=1);

const RUNNER_API_SCHEMA_VERSION = 1;
const RUNNER_API_MAX_REQUEST_BYTES = 1048576;

function request_fail(string $message): void {
    fwrite(STDERR, $message . PHP_EOL);
    exit(2);
}

function exact_keys(object $value, array $allowed, string $label): void {
    $actual = array_keys(get_object_vars($value));
    sort($actual);
    sort($allowed);
    if ($actual !== $allowed) request_fail($label . ' has unknown or missing fields');
}

function required_object(object $value, string $name): object {
    $child = $value->{$name} ?? null;
    if (!is_object($child)) request_fail($name . ' must be an object');
    return $child;
}

function required_string(object $value, string $name): string {
    $child = $value->{$name} ?? null;
    if (!is_string($child)) request_fail($name . ' must be a string');
    return $child;
}

function required_int(object $value, string $name): int {
    $child = $value->{$name} ?? null;
    if (!is_int($child)) request_fail($name . ' must be an integer');
    return $child;
}

function validate_sha256(string $value, string $name): string {
    if (!preg_match('/^[0-9a-f]{64}$/', $value)) request_fail($name . ' must be lowercase sha256');
    return $value;
}

function validate_uuid(string $value, string $name): string {
    if (!preg_match('/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/', $value)) {
        request_fail($name . ' must be a canonical lowercase UUID');
    }
    return $value;
}

function validate_pool(string $value): string {
    if (!preg_match('/^[a-z](?:[a-z0-9-]{0,22}[a-z0-9])?$/', $value)) request_fail('pool_id is invalid');
    return $value;
}

function validate_runner(string $value): string {
    if (!preg_match('/^ci-runner-(?:[0-9]+|[a-z](?:[a-z0-9-]{0,22}[a-z0-9])?-[0-9]+|jit-[a-z0-9]+(?:-[a-z0-9]+)*-[0-9a-f]{20})$/', $value)) {
        request_fail('runner_name is invalid');
    }
    return $value;
}

function validate_repository(string $value): string {
    if (!preg_match('/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/', $value)) request_fail('repository is invalid');
    return $value;
}

function assert_no_controls(mixed $value): void {
    if (is_string($value)) {
        if (preg_match('/[\x00-\x1F\x7F]/', $value)) request_fail('control characters are not allowed');
        return;
    }
    if (is_array($value)) {
        foreach ($value as $child) assert_no_controls($child);
        return;
    }
    if (is_object($value)) foreach (get_object_vars($value) as $child) assert_no_controls($child);
}

function config_expected(object $expected): string {
    exact_keys($expected, ['config_revision'], 'expected');
    return validate_sha256(required_string($expected, 'config_revision'), 'config_revision');
}

function fleet_expected(object $expected): array {
    exact_keys($expected, ['config_revision', 'inventory_revision'], 'expected');
    return [
        validate_sha256(required_string($expected, 'config_revision'), 'config_revision'),
        validate_sha256(required_string($expected, 'inventory_revision'), 'inventory_revision'),
    ];
}

function transition_expected(object $expected): array {
    exact_keys($expected, ['compatibility_record_id', 'config_revision', 'ownership_revision', 'transition_revision'], 'expected');
    return [
        validate_sha256(required_string($expected, 'config_revision'), 'config_revision'),
        validate_sha256(required_string($expected, 'ownership_revision'), 'ownership_revision'),
        validate_sha256(required_string($expected, 'compatibility_record_id'), 'compatibility_record_id'),
        validate_sha256(required_string($expected, 'transition_revision'), 'transition_revision'),
    ];
}

function empty_expected(object $expected): void { exact_keys($expected, [], 'expected'); }
function empty_input(object $input): void { exact_keys($input, [], 'input'); }

function normalize_request(string $verb, string $path): array {
    if (!is_file($path) || is_link($path)) request_fail('request file must be a regular non-symlink file');
    $size = filesize($path);
    $mode = fileperms($path);
    if (!is_int($size) || $size < 2 || $size > RUNNER_API_MAX_REQUEST_BYTES) request_fail('request file size is invalid');
    if (!is_int($mode) || (($mode & 0777) !== 0600)) request_fail('request file mode must be 0600');
    $raw = file_get_contents($path);
    if (!is_string($raw) || preg_match('//u', $raw) !== 1) request_fail('request must be UTF-8');
    if (str_contains($raw, "\0")) request_fail('request contains NUL');
    try {
        $request = json_decode($raw, false, 64, JSON_THROW_ON_ERROR | JSON_BIGINT_AS_STRING);
    } catch (JsonException) {
        request_fail('request is not valid JSON');
    }
    if (!is_object($request)) request_fail('request root must be an object');
    assert_no_controls($request);
    exact_keys($request, ['expected', 'input', 'operation', 'request_id', 'schema_version'], 'request');
    if (($request->schema_version ?? null) !== RUNNER_API_SCHEMA_VERSION) request_fail('schema_version is unsupported');
    $requestId = validate_uuid(required_string($request, 'request_id'), 'request_id');
    $operation = required_string($request, 'operation');
    if ($operation !== $verb) request_fail('operation does not match invoked verb');
    $expected = required_object($request, 'expected');
    $input = required_object($request, 'input');
    $fields = [$requestId];

    switch ($verb) {
        case 'start': case 'stop': case 'restart':
            [$config, $inventory] = fleet_expected($expected);
            empty_input($input);
            array_push($fields, $config, $inventory);
            break;
        case 'scale':
            [$config, $inventory] = fleet_expected($expected);
            $inputKeys = array_keys(get_object_vars($input));
            sort($inputKeys);
            if ($inputKeys !== ['target'] && $inputKeys !== ['pool_id', 'target']) request_fail('input has unknown or missing fields');
            $target = required_int($input, 'target');
            if ($target < 0 || $target > 64) request_fail('target must be between 0 and 64');
            $pool = property_exists($input, 'pool_id') ? validate_pool(required_string($input, 'pool_id')) : 'null';
            array_push($fields, $config, $inventory, $pool, (string)$target);
            break;
        case 'prewarm':
            $config = config_expected($expected);
            exact_keys($input, ['pool_id', 'target'], 'input');
            $target = required_int($input, 'target');
            if ($target < 0 || $target > 64) request_fail('target must be between 0 and 64');
            array_push($fields, $config, validate_pool(required_string($input, 'pool_id')), (string)$target);
            break;
        case 'recycle':
            [$config, $inventory] = fleet_expected($expected);
            exact_keys($input, ['runner_name'], 'input');
            array_push($fields, $config, $inventory, validate_runner(required_string($input, 'runner_name')));
            break;
        case 'maintenance':
            $config = config_expected($expected);
            exact_keys($input, ['mode'], 'input');
            $modeValue = required_string($input, 'mode');
            if (!in_array($modeValue, ['BEGIN', 'RESUME'], true)) request_fail('mode must be BEGIN or RESUME');
            array_push($fields, $config, $modeValue);
            break;
        case 'operation-read':
            empty_expected($expected);
            exact_keys($input, ['operation_id'], 'input');
            $fields[] = validate_uuid(required_string($input, 'operation_id'), 'operation_id');
            break;
        case 'runner-log': case 'history-log':
            empty_expected($expected);
            exact_keys($input, ['lines', 'runner_name'], 'input');
            $lines = required_int($input, 'lines');
            if ($lines < 1 || $lines > 500) request_fail('lines must be between 1 and 500');
            array_push($fields, validate_runner(required_string($input, 'runner_name')), (string)$lines);
            break;
        case 'controller-log':
            empty_expected($expected);
            exact_keys($input, ['lines'], 'input');
            $lines = required_int($input, 'lines');
            if ($lines < 1 || $lines > 500) request_fail('lines must be between 1 and 500');
            $fields[] = (string)$lines;
            break;
        case 'image-build-start':
            empty_expected($expected);
            exact_keys($input, ['dockerfile_sha256'], 'input');
            $fields[] = validate_sha256(required_string($input, 'dockerfile_sha256'), 'dockerfile_sha256');
            break;
        case 'provisioning-validation-start': case 'compatibility-test-start': case 'cache-clear':
            $fields[] = config_expected($expected);
            empty_input($input);
            break;
        case 'backend-migration-start': case 'backend-rollback':
            foreach (transition_expected($expected) as $value) $fields[] = $value;
            empty_input($input);
            break;
        case 'queue-cancel':
            empty_expected($expected);
            exact_keys($input, ['repository', 'run_id'], 'input');
            $runId = required_string($input, 'run_id');
            if (!preg_match('/^[0-9]{1,20}$/', $runId)) request_fail('run_id is invalid');
            array_push($fields, validate_repository(required_string($input, 'repository')), $runId);
            break;
        default: request_fail('unsupported operation');
    }
    return [$request, $fields];
}

if ($argc !== 4 || !in_array($argv[1], ['validate', 'fields'], true)) request_fail('usage: api-request.php validate|fields verb file');
[, $fields] = normalize_request($argv[2], $argv[3]);
if ($argv[1] === 'fields') echo implode("\t", array_map(static fn(string $value): string => base64_encode($value), $fields)), PHP_EOL;
