<?php
declare(strict_types=1);

const RUNNER_API_LOG_INPUT_MAX_BYTES = 1048576;
const RUNNER_API_LOG_CONTENT_MAX_BYTES = 65536;

function log_fail(string $message, int $exitCode = 5): never {
    fwrite(STDERR, $message . PHP_EOL);
    exit($exitCode);
}

function log_safe_source(string $value): string {
    if ($value === '' || strlen($value) > 160 || preg_match('/[\x00-\x1f\x7f]/', $value)) {
        log_fail('log source is invalid');
    }
    return $value;
}

function log_private_bytes(string $path): string {
    if (!is_file($path) || is_link($path)) log_fail('log input must be a regular non-symlink file');
    $size = filesize($path);
    $mode = fileperms($path);
    if (!is_int($size) || $size < 0) log_fail('log input size is invalid');
    if ($size > RUNNER_API_LOG_INPUT_MAX_BYTES) log_fail('log input is too large', 7);
    if (!is_int($mode) || (($mode & 0777) !== 0600)) log_fail('log input mode must be 0600');
    $raw = file_get_contents($path);
    if (!is_string($raw) || preg_match('//u', $raw) !== 1 || str_contains($raw, chr(0))) {
        log_fail('log input must be UTF-8 without NUL');
    }
    return $raw;
}

function log_json_content(string $raw): string {
    try {
        $value = json_decode($raw, true, 16, JSON_THROW_ON_ERROR);
    } catch (JsonException) {
        log_fail('log JSON is invalid');
    }
    if (!is_array($value)) log_fail('log JSON root is invalid');
    $keys = array_keys($value);
    sort($keys);
    if ($keys !== ['log', 'ok'] || ($value['ok'] ?? null) !== true || !is_string($value['log'] ?? null)) {
        log_fail('log JSON shape is invalid');
    }
    return $value['log'];
}

function log_redact(string $content): string {
    $content = str_replace(chr(13) . chr(10), chr(10), $content);
    $content = str_replace(chr(13), chr(10), $content);
    $content = preg_replace('/\x1B\[[0-?]*[ -\/]*[@-~]/', '', $content) ?? '';
    $content = preg_replace('/-----BEGIN [^-\r\n]{1,80}-----.*?-----END [^-\r\n]{1,80}-----/s', '[REDACTED PEM]', $content) ?? '';
    $content = preg_replace('/(github_pat_|gh[pousr]_)[A-Za-z0-9_]{8,}/', '[REDACTED]', $content) ?? '';
    $content = preg_replace('/([Aa]uthorization|registrationToken|runnerRequestId|access[_-]?token|registry[_-]?token|password|secret)["=: ]+([Bb]earer[[:space:]]+)?[A-Za-z0-9._+\/=:-]{8,}/i', '$1=[REDACTED]', $content) ?? '';
    $content = preg_replace('/[Bb]earer[[:space:]]+[A-Za-z0-9._+\/=:-]{8,}/', 'Bearer [REDACTED]', $content) ?? '';
    $content = preg_replace('/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/', '', $content) ?? '';
    return $content;
}

function utf8_suffix(string $value, int $maximumBytes): string {
    if (strlen($value) <= $maximumBytes) return $value;
    $candidate = substr($value, -$maximumBytes);
    while ($candidate !== '' && preg_match('//u', $candidate) !== 1) $candidate = substr($candidate, 1);
    return $candidate;
}

function log_tail(string $content, int $requestedLines): array {
    $content = log_redact($content);
    $content = rtrim($content, chr(10));
    $all = $content === '' ? [] : explode(chr(10), $content);
    $selected = array_slice($all, -$requestedLines);
    $truncated = count($all) > count($selected);
    $kept = [];
    $bytes = 0;
    for ($index = count($selected) - 1; $index >= 0; --$index) {
        $line = $selected[$index];
        $separatorBytes = count($kept) > 0 ? 1 : 0;
        $lineBytes = strlen($line) + $separatorBytes;
        if ($lineBytes + $bytes > RUNNER_API_LOG_CONTENT_MAX_BYTES) {
            $truncated = true;
            if (count($kept) === 0) {
                $line = utf8_suffix($line, RUNNER_API_LOG_CONTENT_MAX_BYTES);
                if ($line !== '') $kept[] = $line;
            }
            break;
        }
        $kept[] = $line;
        $bytes += $lineBytes;
    }
    $kept = array_reverse($kept);
    $result = implode(chr(10), $kept);
    if (strlen($result) > RUNNER_API_LOG_CONTENT_MAX_BYTES || preg_match('//u', $result) !== 1) {
        log_fail('normalized log exceeded its byte contract');
    }
    return [$result, $truncated];
}

if ($argc !== 5 || !in_array($argv[1], ['plain', 'json'], true)) {
    log_fail('usage: api-log.php plain|json file lines source');
}
$mode = $argv[1];
$path = $argv[2];
$linesText = $argv[3];
$source = log_safe_source($argv[4]);
if (!preg_match('/^[1-9][0-9]{0,2}$/', $linesText)) log_fail('requested lines are invalid');
$lines = (int)$linesText;
if ($lines < 1 || $lines > 500) log_fail('requested lines are outside supported bounds');
$raw = log_private_bytes($path);
$content = $mode === 'json' ? log_json_content($raw) : $raw;
[$content, $truncated] = log_tail($content, $lines);
try {
    $encoded = json_encode([
        'source' => $source,
        'content' => $content,
        'truncated' => $truncated,
    ], JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES);
} catch (JsonException) {
    log_fail('could not encode normalized log');
}
if (strlen($encoded) + 1 > RUNNER_API_LOG_INPUT_MAX_BYTES) log_fail('normalized log envelope is too large', 7);
echo $encoded, PHP_EOL;
