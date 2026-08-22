<?php
declare(strict_types=1);

$root = dirname(__DIR__);
$cli = $root . '/src/usr/local/emhttp/plugins/ci-runner-farm/include/api-status.php';
$tmp = sys_get_temp_dir() . '/crf-api-status-' . bin2hex(random_bytes(6));
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

function run_status(array $args): array {
    $pipes = [];
    $process = proc_open(
        array_merge([PHP_BINARY, $GLOBALS['cli']], $args),
        [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']],
        $pipes
    );
    must(is_resource($process), 'could not launch api-status.php');
    fclose($pipes[0]);
    $stdout = stream_get_contents($pipes[1]);
    $stderr = stream_get_contents($pipes[2]);
    fclose($pipes[1]);
    fclose($pipes[2]);
    return [proc_close($process), $stdout, $stderr];
}

function base_status(string $inventoryRevision, string $runnerName = 'ci-runner-rust-1'): array {
    return [
        'schema_version' => 2,
        'config_revision' => str_repeat('a', 64),
        'observed_at' => 1785950000,
        'inventory_revision' => $inventoryRevision,
        'backend' => [
            'requested' => 'scaleset',
            'effective' => 'invalid',
            'transition_phase' => 'invalid',
            'transition_id' => '',
            'transition_revision' => str_repeat('b', 64),
            'ownership_revision' => str_repeat('c', 64),
        ],
        'compatibility' => [
            'valid' => true,
            'reason' => 'valid',
            'record_id' => str_repeat('d', 64),
            'runner_group_id' => '9007199254740993',
        ],
        'operation' => null,
        'maintenance' => false,
        'resources' => [
            'available' => true,
            'reason' => null,
            'cpu_milli' => ['budget' => 8000, 'reserve' => 1000, 'reserved' => 1500, 'admissible' => 6500],
            'memory_bytes' => ['budget' => 17179869184, 'reserve' => 1073741824, 'reserved' => 3221225472, 'admissible' => 13958643712],
        ],
        'reservations' => [],
        'recent_activity' => [[
            'schema_version' => 1,
            'observed_at' => 1785950000,
            'completed_at' => '2026-08-05T18:00:00Z',
            'runner_name' => $runnerName,
            'pool_id' => 'rust',
            'work_handle' => '9007199254740993',
            'job' => 'build',
            'conclusion' => 'success',
        ]],
        'mode' => 'invalid',
        'config_error' => '',
        'count' => 1,
        'configured' => 1,
        'token' => true,
        'autoscale_enabled' => true,
        'autoscale_max' => 64,
        'autoscale' => 'running',
        'image_autoupdate' => 'off',
        'warning' => '',
        'security' => '',
        'stale' => 0,
        'retiring' => 0,
        'blocked_capacity' => 0,
        'pools' => [[
            'id' => 'rust',
            'label' => 'rust',
            'autoscale_enabled' => true,
            'configured' => 1,
            'effective_target' => 1,
            'count' => 1,
            'up' => 1,
            'busy' => 1,
            'idle' => 0,
            'starting' => 0,
            'error' => 0,
            'completed' => 0,
            'stale' => 0,
            'retiring' => 0,
            'pending' => 0,
            'min' => 1,
            'max' => 'auto',
            'idle_buffer' => 1,
            'remote_scale_set_id' => '9007199254740993',
        ]],
        'runners' => [[
            'name' => $runnerName,
            'pool' => 'rust',
            'routing_label' => 'rust',
            'scope_target' => 'org:owner',
            'pool_index' => 1,
            'state' => 'running',
            'phase' => 'busy',
            'job' => 'build',
            'job_started' => '2026-08-05T18:00:00Z',
            'started_at' => '2026-08-05T17:00:00Z',
            'repo' => 'owner/repo',
            'pr' => '1',
            'branch' => 'main',
            'run_id' => '9007199254740993',
            'cpus' => 1,
            'mem_gb' => 3,
            'cpu_pct' => 42.5,
            'mem_used_mib' => 512,
            'completed' => false,
            'stale' => false,
            'retiring' => false,
        ]],
    ];
}

$inventory = write_raw(
    'inventory.tsv',
    "ci-runner-rust-1|running|healthy|1500000000|3221225472|gen|rust|org:owner|1|rust|valid|classic|2026-08-05T17:00:00Z
"
);
$inventoryRevision = hash_file('sha256', $inventory);
$statusPath = write_json('status.json', base_status($inventoryRevision));
[$rc, $stdout, $stderr] = run_status(['status', $statusPath, $inventory]);
must($rc === 0 && $stderr === '', 'valid status failed: ' . $stderr);
$strict = json_decode($stdout, true, 64, JSON_THROW_ON_ERROR);
must(($strict['runners'][0]['cpu_milli'] ?? null) === 1500, 'fractional CPU was not preserved');
must(($strict['runners'][0]['memory_bytes'] ?? null) === 3221225472, 'exact memory bytes were not preserved');
must(($strict['runners'][0]['run_id'] ?? null) === '9007199254740993', 'run ID was truncated');
must(($strict['pools'][0]['remote_scale_set_id'] ?? null) === '9007199254740993', 'remote scale-set ID was truncated');
must(($strict['recent_activity'][0]['work_handle'] ?? null) === '9007199254740993', 'work handle was truncated');
must(($strict['compatibility']['runner_group_id'] ?? null) === '9007199254740993', 'runner group ID was truncated');
must(($strict['mode'] ?? null) === 'invalid' && ($strict['backend']['effective'] ?? null) === 'invalid', 'invalid read state was coerced');
must(($strict['resources']['available'] ?? null) === true && array_key_exists('reason', $strict['resources']) && $strict['resources']['reason'] === null, 'available resource state changed');

$uncappedInventory = write_raw(
    'uncapped.tsv',
    "ci-runner-rust-2|running|healthy|0|0|gen|rust|org:owner|2|rust|valid|classic|2026-08-05T17:00:00Z
"
);
$uncappedStatus = base_status(hash_file('sha256', $uncappedInventory), 'ci-runner-rust-2');
$uncappedStatus['runners'][0]['run_id'] = '';
$uncappedPath = write_json('uncapped-status.json', $uncappedStatus);
[$rc, $stdout] = run_status(['status', $uncappedPath, $uncappedInventory]);
$uncapped = json_decode($stdout, true, 64, JSON_THROW_ON_ERROR);
must($rc === 0 && $uncapped['runners'][0]['cpu_milli'] === null && $uncapped['runners'][0]['memory_bytes'] === null, 'uncapped limits did not normalize to null');

$unavailable = base_status($inventoryRevision);
$unavailable['resources'] = [
    'available' => false,
    'reason' => 'cgroup_v2_unavailable',
    'cpu_milli' => ['budget' => 0, 'reserve' => 0, 'reserved' => 0, 'admissible' => 0],
    'memory_bytes' => ['budget' => 0, 'reserve' => 0, 'reserved' => 0, 'admissible' => 0],
];
[$rc, $stdout] = run_status(['status', write_json('unavailable-resources.json', $unavailable), $inventory]);
$unavailableStrict = json_decode($stdout, true, 64, JSON_THROW_ON_ERROR);
must($rc === 0 && $unavailableStrict['resources']['available'] === false && $unavailableStrict['resources']['reason'] === 'cgroup_v2_unavailable', 'unavailable resource state was lost');

$badSchema = base_status($inventoryRevision);
$badSchema['schema_version'] = 3;
[$rc, $stdout] = run_status(['status', write_json('bad-schema.json', $badSchema), $inventory]);
must($rc === 6 && $stdout === '', 'unsupported status schema did not exit 6');

$inventoryUnavailable = base_status($inventoryRevision);
$inventoryUnavailable['compatibility']['reason'] = 'inventory_unavailable';
$inventoryUnavailable['config_error'] = 'Docker inventory unavailable';
[$rc, $stdout] = run_status(['status', write_json('inventory-unavailable.json', $inventoryUnavailable), $inventory]);
must($rc === 8 && $stdout === '', 'inventory unavailable did not exit 8');

$unsafeInventory = write_raw('unsafe-inventory.tsv', file_get_contents($inventory), 0644);
[$rc, $stdout] = run_status(['status', $statusPath, $unsafeInventory]);
must($rc === 5 && $stdout === '', 'unsafe inventory mode was accepted');

$overCpuInventory = write_raw(
    'over-cpu.tsv',
    "ci-runner-rust-1|running|healthy|256001000000|3221225472|gen|rust|org:owner|1|rust|valid|classic|2026-08-05T17:00:00Z
"
);
[$rc, $stdout] = run_status(['status', $statusPath, $overCpuInventory]);
must($rc === 5 && $stdout === '', 'over-bound CPU limit was accepted');

$nonExactCpuInventory = write_raw(
    'non-exact-cpu.tsv',
    "ci-runner-rust-1|running|healthy|1500000001|3221225472|gen|rust|org:owner|1|rust|valid|classic|2026-08-05T17:00:00Z
"
);
[$rc, $stdout] = run_status(['status', $statusPath, $nonExactCpuInventory]);
must($rc === 5 && $stdout === '', 'non-millicore CPU limit was accepted');

$readiness = [
    'schema_version' => 2,
    'backend' => ['requested' => 'classic', 'effective' => 'classic'],
    'compatibility' => ['valid' => false, 'reason' => 'not_checked'],
    'operation' => null,
    'count' => 2,
];
[$rc, $stdout, $stderr] = run_status(['readiness', write_json('readiness.json', $readiness)]);
$ready = json_decode($stdout, true, 64, JSON_THROW_ON_ERROR);
must($rc === 0 && $stderr === '' && $ready['count'] === 2, 'valid readiness failed');

$readiness['count'] = null;
[$rc, $stdout] = run_status(['readiness', write_json('readiness-null.json', $readiness)]);
$ready = json_decode($stdout, true, 64, JSON_THROW_ON_ERROR);
must($rc === 0 && array_key_exists('count', $ready) && $ready['count'] === null, 'unknown readiness count was lost');

$readiness['schema_version'] = 1;
[$rc, $stdout] = run_status(['readiness', write_json('readiness-bad-schema.json', $readiness)]);
must($rc === 6 && $stdout === '', 'unsupported readiness schema did not exit 6');

printf("api-status: OK
");
