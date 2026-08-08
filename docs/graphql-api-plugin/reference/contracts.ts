/**
 * Process-boundary and permission contracts for unraid-api-plugin-ci-runner-farm.
 *
 * The GraphQL adapter selects a named operation. Resolvers never provide an
 * executable, verb, path, timeout, or arbitrary argument vector.
 */

export const RUNNER_FARM_SCRIPT =
    '/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh' as const;
export const RUNNER_FARM_CONFIG_CLI =
    '/usr/local/emhttp/plugins/ci-runner-farm/include/config-cli.php' as const;
export const RUNNER_FARM_SECRET_CLI =
    '/usr/local/emhttp/plugins/ci-runner-farm/include/secret-cli.php' as const;
export const PHP_BINARY = '/usr/bin/php' as const;

export const API_SCHEMA_VERSION = 1 as const;
export const MAX_REQUEST_BYTES = 1 << 20;
export const MAX_RESPONSE_BYTES = 1 << 20;
export const MAX_LOG_BYTES = 64 << 10;
export const MAX_GITHUB_PAT_BYTES = 255;
export const MAX_GITHUB_APP_PRIVATE_KEY_BYTES = 32 << 10;
export const MAX_REGISTRY_TOKEN_BYTES = 4 << 10;
export const MAX_DOCKERFILE_BYTES = 1 << 20;
export const DEFAULT_QUERY_TIMEOUT_MS = 15_000;
export const DEFAULT_MUTATION_TIMEOUT_MS = 30_000;
export const LONG_MUTATION_TIMEOUT_MS = 180_000;

export type UnraidResource = 'DOCKER' | 'CONFIG' | 'LOGS';
export type UnraidAction = 'READ_ANY' | 'UPDATE_ANY' | 'DELETE_ANY';

export interface PermissionRequirement {
    action: UnraidAction;
    resource: UnraidResource;
}

export const RUNNER_FARM_PERMISSIONS = {
    runnerFarmStatus: { action: 'READ_ANY', resource: 'DOCKER' },
    runnerFarmReadiness: { action: 'READ_ANY', resource: 'DOCKER' },
    runnerFarmConfiguration: { action: 'READ_ANY', resource: 'CONFIG' },
    runnerFarmQueue: { action: 'READ_ANY', resource: 'DOCKER' },
    runnerFarmRunStatistics: { action: 'READ_ANY', resource: 'DOCKER' },
    runnerFarmCacheUsage: { action: 'READ_ANY', resource: 'DOCKER' },
    runnerFarmImage: { action: 'READ_ANY', resource: 'DOCKER' },
    runnerFarmDockerfile: { action: 'READ_ANY', resource: 'CONFIG' },
    runnerFarmOperation: { action: 'READ_ANY', resource: 'DOCKER' },
    runnerFarmRunnerLog: { action: 'READ_ANY', resource: 'LOGS' },
    runnerFarmHistoryLog: { action: 'READ_ANY', resource: 'LOGS' },
    runnerFarmControllerLog: { action: 'READ_ANY', resource: 'LOGS' },
    runnerFarmStart: { action: 'UPDATE_ANY', resource: 'DOCKER' },
    runnerFarmStop: { action: 'UPDATE_ANY', resource: 'DOCKER' },
    runnerFarmRestart: { action: 'UPDATE_ANY', resource: 'DOCKER' },
    runnerFarmScale: { action: 'UPDATE_ANY', resource: 'DOCKER' },
    runnerFarmPrewarm: { action: 'UPDATE_ANY', resource: 'DOCKER' },
    runnerFarmRecycle: { action: 'UPDATE_ANY', resource: 'DOCKER' },
    runnerFarmSetMaintenance: { action: 'UPDATE_ANY', resource: 'DOCKER' },
    runnerFarmApplyConfiguration: { action: 'UPDATE_ANY', resource: 'CONFIG' },
    runnerFarmValidateConfiguration: { action: 'UPDATE_ANY', resource: 'CONFIG' },
    runnerFarmSetGithubPat: { action: 'UPDATE_ANY', resource: 'CONFIG' },
    runnerFarmClearGithubPat: { action: 'UPDATE_ANY', resource: 'CONFIG' },
    runnerFarmSetGithubAppPrivateKey: { action: 'UPDATE_ANY', resource: 'CONFIG' },
    runnerFarmClearGithubAppPrivateKey: { action: 'UPDATE_ANY', resource: 'CONFIG' },
    runnerFarmSetRegistryToken: { action: 'UPDATE_ANY', resource: 'CONFIG' },
    runnerFarmClearRegistryToken: { action: 'UPDATE_ANY', resource: 'CONFIG' },
    runnerFarmSaveDockerfile: { action: 'UPDATE_ANY', resource: 'CONFIG' },
    runnerFarmStartImageBuild: { action: 'UPDATE_ANY', resource: 'DOCKER' },
    runnerFarmStartProvisioningValidation: { action: 'UPDATE_ANY', resource: 'DOCKER' },
    runnerFarmStartCompatibilityTest: { action: 'UPDATE_ANY', resource: 'CONFIG' },
    runnerFarmBeginBackendMigration: { action: 'UPDATE_ANY', resource: 'CONFIG' },
    runnerFarmRollbackBackend: { action: 'UPDATE_ANY', resource: 'CONFIG' },
    runnerFarmCancelQueuedRun: { action: 'UPDATE_ANY', resource: 'DOCKER' },
    runnerFarmClearPackageCaches: { action: 'DELETE_ANY', resource: 'DOCKER' },
    runnerFarmStatusUpdates: { action: 'READ_ANY', resource: 'DOCKER' },
    runnerFarmOperationUpdates: { action: 'READ_ANY', resource: 'DOCKER' },
} as const satisfies Record<string, PermissionRequirement>;

