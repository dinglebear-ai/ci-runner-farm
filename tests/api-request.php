<?php
declare(strict_types=1);

$root = dirname(__DIR__);
$cli = $root . '/src/usr/local/emhttp/plugins/ci-runner-farm/include/api-request.php';
$tmp = sys_get_temp_dir() . '/crf-api-request-' . bin2hex(random_bytes(6));
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

function run_cli(string $action, string $verb, string $path): array {
    $pipes = [];
    $process = proc_open(
        [PHP_BINARY, $GLOBALS['cli'], $action, $verb, $path],
        [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']],
        $pipes
    );
    must(is_resource($process), 'could not launch api-request.php');
    fclose($pipes[0]);
    $stdout = stream_get_contents($pipes[1]);
    $stderr = stream_get_contents($pipes[2]);
    fclose($pipes[1]);
    fclose($pipes[2]);
    return [proc_close($process), $stdout, $stderr];
}

function expect_failure(string $label, string $verb, string $path): void {
    [$rc, $stdout] = run_cli('validate', $verb, $path);
    must($rc === 2, $label . ' did not exit 2');
    must($stdout === '', $label . ' wrote to stdout');
}

$requestId = '7bb90867-3378-4ae3-81bb-74ce20fd3274';
$config = str_repeat('a', 64);
$inventory = str_repeat('b', 64);
$base = [
    'schema_version' => 1,
    'request_id' => $requestId,
    'operation' => 'scale',
    'expected' => ['config_revision' => $config, 'inventory_revision' => $inventory],
    'input' => ['pool_id' => 'rust', 'target' => 3],
];

$valid = write_json('valid-scale.json', $base);
[$rc, $stdout, $stderr] = run_cli('validate', 'scale', $valid);
must($rc === 0 && $stdout === '' && $stderr === '', 'valid scale request failed');

[$rc, $stdout, $stderr] = run_cli('fields', 'scale', $valid);
must($rc === 0 && $stderr === '', 'scale fields failed');
$fields = array_map('base64_decode', explode("\t", trim($stdout)));
must($fields === [$requestId, $config, $inventory, 'rust', '3'], 'scale field order changed');

$withoutPool = $base;
unset($withoutPool['input']['pool_id']);
$noPoolPath = write_json('scale-no-pool.json', $withoutPool);
[, $stdout] = run_cli('fields', 'scale', $noPoolPath);
$fields = array_map('base64_decode', explode("\t", trim($stdout)));
must($fields[3] === 'null', 'optional pool sentinel changed');

$operation = [
    'schema_version' => 1,
    'request_id' => $requestId,
    'operation' => 'operation-read',
    'expected' => (object)[],
    'input' => ['operation_id' => '01234567-89ab-cdef-0123-456789abcdef'],
];
$operationPath = write_json('operation-read.json', $operation);
[, $stdout] = run_cli('fields', 'operation-read', $operationPath);
$fields = array_map('base64_decode', explode("\t", trim($stdout)));
must($fields === [$requestId, '01234567-89ab-cdef-0123-456789abcdef'], 'operation-read field order changed');

$case = $base;
$case['extra'] = true;
expect_failure('unknown root field', 'scale', write_json('unknown-root.json', $case));

$case = $base;
$case['operation'] = 'start';
expect_failure('wrong operation', 'scale', write_json('wrong-operation.json', $case));

$case = $base;
$case['schema_version'] = 2;
expect_failure('wrong schema', 'scale', write_json('wrong-schema.json', $case));

$case = $base;
$case['input']['target'] = '3';
expect_failure('wrong target type', 'scale', write_json('target-string.json', $case));

$case = $base;
$case['input']['target'] = 65;
expect_failure('target overflow', 'scale', write_json('target-overflow.json', $case));

$case = $base;
$case['input']['pool_id'] = "ru\nst";
expect_failure('decoded control character', 'scale', write_json('control.json', $case));

$case = $base;
unset($case['expected']['inventory_revision']);
expect_failure('missing inventory revision', 'scale', write_json('missing-inventory.json', $case));

expect_failure('array root', 'scale', write_json('array-root.json', []));
expect_failure('malformed JSON', 'scale', write_raw('malformed.json', '{'));
expect_failure('raw NUL', 'scale', write_raw('nul.json', "{\"x\":\"\0\"}"));
expect_failure('unsafe mode', 'scale', write_json('unsafe-mode.json', $base, 0644));

$target = write_json('symlink-target.json', $base);
$symlink = $tmp . '/request-link.json';
symlink($target, $symlink);
expect_failure('symlink request', 'scale', $symlink);
expect_failure('unsupported verb', 'not-a-verb', $valid);

printf("api-request: OK\n");
