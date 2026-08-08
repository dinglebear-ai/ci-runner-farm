import { registerEnumType } from '@nestjs/graphql';

export enum RunnerFarmBackend {
    CLASSIC = 'CLASSIC',
    SCALESET = 'SCALESET',
}

export enum RunnerFarmBackendStateValue {
    CLASSIC = 'CLASSIC',
    SCALESET = 'SCALESET',
    INVALID = 'INVALID',
}

export enum RunnerFarmMode {
    SINGLE = 'SINGLE',
    POOLS = 'POOLS',
}

export enum RunnerFarmModeState {
    SINGLE = 'SINGLE',
    POOLS = 'POOLS',
    INVALID = 'INVALID',
}

export enum RunnerFarmAuthMode {
    PAT = 'PAT',
    GITHUB_APP = 'GITHUB_APP',
}

export enum RunnerFarmAuthModeState {
    PAT = 'PAT',
    GITHUB_APP = 'GITHUB_APP',
    INVALID = 'INVALID',
}

export enum RunnerFarmGitHubScope {
    REPOSITORY = 'REPOSITORY',
    ORGANIZATION = 'ORGANIZATION',
}

export enum RunnerFarmImageSource {
    BUILTIN = 'BUILTIN',
    REMOTE = 'REMOTE',
}

export enum RunnerFarmNetworkIsolation {
    OFF = 'OFF',
    ISOLATE = 'ISOLATE',
    STRICT = 'STRICT',
}

export enum RunnerFarmWorkspaceMode {
    TMPFS = 'TMPFS',
    CACHE_BIND = 'CACHE_BIND',
}

export enum RunnerFarmPoolAutoscaleMode {
    INHERIT = 'INHERIT',
    EXPLICIT = 'EXPLICIT',
}

export enum RunnerFarmMemorySwapMode {
    NONE = 'NONE',
    DOUBLE = 'DOUBLE',
}

export enum RunnerFarmOperationKind {
    COMPATIBILITY_TEST = 'COMPATIBILITY_TEST',
    PROVISIONING_VALIDATION = 'PROVISIONING_VALIDATION',
    IMAGE_BUILD = 'IMAGE_BUILD',
}

export enum RunnerFarmOperationState {
    QUEUED = 'QUEUED',
    RUNNING = 'RUNNING',
    SUCCEEDED = 'SUCCEEDED',
    FAILED = 'FAILED',
    CANCELLED = 'CANCELLED',
}

export enum RunnerFarmConclusion {
    SUCCESS = 'SUCCESS',
    FAILURE = 'FAILURE',
    CANCELLED = 'CANCELLED',
    UNKNOWN = 'UNKNOWN',
}

export enum RunnerFarmMaintenanceMode {
    BEGIN = 'BEGIN',
    RESUME = 'RESUME',
}

for (const [type, name] of [
    [RunnerFarmBackend, 'RunnerFarmBackend'],
    [RunnerFarmBackendStateValue, 'RunnerFarmBackendStateValue'],
    [RunnerFarmMode, 'RunnerFarmMode'],
    [RunnerFarmModeState, 'RunnerFarmModeState'],
    [RunnerFarmAuthMode, 'RunnerFarmAuthMode'],
    [RunnerFarmAuthModeState, 'RunnerFarmAuthModeState'],
    [RunnerFarmGitHubScope, 'RunnerFarmGitHubScope'],
    [RunnerFarmImageSource, 'RunnerFarmImageSource'],
    [RunnerFarmNetworkIsolation, 'RunnerFarmNetworkIsolation'],
    [RunnerFarmWorkspaceMode, 'RunnerFarmWorkspaceMode'],
    [RunnerFarmPoolAutoscaleMode, 'RunnerFarmPoolAutoscaleMode'],
    [RunnerFarmMemorySwapMode, 'RunnerFarmMemorySwapMode'],
    [RunnerFarmOperationKind, 'RunnerFarmOperationKind'],
    [RunnerFarmOperationState, 'RunnerFarmOperationState'],
    [RunnerFarmConclusion, 'RunnerFarmConclusion'],
    [RunnerFarmMaintenanceMode, 'RunnerFarmMaintenanceMode'],
] as const) {
    registerEnumType(type, { name });
}