export type RunnerFarmOperationName =
    | 'status'
    | 'readiness'
    | 'configuration-read'
    | 'queue'
    | 'statistics'
    | 'cache-usage'
    | 'image-info'
    | 'dockerfile-read'
    | 'operation-read'
    | 'runner-log'
    | 'history-log'
    | 'controller-log'
    | 'start'
    | 'stop'
    | 'restart'
    | 'scale'
    | 'prewarm'
    | 'recycle'
    | 'maintenance'
    | 'configuration-apply'
    | 'configuration-validate'
    | 'dockerfile-save'
    | 'image-build-start'
    | 'provisioning-validation-start'
    | 'compatibility-test-start'
    | 'backend-migration-start'
    | 'backend-rollback'
    | 'queue-cancel'
    | 'cache-clear';

export interface CommandSpec {
    executable: typeof RUNNER_FARM_SCRIPT | typeof PHP_BINARY;
    args: readonly string[];
    timeoutMs: number;
    maxStdoutBytes: number;
    maxStderrBytes: number;
    stdin: 'none' | 'json' | 'secret';
    mutating: boolean;
}

const shell = (
    verb: string,
    options: Partial<Omit<CommandSpec, 'executable' | 'args'>> = {}
): CommandSpec => ({
    executable: RUNNER_FARM_SCRIPT,
    args: ['api', verb],
    timeoutMs: DEFAULT_QUERY_TIMEOUT_MS,
    maxStdoutBytes: MAX_RESPONSE_BYTES,
    maxStderrBytes: MAX_LOG_BYTES,
    stdin: 'none',
    mutating: false,
    ...options,
});

const php = (
    script: typeof RUNNER_FARM_CONFIG_CLI,
    verb: string,
    options: Partial<Omit<CommandSpec, 'executable' | 'args'>> = {}
): CommandSpec => ({
    executable: PHP_BINARY,
    args: [script, verb],
    timeoutMs: DEFAULT_QUERY_TIMEOUT_MS,
    maxStdoutBytes: MAX_RESPONSE_BYTES,
    maxStderrBytes: MAX_LOG_BYTES,
    stdin: 'json',
    mutating: false,
    ...options,
});

