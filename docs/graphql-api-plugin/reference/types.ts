/**
 * CI Runner Farm GraphQL plugin type contract.
 *
 * These are implementation-ready reference types. Move them into
 * packages/unraid-api-plugin-ci-runner-farm/src/contracts/types.ts when the package
 * is scaffolded. Raw types cover the current schema-v2 shell JSON plus the exact,
 * non-lossy additions required from the strict local API. Public types are normalized
 * for GraphQL and must never expose secret values.
 */

export type Brand<T, Name extends string> = T & { readonly __brand: Name };

export type Sha256 = Brand<string, 'Sha256'>;
export type Uuid = Brand<string, 'Uuid'>;
export type RunnerName = Brand<string, 'RunnerName'>;
export type PoolId = Brand<string, 'PoolId'>;
export type RepositoryName = Brand<string, 'RepositoryName'>;
export type WorkflowRunId = Brand<string, 'WorkflowRunId'>;
export type JobId = Brand<string, 'JobId'>;
export type EpochSeconds = Brand<number, 'EpochSeconds'>;
export type CpuMilli = Brand<bigint, 'CpuMilli'>;
export type ByteCount = Brand<bigint, 'ByteCount'>;

export const SHA256_PATTERN = /^[0-9a-f]{64}$/;
export const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export const POOL_ID_PATTERN = /^[a-z](?:[a-z0-9-]{0,22}[a-z0-9])?$/;
export const REPOSITORY_PATTERN = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;
export const RUNNER_NAME_PATTERN = /^ci-runner-(?:[0-9]+|[a-z](?:[a-z0-9-]{0,22}[a-z0-9])?-[0-9]+|jit-[a-z0-9]+(?:-[a-z0-9]+)*-[0-9a-f]{20})$/;

export type RunnerFarmBackend = 'classic' | 'scaleset';
export type RunnerFarmMode = 'single' | 'pools';
export type RunnerFarmAuthMode = 'pat' | 'github_app';
export type RunnerFarmImageSource = 'builtin' | 'remote';
export type RunnerFarmNetworkIsolation = 'off' | 'isolate' | 'strict';

export type RawTransitionPhase =
    | 'classic_active'
    | 'preparing_scaleset_ineligible'
    | 'quiescing_classic'
    | 'classic_ineligible'
    | 'activating_scaleset'
    | 'scaleset_active'
    | 'quiescing_scaleset'
    | 'scaleset_ineligible'
    | 'draining_assigned_jit'
    | 'activating_classic';

export type RawReservationPhase =
    | 'reserved'
    | 'offered'
    | 'assigned'
    | 'acting'
    | 'observed'
    | 'failed'
    | 'expired';

export type RawJitPhase =
    | 'admitted'
    | 'jit_received'
    | 'container_create_started'
    | 'container_observed'
    | 'secret_consumed'
    | 'running'
    | 'terminal'
    | 'deleting'
    | 'deleted'
    | 'failed';

export interface RawBackendState {
    requested: string;
    effective: string;
    transition_phase: string;
    transition_id: string;
    transition_revision: string;
    ownership_revision: string;
}

export interface RawCompatibilityState {
    valid: boolean;
    reason: string;
    record_id?: string;
    tested_at?: string;
    age_seconds?: number;
    helper_digest?: string;
    plugin_digest?: string;
    image_digest?: string;
    entrypoint_digest?: string;
    module_revision?: string;
    go_version?: string;
    runner_group_id?: number;
    runner_group_policy?: string;
    owner?: string;
    auth_mode?: string;
    private_key_configured?: boolean;
}

export interface RawOperationState {
    schema_version: 1;
    operation_id: string;
    kind: string;
    state: string;
    code: string;
    message: string;
    config_revision: string;
    created_at: string;
    updated_at: string;
    finished_at?: string | null;
    output?: string[];
}

export interface RawResourceQuantity {
    budget: number;
    reserve: number;
    reserved: number;
    admissible: number;
}

export interface RawResources {
    available?: boolean;
    reason?: string;
    cpu_milli: RawResourceQuantity;
    memory_bytes: RawResourceQuantity;
}

export interface RawReservation {
    operation_id: string;
    pool_id: string;
    runner_name: string;
    cpu_milli: number;
    memory_bytes: number;
    deadline: number;
    phase: string;
}

