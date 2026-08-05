<?php
declare(strict_types=1);

const CRF_OPERATION_RECORD_MAX_BYTES = 65536;
const CRF_OPERATION_MESSAGE_MAX_BYTES = 512;
const CRF_OPERATION_OUTPUT_MAX_LINES = 20;
const CRF_OPERATION_OUTPUT_MAX_BYTES = 4096;

function operation_fail(string $message, int $exitCode = 5): never {
    fwrite(STDERR, $message . PHP_EOL);
    exit($exitCode);
}

function operation_uuid(string $value, string $name): string {
    if (!preg_match('/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/', $value)) {
        operation_fail($name . ' is invalid');
    }
    return $value;
}

function operation_sha(string $value): string {
    if (!preg_match('/^[0-9a-f]{64}$/', $value)) operation_fail('config revision is invalid');
    return $value;
}

function operation_kind(string $value): string {
    if (!in_array($value, ['compatibility_test', 'provisioning_validation', 'image_build'], true)) {
        operation_fail('operation kind is invalid');
    }
    return $value;
}

function operation_state(string $value): string {
    if (!in_array($value, ['queued', 'running', 'succeeded', 'failed', 'cancelled'], true)) {
        operation_fail('operation state is invalid');
    }
    return $value;
}

function operation_terminal(string $value): bool {
    return in_array($value, ['succeeded', 'failed', 'cancelled'], true);
}

function operation_code(string $value): string {
    if (!preg_match('/^[a-z][a-z0-9_]{0,63}$/', $value)) operation_fail('operation code is invalid');
    return $value;
}

function operation_output_source(string $value): string {
    if (!in_array($value, ['none', 'compatibility_log', 'provisioning_log', 'image_build_log'], true)) {
        operation_fail('operation output source is invalid');
    }
    return $value;
}

function operation_safe_text(string $value, string $name, int $maximum): string {
    if (strlen($value) > $maximum || preg_match('//u', $value) !== 1 || preg_match('/[\x00-\x1f\x7f]/', $value)) {
        operation_fail($name . ' is invalid');
    }
    return $value;
}

function operation_redact(string $value): string {
    $value = preg_replace('/-----BEGIN [^-\r\n]{1,80}-----.*?-----END [^-\r\n]{1,80}-----/s', '[REDACTED PEM]', $value) ?? '';
    $value = preg_replace('/(github_pat_|gh[pousr]_)[A-Za-z0-9_]{8,}/', '[REDACTED]', $value) ?? '';
    $value = preg_replace('/([Aa]uthorization|registrationToken|runnerRequestId|access[_-]?token|registry[_-]?token|password|secret)["=: ]+([Bb]earer[[:space:]]+)?[A-Za-z0-9._+\/=:-]{8,}/i', '$1=[REDACTED]', $value) ?? '';
    $value = preg_replace('/[Bb]earer[[:space:]]+[A-Za-z0-9._+\/=:-]{8,}/', 'Bearer [REDACTED]', $value) ?? '';
    $value = preg_replace('/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/', '', $value) ?? '';
    return $value;
}

function operation_timestamp(string $value, string $name, bool $nullable = false): ?string {
    if ($nullable && $value === '') return null;
    $parsed = DateTimeImmutable::createFromFormat(DateTimeInterface::ATOM, $value);
    $errors = DateTimeImmutable::getLastErrors();
    if (!$parsed || ($errors !== false && ($errors['warning_count'] > 0 || $errors['error_count'] > 0))) {
        operation_fail($name . ' is invalid');
    }
    return $value;
}

function operation_now(): string {
    return gmdate('c');
}

function operation_worker(?array $worker): ?array {
    if ($worker === null) return null;
    $keys = array_keys($worker);
    sort($keys);
    if ($keys !== ['boot_id', 'pid', 'start_ticks']) operation_fail('worker shape is invalid');
    $bootId = operation_safe_text((string)$worker['boot_id'], 'worker boot id', 128);
    if (!preg_match('/^[A-Za-z0-9._:-]{8,128}$/', $bootId)) operation_fail('worker boot id is invalid');
    $pid = $worker['pid'];
    $ticks = $worker['start_ticks'];
    if (!is_int($pid) || $pid < 1 || $pid > 4194304) operation_fail('worker pid is invalid');
    if (!is_string($ticks) || !preg_match('/^[1-9][0-9]{0,20}$/', $ticks)) operation_fail('worker start ticks are invalid');
    return ['boot_id' => $bootId, 'pid' => $pid, 'start_ticks' => $ticks];
}

function operation_output(array $output): array {
    if (count($output) > CRF_OPERATION_OUTPUT_MAX_LINES) operation_fail('operation output has too many lines');
    $bytes = 0;
    $normalized = [];
    foreach ($output as $line) {
        if (!is_string($line)) operation_fail('operation output line is invalid');
        $line = operation_safe_text($line, 'operation output line', 512);
        $lineBytes = strlen($line) + ($normalized === [] ? 0 : 1);
        if ($bytes + $lineBytes > CRF_OPERATION_OUTPUT_MAX_BYTES) operation_fail('operation output is too large');
        $normalized[] = $line;
        $bytes += $lineBytes;
    }
    return $normalized;
}