export const COMMAND_SPECS: Record<RunnerFarmOperationName, CommandSpec> = {
    status: shell('status'),
    readiness: shell('readiness'),
    'configuration-read': php(RUNNER_FARM_CONFIG_CLI, 'read', { stdin: 'none' }),
    queue: shell('queue'),
    statistics: shell('statistics'),
    'cache-usage': shell('cache-usage'),
    'image-info': shell('image-info'),
    'dockerfile-read': php(RUNNER_FARM_CONFIG_CLI, 'dockerfile-read', { stdin: 'none' }),
    'operation-read': shell('operation-read', { stdin: 'json' }),
    'runner-log': shell('runner-log', { stdin: 'json', maxStdoutBytes: MAX_LOG_BYTES }),
    'history-log': shell('history-log', { stdin: 'json', maxStdoutBytes: MAX_LOG_BYTES }),
    'controller-log': shell('controller-log', { stdin: 'json', maxStdoutBytes: MAX_LOG_BYTES }),
    start: shell('start', { stdin: 'json', mutating: true, timeoutMs: LONG_MUTATION_TIMEOUT_MS }),
    stop: shell('stop', { stdin: 'json', mutating: true, timeoutMs: LONG_MUTATION_TIMEOUT_MS }),
    restart: shell('restart', { stdin: 'json', mutating: true, timeoutMs: LONG_MUTATION_TIMEOUT_MS }),
    scale: shell('scale', { stdin: 'json', mutating: true, timeoutMs: LONG_MUTATION_TIMEOUT_MS }),
    prewarm: shell('prewarm', { stdin: 'json', mutating: true, timeoutMs: DEFAULT_MUTATION_TIMEOUT_MS }),
    recycle: shell('recycle', { stdin: 'json', mutating: true, timeoutMs: LONG_MUTATION_TIMEOUT_MS }),
    maintenance: shell('maintenance', { stdin: 'json', mutating: true, timeoutMs: DEFAULT_MUTATION_TIMEOUT_MS }),
    'configuration-apply': php(RUNNER_FARM_CONFIG_CLI, 'apply', {
        mutating: true,
        timeoutMs: LONG_MUTATION_TIMEOUT_MS,
    }),
    'configuration-validate': php(RUNNER_FARM_CONFIG_CLI, 'validate', {
        timeoutMs: DEFAULT_MUTATION_TIMEOUT_MS,
    }),
    'dockerfile-save': php(RUNNER_FARM_CONFIG_CLI, 'dockerfile-save', {
        mutating: true,
        timeoutMs: DEFAULT_MUTATION_TIMEOUT_MS,
    }),
    'image-build-start': shell('image-build-start', { stdin: 'json', mutating: true }),
    'provisioning-validation-start': shell('provisioning-validation-start', {
        stdin: 'json',
        mutating: true,
        timeoutMs: DEFAULT_MUTATION_TIMEOUT_MS,
    }),
    'compatibility-test-start': shell('compatibility-test-start', {
        stdin: 'json',
        mutating: true,
        timeoutMs: DEFAULT_MUTATION_TIMEOUT_MS,
    }),
    'backend-migration-start': shell('backend-migration-start', {
        stdin: 'json',
        mutating: true,
        timeoutMs: LONG_MUTATION_TIMEOUT_MS,
    }),
    'backend-rollback': shell('backend-rollback', {
        stdin: 'json',
        mutating: true,
        timeoutMs: LONG_MUTATION_TIMEOUT_MS,
    }),
    'queue-cancel': shell('queue-cancel', {
        stdin: 'json',
        mutating: true,
        timeoutMs: DEFAULT_MUTATION_TIMEOUT_MS,
    }),
    'cache-clear': shell('cache-clear', {
        stdin: 'json',
        mutating: true,
        timeoutMs: LONG_MUTATION_TIMEOUT_MS,
    }),
};

export const SECRET_COMMANDS = {
    setGithubPat: {
        argv: [PHP_BINARY, RUNNER_FARM_SECRET_CLI, 'set-github-pat'] as const,
        maxSecretBytes: MAX_GITHUB_PAT_BYTES,
        maxRequestBytes: MAX_GITHUB_PAT_BYTES * 6 + 1024,
    },
    clearGithubPat: {
        argv: [PHP_BINARY, RUNNER_FARM_SECRET_CLI, 'clear-github-pat'] as const,
        maxSecretBytes: 0,
        maxRequestBytes: 512,
    },
    setGithubAppPrivateKey: {
        argv: [PHP_BINARY, RUNNER_FARM_SECRET_CLI, 'set-github-app-private-key'] as const,
        maxSecretBytes: MAX_GITHUB_APP_PRIVATE_KEY_BYTES,
        maxRequestBytes: MAX_GITHUB_APP_PRIVATE_KEY_BYTES * 6 + 1024,
    },
    clearGithubAppPrivateKey: {
        argv: [PHP_BINARY, RUNNER_FARM_SECRET_CLI, 'clear-github-app-private-key'] as const,
        maxSecretBytes: 0,
        maxRequestBytes: 512,
    },
    setRegistryToken: {
        argv: [PHP_BINARY, RUNNER_FARM_SECRET_CLI, 'set-registry-token'] as const,
        maxSecretBytes: MAX_REGISTRY_TOKEN_BYTES,
        maxRequestBytes: MAX_REGISTRY_TOKEN_BYTES * 6 + 1024,
    },
    clearRegistryToken: {
        argv: [PHP_BINARY, RUNNER_FARM_SECRET_CLI, 'clear-registry-token'] as const,
        maxSecretBytes: 0,
        maxRequestBytes: 512,
    },
} as const;

export const DOMAIN_ERROR_CODES = [
    'ok',
    'invalid_request',
    'invalid_revision',
    'stale_config',
    'stale_inventory',
    'stale_credential',
    'stale_dockerfile',
    'stale_transition',
    'ownership_changed',
    'compatibility_changed',
    'invalid_config',
    'invalid_pool',
    'invalid_runner',
    'backend_transition_in_progress',
    'backend_not_ready',
    'resource_capacity',
    'operation_not_found',
    'operation_running',
    'operation_interrupted',
    'secret_validation_failed',
    'secret_write_failed',
    'backend_unavailable',
    'unsupported_schema',
    'timeout',
    'output_too_large',
] as const;

export type RunnerFarmDomainErrorCode = (typeof DOMAIN_ERROR_CODES)[number];