export interface RawRecentActivity {
    schema_version: 1;
    observed_at: number;
    completed_at: string;
    runner_name: string;
    pool_id: string;
    work_handle: number | string;
    job: string;
    conclusion: string;
}

export interface RawPoolStatus {
    id: string;
    label: string;
    routing_label?: string;
    additional_labels?: string;
    effective_labels?: string;
    cpu_milli?: number;
    memory_bytes?: number;
    blocked_reason?: string;
    autoscale_enabled: boolean;
    configured: number;
    effective_target: number;
    count: number;
    up: number;
    busy: number;
    idle: number;
    starting: number;
    error: number;
    completed?: number;
    stale: number;
    retiring: number;
    pending: number;
    min: number;
    max: number | 'auto';
    idle_buffer: number;
    assigned_jobs?: number;
    demand_fresh?: boolean;
    desired?: number;
    admitted?: number;
    advertised_capacity?: number;
    lease_age_seconds?: number | null;
    session_healthy?: boolean;
    ownership_state?: string;
    remote_scale_set_id?: number | null;
    tombstone?: boolean;
    orphan?: boolean;
}

export interface RawRunnerStatus {
    name: string;
    pool: string;
    routing_label: string;
    scope_target: string;
    pool_index: number;
    state: string;
    phase: string;
    job: string;
    job_started: string;
    started_at: string;
    repo: string;
    pr: string;
    branch: string;
    run_id: string;
    cpus: number;
    mem_gb: number;
    cpu_milli?: number | null;
    memory_bytes?: number | null;
    cpu_pct: number;
    mem_used_mib: number;
    completed: boolean;
    stale: boolean;
    retiring: boolean;
}

export interface RawStatusV2 {
    schema_version: 2;
    config_revision: string;
    observed_at: number;
    inventory_revision: string;
    backend: RawBackendState;
    compatibility: RawCompatibilityState;
    operation: RawOperationState | null;
    maintenance: boolean;
    resources: RawResources;
    reservations: RawReservation[];
    recent_activity: RawRecentActivity[];
    mode: string;
    config_error: string;
    count: number;
    configured: number;
    token: boolean;
    autoscale_enabled: boolean;
    autoscale_max: number;
    autoscale: string;
    image_autoupdate: string;
    warning: string;
    security: string;
    stale: number;
    retiring: number;
    blocked_capacity: number;
    pools: RawPoolStatus[];
    runners: RawRunnerStatus[];
}

export interface RawReadinessV2 {
    schema_version: 2;
    backend: RawBackendState;
    compatibility: RawCompatibilityState;
    operation: RawOperationState | null;
    count: number | null;
}

export interface RawQueueJob {
    run_id: number | string;
    job_id: number | string;
    repo: string;
    workflow: string;
    labels: string;
    pool: string;
    reason: string;
    created_at: string;
    url: string;
}

export interface RawQueueSnapshot {
    queued: number;
    known_queued: number;
    workflow_runs: number;
    partial: boolean;
    truncated: boolean;
    detail_complete: boolean;
    jobs: RawQueueJob[];
    age: number;
}

export interface RawRunStatistics {
    ok: number;
    fail: number;
    cancel: number;
    other: number;
    total: number;
    age: number;
}

export interface RawCacheUsage {
    total: number;
    pkg: number;
    age: number;
}

export interface RawImageInfo {
    exists: boolean;
    image: string;
    source: string;
    id?: string;
    image_id?: string;
    created?: string;
    size_mb?: number;
    size_bytes?: number;
    base?: string;
    in_use?: number;
    dockerfile?: string;
}

export interface RawBuildStatus {
    ok: boolean;
    running: boolean;
    rc: number | null;
    log: string;
}

export interface RawLogResult {
    ok: boolean;
    log: string;
    error?: string;
}

export interface RawCommandResult<T = unknown> {
    schema_version: 1;
    request_id: string;
    ok: boolean;
    code: string;
    message: string;
    result: T | null;
    observed: {
        config_revision: string;
        inventory_revision: string;
        transition_revision: string;
        ownership_revision: string;
        compatibility_record_id: string;
        credential_revision?: string;
    };
}