function operation_record(array $record, ?string $expectedId = null): array {
    $keys = array_keys($record);
    sort($keys);
    $expectedKeys = ['code', 'config_revision', 'created_at', 'finished_at', 'kind', 'message', 'operation_id', 'output', 'output_operation_id', 'output_source', 'schema_version', 'state', 'updated_at', 'worker'];
    sort($expectedKeys);
    if ($keys !== $expectedKeys || ($record['schema_version'] ?? null) !== 1) operation_fail('operation record shape is invalid');
    $id = operation_uuid((string)$record['operation_id'], 'operation id');
    if ($expectedId !== null && $id !== operation_uuid($expectedId, 'expected operation id')) operation_fail('operation id does not match filename');
    $kind = operation_kind((string)$record['kind']);
    $state = operation_state((string)$record['state']);
    $code = operation_code((string)$record['code']);
    $message = operation_safe_text((string)$record['message'], 'operation message', CRF_OPERATION_MESSAGE_MAX_BYTES);
    $configRevision = operation_sha((string)$record['config_revision']);
    $createdAt = operation_timestamp((string)$record['created_at'], 'created_at');
    $updatedAt = operation_timestamp((string)$record['updated_at'], 'updated_at');
    $finishedAtRaw = $record['finished_at'];
    if ($finishedAtRaw !== null && !is_string($finishedAtRaw)) operation_fail('finished_at is invalid');
    $finishedAt = $finishedAtRaw === null ? null : operation_timestamp($finishedAtRaw, 'finished_at');
    $createdEpoch = strtotime($createdAt);
    $updatedEpoch = strtotime($updatedAt);
    $finishedEpoch = $finishedAt === null ? null : strtotime($finishedAt);
    if ($createdEpoch === false || $updatedEpoch === false || $updatedEpoch < $createdEpoch ||
        ($finishedEpoch !== null && ($finishedEpoch === false || $finishedEpoch < $updatedEpoch))) {
        operation_fail('operation timestamps are inconsistent');
    }
    $source = operation_output_source((string)$record['output_source']);
    $outputOperationId = operation_uuid((string)$record['output_operation_id'], 'output operation id');
    if ($outputOperationId !== $id) operation_fail('output operation id does not match operation id');
    if (!is_array($record['output'])) operation_fail('operation output is invalid');
    $output = operation_output($record['output']);
    $worker = is_array($record['worker']) || $record['worker'] === null ? operation_worker($record['worker']) : operation_fail('worker is invalid');
    if (operation_terminal($state) !== ($finishedAt !== null)) operation_fail('terminal timestamp is inconsistent');
    if ($state === 'queued' && $worker !== null) operation_fail('queued operation cannot have a worker');
    if ($state === 'running' && $worker === null) operation_fail('running operation requires a worker');
    if (!operation_terminal($state) && $output !== []) operation_fail('non-terminal operation cannot have terminal output');
    return [
        'schema_version' => 1,
        'operation_id' => $id,
        'kind' => $kind,
        'state' => $state,
        'code' => $code,
        'message' => $message,
        'config_revision' => $configRevision,
        'created_at' => $createdAt,
        'updated_at' => $updatedAt,
        'finished_at' => $finishedAt,
        'output_source' => $source,
        'output_operation_id' => $outputOperationId,
        'output' => $output,
        'worker' => $worker,
    ];
}

function operation_read_file(string $path, string $expectedId): array {
    if (!is_file($path) || is_link($path)) operation_fail('operation record must be a regular non-symlink file');
    $size = filesize($path);
    $mode = fileperms($path);
    if (!is_int($size) || $size < 2 || $size > CRF_OPERATION_RECORD_MAX_BYTES) operation_fail('operation record size is invalid');
    if (!is_int($mode) || (($mode & 0777) !== 0600)) operation_fail('operation record mode must be 0600');
    $raw = file_get_contents($path);
    if (!is_string($raw) || preg_match('//u', $raw) !== 1 || str_contains($raw, chr(0))) operation_fail('operation record is not valid UTF-8');
    try {
        $decoded = json_decode($raw, true, 64, JSON_THROW_ON_ERROR);
    } catch (JsonException) {
        operation_fail('operation record is not valid JSON');
    }
    if (!is_array($decoded)) operation_fail('operation record root is invalid');
    return operation_record($decoded, $expectedId);
}

function operation_write_file(string $path, array $record): void {
    $record = operation_record($record, (string)$record['operation_id']);
    try {
        $encoded = json_encode($record, JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES);
    } catch (JsonException) {
        operation_fail('operation record could not be encoded');
    }
    if (strlen($encoded) + 1 > CRF_OPERATION_RECORD_MAX_BYTES) operation_fail('operation record is too large');
    if (file_put_contents($path, $encoded . PHP_EOL, LOCK_EX) === false) operation_fail('operation record could not be written');
}

