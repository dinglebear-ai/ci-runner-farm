<?php
declare(strict_types=1);

$root = dirname(__DIR__);
$exec = file_get_contents($root . '/src/usr/local/emhttp/plugins/ci-runner-farm/include/exec.php');
$engine = file_get_contents($root . '/src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh');
$page = file_get_contents($root . '/src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmSettings.page');

function must(bool $condition, string $message): void {
    if (!$condition) {
        fwrite(STDERR, "FAIL: $message\n");
        exit(1);
    }
}

must(str_contains($exec, "\$method !== 'POST'"), 'endpoint is not POST-only');
must(!str_contains($exec, '$_REQUEST'), 'endpoint reads the mixed request bag');
must(strpos($exec, "\$method !== 'POST'") < strpos($exec, 'hash_equals'), 'method is checked after CSRF');
must(strpos($exec, "post_scalar('csrf_token'") < strpos($exec, 'hash_equals'), 'CSRF type is checked after hash_equals');
must(str_contains($exec, "preg_match('/^[a-z][a-z0-9-]{0,63}$/"), 'action is not bounded and shape checked');
must(str_contains($exec, "case 'apply-config':"), 'transactional endpoint is absent');
must(str_contains($exec, 'array_diff_key($snapshot, $expectedKeys)'), 'settings allowlist is not exact');
must(str_contains($exec, "tempnam(\$CFGDIR, '.apply.')"), 'staging is not same-directory');
must(str_contains($exec, "chmod(\$staged, 0600)"), 'staging mode is not private');
must(str_contains($exec, "function_exists('fsync')"), 'staging does not flush durable content');
must(str_contains($engine, 'with_fleet_lock wait cmd_apply_config'), 'apply is not serialized');
must(str_contains($engine, '"code":"stale_config"'), 'stale writes have no stable conflict code');
must(str_contains($engine, 'mv -f "$staged" "$old_cfg"'), 'commit is not an atomic rename');
must(str_contains($engine, 'chmod 0600 "$backup_tmp"'), 'backup is not private');
must(strpos($engine, 'mv -f "$staged" "$old_cfg"') < strpos($engine, 'reconcile_start', strpos($engine, 'cmd_apply_config')), 'reconcile starts before commit');
must(!str_contains($page, '/update.php'), 'Settings still authorizes native update.php writes');

echo "settings-endpoint: OK\n";