export interface RunnerFarmConfigRevisionExpectation {
    configRevision: Sha256;
}

export interface RunnerFarmFleetRevisionExpectation {
    configRevision: Sha256;
    inventoryRevision: Sha256;
}

export interface RunnerFarmCredentialRevisionExpectation {
    configRevision: Sha256;
    credentialRevision: Sha256;
}

export interface RunnerFarmTransitionExpectation {
    configRevision: Sha256;
    ownershipRevision: Sha256;
    compatibilityRecordId: Sha256;
    transitionRevision: Sha256;
}

export interface RunnerFarmPoolPatch {
    id: PoolId;
    routingLabel: string;
    additionalLabels: string[];
    fixed: number;
    min: number;
    max: number | 'auto';
    idleBuffer: number;
    cpuMilli: CpuMilli;
    memoryBytes: ByteCount;
    autoscaleEnabled: boolean;
}

export interface RunnerFarmConfigurationPatch {
    github?: {
        scope?: 'repo' | 'org';
        owner?: string;
        repositories?: RepositoryName[];
        runnerGroup?: string | null;
        authMode?: RunnerFarmAuthMode;
        githubAppId?: string | null;
        githubAppInstallationId?: string | null;
    };
    runners?: {
        mode?: RunnerFarmMode;
        count?: number;
        labels?: string[];
        poolBackend?: RunnerFarmBackend;
        pools?: RunnerFarmPoolPatch[];
        poolAutoscalePolicy?: { mode: 'inherit' | 'explicit'; poolIds: PoolId[] };
        defaultCpuMilli?: CpuMilli | null;
        defaultMemoryBytes?: ByteCount | null;
        ephemeral?: boolean;
        runAsRoot?: boolean;
    };
    resources?: {
        cpuBudgetMilli?: CpuMilli | null;
        memoryBudgetBytes?: ByteCount | null;
        cpuReserveMilli?: CpuMilli;
        memoryReserveBytes?: ByteCount;
        cpuOvercommit?: number;
        memorySwapMode?: 'none' | 'double';
        pidsLimit?: number;
    };
    storage?: {
        cacheRoot?: string;
        workspaceMode?: 'tmpfs' | 'cache_bind';
        workspaceTmpfsBytes?: ByteCount | null;
        cacheMounts?: string[];
    };
    image?: {
        source?: RunnerFarmImageSource;
        image?: string | null;
        registryServer?: string | null;
        registryUsername?: string | null;
    };
    docker?: {
        shareDockerSocket?: boolean;
        dockerInDocker?: boolean;
        sharedImageCache?: boolean;
        networkIsolation?: RunnerFarmNetworkIsolation;
        runnerNetwork?: string;
        mirrorPort?: number;
    };
    autoscaling?: {
        enabled?: boolean;
        min?: number;
        max?: number;
        minIdle?: number;
        step?: number;
        intervalSeconds?: number;
        idleGraceSeconds?: number;
    };
    imageUpdates?: {
        enabled?: boolean;
        intervalSeconds?: number;
        drainTimeoutSeconds?: number;
    };
    dashboardWidgetEnabled?: boolean;
}

export interface RunnerFarmCommandRequest<TInput = Record<string, never>> {
    schema_version: 1;
    request_id: Uuid;
    operation: string;
    expected?: {
        config_revision?: Sha256;
        inventory_revision?: Sha256;
        transition_revision?: Sha256;
        ownership_revision?: Sha256;
        compatibility_record_id?: Sha256;
    };
    input: TInput;
}

export interface RunnerFarmCommandExecution {
    command: string;
    args: readonly string[];
    stdin?: string;
    timeoutMs: number;
    maxStdoutBytes: number;
    maxStderrBytes: number;
}

export interface RunnerFarmCommandExecutor {
    execute<T>(execution: RunnerFarmCommandExecution): Promise<RawCommandResult<T>>;
}

export interface RunnerFarmStatusSource {
    readStatus(): Promise<RawStatusV2>;
    readReadiness(): Promise<RawReadinessV2>;
    readQueue(): Promise<RawQueueSnapshot>;
    readStatistics(): Promise<RawRunStatistics>;
    readCacheUsage(): Promise<RawCacheUsage>;
    readImageInfo(): Promise<RawImageInfo>;
}