function operation_summary(string $path): array {
    if ($path === '') return [];
    if (!is_file($path) || is_link($path)) operation_fail('operation summary must be a regular non-symlink file');
    $size = filesize($path);
    $mode = fileperms($path);
    if (!is_int($size) || $size > 65536 || !is_int($mode) || (($mode & 0777) !== 0600)) operation_fail('operation summary file is unsafe');
    $raw = file_get_contents($path);
    if (!is_string($raw) || preg_match('//u', $raw) !== 1 || str_contains($raw, chr(0))) operation_fail('operation summary is invalid');
    $raw = str_replace(chr(13) . chr(10), chr(10), $raw);
    $raw = operation_redact(str_replace(chr(13), chr(10), $raw));
    $lines = array_values(array_filter(array_map('rtrim', explode(chr(10), $raw)), static fn(string $line): bool => $line !== ''));
    $lines = array_slice($lines, -CRF_OPERATION_OUTPUT_MAX_LINES);
    $kept = [];
    $bytes = 0;
    for ($index = count($lines) - 1; $index >= 0; --$index) {
        $line = $lines[$index];
        if (strlen($line) > 512) $line = substr($line, 0, 512);
        while ($line !== '' && preg_match('//u', $line) !== 1) $line = substr($line, 0, -1);
        $lineBytes = strlen($line) + ($kept === [] ? 0 : 1);
        if ($bytes + $lineBytes > CRF_OPERATION_OUTPUT_MAX_BYTES) break;
        $kept[] = operation_safe_text($line, 'operation summary line', 512);
        $bytes += $lineBytes;
    }
    return array_reverse($kept);
}

function operation_public(array $record): array {
    return [
        'schema_version' => 1,
        'operation_id' => $record['operation_id'],
        'kind' => $record['kind'],
        'state' => $record['state'],
        'code' => $record['code'],
        'message' => $record['message'],
        'config_revision' => $record['config_revision'],
        'created_at' => $record['created_at'],
        'updated_at' => $record['updated_at'],
        'finished_at' => $record['finished_at'],
        'output' => $record['output'],
    ];
}

if ($argc < 2) operation_fail('operation-record action is required');
$action = $argv[1];
if ($action === 'create' && $argc === 7) {
    $path = $argv[2];
    $id = operation_uuid($argv[3], 'operation id');
    $kind = operation_kind($argv[4]);
    $configRevision = operation_sha($argv[5]);
    $source = operation_output_source($argv[6]);
    $now = operation_now();
    operation_write_file($path, [
        'schema_version' => 1,
        'operation_id' => $id,
        'kind' => $kind,
        'state' => 'queued',
        'code' => 'queued',
        'message' => 'Operation queued.',
        'config_revision' => $configRevision,
        'created_at' => $now,
        'updated_at' => $now,
        'finished_at' => null,
        'output_source' => $source,
        'output_operation_id' => $id,
        'output' => [],
        'worker' => null,
    ]);
    exit(0);
}
if ($action === 'transition' && $argc === 11) {
    $existing = operation_read_file($argv[2], $argv[4]);
    $target = $argv[3];
    $nextState = operation_state($argv[5]);
    $code = operation_code($argv[6]);
    $message = operation_safe_text(operation_redact($argv[7]), 'operation message', CRF_OPERATION_MESSAGE_MAX_BYTES);
    $bootId = $argv[8];
    $pidText = $argv[9];
    $ticks = $argv[10];
    $allowed = match ($existing['state']) {
        'queued' => ['running', 'failed', 'cancelled'],
        'running' => ['succeeded', 'failed', 'cancelled'],
        default => [],
    };
    if (!in_array($nextState, $allowed, true)) operation_fail('operation state transition is invalid');
    $worker = $existing['worker'];
    if ($nextState === 'running') {
        if (!preg_match('/^[1-9][0-9]{0,6}$/', $pidText)) operation_fail('worker pid is invalid');
        $worker = operation_worker(['boot_id' => $bootId, 'pid' => (int)$pidText, 'start_ticks' => $ticks]);
    }
    $terminal = operation_terminal($nextState);
    $existing['state'] = $nextState;
    $existing['code'] = $code;
    $existing['message'] = $message;
    $existing['updated_at'] = operation_now();
    $existing['finished_at'] = $terminal ? $existing['updated_at'] : null;
    $existing['output'] = $terminal ? operation_summary(getenv('CRF_OPERATION_SUMMARY_FILE') ?: '') : [];
    $existing['worker'] = $worker;
    operation_write_file($target, $existing);
    exit(0);
}
if (in_array($action, ['validate', 'public', 'worker', 'state'], true) && $argc === 4) {
    $record = operation_read_file($argv[2], $argv[3]);
    if ($action === 'validate') $value = $record;
    elseif ($action === 'public') $value = operation_public($record);
    elseif ($action === 'state') { echo $record['state'], PHP_EOL; exit(0); }
    else {
        echo $record['state'], PHP_EOL;
        if ($record['worker'] !== null) {
            echo $record['worker']['boot_id'], PHP_EOL, $record['worker']['pid'], PHP_EOL, $record['worker']['start_ticks'], PHP_EOL;
        }
        exit(0);
    }
    echo json_encode($value, JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR), PHP_EOL;
    exit(0);
}
operation_fail('operation-record invocation is invalid');
