/** Typed configuration output models. Secret values are never represented. */
import { Field, Float, Int, ObjectType } from '@nestjs/graphql';
import { GraphQLBigInt } from 'graphql-scalars';
import { RunnerFarmCredentialPresenceModel } from './common.models.js';
import {
    RunnerFarmAuthMode,
    RunnerFarmBackend,
    RunnerFarmGitHubScope,
    RunnerFarmImageSource,
    RunnerFarmMemorySwapMode,
    RunnerFarmMode,
    RunnerFarmNetworkIsolation,
    RunnerFarmPoolAutoscaleMode,
    RunnerFarmWorkspaceMode,
} from './enums.js';

@ObjectType('RunnerFarmGitHubConfiguration')
export class RunnerFarmGitHubConfigurationModel {
    @Field(() => RunnerFarmGitHubScope)
    scope!: RunnerFarmGitHubScope;
    @Field(() => String)
    owner!: string;
    @Field(() => [String])
    repositories!: string[];
    @Field(() => String, { nullable: true })
    runnerGroup?: string | null;
    @Field(() => RunnerFarmAuthMode)
    authMode!: RunnerFarmAuthMode;
    @Field(() => String, { nullable: true })
    githubAppId?: string | null;
    @Field(() => String, { nullable: true })
    githubAppInstallationId?: string | null;
}

@ObjectType('RunnerFarmPoolConfiguration')
export class RunnerFarmPoolConfigurationModel {
    @Field(() => String)
    id!: string;
    @Field(() => String)
    routingLabel!: string;
    @Field(() => [String])
    additionalLabels!: string[];
    @Field(() => Int)
    fixed!: number;
    @Field(() => Int)
    min!: number;
    @Field(() => Int, { nullable: true })
    max?: number | null;
    @Field(() => Boolean)
    maxAutomatic!: boolean;
    @Field(() => Int)
    idleBuffer!: number;
    @Field(() => GraphQLBigInt)
    cpuMilli!: bigint;
    @Field(() => GraphQLBigInt)
    memoryBytes!: bigint;
    @Field(() => Boolean)
    autoscaleEnabled!: boolean;
}

@ObjectType('RunnerFarmPoolAutoscalePolicy')
export class RunnerFarmPoolAutoscalePolicyModel {
    @Field(() => RunnerFarmPoolAutoscaleMode)
    mode!: RunnerFarmPoolAutoscaleMode;
    @Field(() => [String])
    poolIds!: string[];
}

@ObjectType('RunnerFarmRunnerConfiguration')
export class RunnerFarmRunnerConfigurationModel {
    @Field(() => RunnerFarmMode)
    mode!: RunnerFarmMode;
    @Field(() => Int)
    count!: number;
    @Field(() => [String])
    labels!: string[];
    @Field(() => RunnerFarmBackend)
    poolBackend!: RunnerFarmBackend;
    @Field(() => [RunnerFarmPoolConfigurationModel])
    pools!: RunnerFarmPoolConfigurationModel[];
    @Field(() => RunnerFarmPoolAutoscalePolicyModel)
    poolAutoscalePolicy!: RunnerFarmPoolAutoscalePolicyModel;
    @Field(() => GraphQLBigInt, { nullable: true })
    defaultCpuMilli?: bigint | null;
    @Field(() => GraphQLBigInt, { nullable: true })
    defaultMemoryBytes?: bigint | null;
    @Field(() => Boolean)
    ephemeral!: boolean;
    @Field(() => Boolean)
    runAsRoot!: boolean;
}

@ObjectType('RunnerFarmResourceConfiguration')
export class RunnerFarmResourceConfigurationModel {
    @Field(() => GraphQLBigInt, { nullable: true })
    cpuBudgetMilli?: bigint | null;
    @Field(() => GraphQLBigInt, { nullable: true })
    memoryBudgetBytes?: bigint | null;
    @Field(() => GraphQLBigInt)
    cpuReserveMilli!: bigint;
    @Field(() => GraphQLBigInt)
    memoryReserveBytes!: bigint;
    @Field(() => Float)
    cpuOvercommit!: number;
    @Field(() => RunnerFarmMemorySwapMode)
    memorySwapMode!: RunnerFarmMemorySwapMode;
    @Field(() => Int)
    pidsLimit!: number;
}

@ObjectType('RunnerFarmStorageConfiguration')
export class RunnerFarmStorageConfigurationModel {
    @Field(() => String)
    cacheRoot!: string;
    @Field(() => RunnerFarmWorkspaceMode)
    workspaceMode!: RunnerFarmWorkspaceMode;
    @Field(() => GraphQLBigInt, { nullable: true })
    workspaceTmpfsBytes?: bigint | null;
    @Field(() => [String])
    cacheMounts!: string[];
}

@ObjectType('RunnerFarmImageConfiguration')
export class RunnerFarmImageConfigurationModel {
    @Field(() => RunnerFarmImageSource)
    source!: RunnerFarmImageSource;
    @Field(() => String)
    image!: string;
    @Field(() => String, { nullable: true })
    registryServer?: string | null;
    @Field(() => String, { nullable: true })
    registryUsername?: string | null;
}

@ObjectType('RunnerFarmDockerConfiguration')
export class RunnerFarmDockerConfigurationModel {
    @Field(() => Boolean)
    shareDockerSocket!: boolean;
    @Field(() => Boolean)
    dockerInDocker!: boolean;
    @Field(() => Boolean)
    sharedImageCache!: boolean;
    @Field(() => RunnerFarmNetworkIsolation)
    networkIsolation!: RunnerFarmNetworkIsolation;
    @Field(() => String)
    runnerNetwork!: string;
    @Field(() => Int)
    mirrorPort!: number;
}

@ObjectType('RunnerFarmAutoscaleConfiguration')
export class RunnerFarmAutoscaleConfigurationModel {
    @Field(() => Boolean)
    enabled!: boolean;
    @Field(() => Int)
    min!: number;
    @Field(() => Int)
    max!: number;
    @Field(() => Int)
    minIdle!: number;
    @Field(() => Int)
    step!: number;
    @Field(() => Int)
    intervalSeconds!: number;
    @Field(() => Int)
    idleGraceSeconds!: number;
}

@ObjectType('RunnerFarmImageUpdateConfiguration')
export class RunnerFarmImageUpdateConfigurationModel {
    @Field(() => Boolean)
    enabled!: boolean;
    @Field(() => Int)
    intervalSeconds!: number;
    @Field(() => Int)
    drainTimeoutSeconds!: number;
}

@ObjectType('RunnerFarmConfiguration')
export class RunnerFarmConfigurationModel {
    @Field(() => RunnerFarmGitHubConfigurationModel)
    github!: RunnerFarmGitHubConfigurationModel;
    @Field(() => RunnerFarmRunnerConfigurationModel)
    runners!: RunnerFarmRunnerConfigurationModel;
    @Field(() => RunnerFarmResourceConfigurationModel)
    resources!: RunnerFarmResourceConfigurationModel;
    @Field(() => RunnerFarmStorageConfigurationModel)
    storage!: RunnerFarmStorageConfigurationModel;
    @Field(() => RunnerFarmImageConfigurationModel)
    image!: RunnerFarmImageConfigurationModel;
    @Field(() => RunnerFarmDockerConfigurationModel)
    docker!: RunnerFarmDockerConfigurationModel;
    @Field(() => RunnerFarmAutoscaleConfigurationModel)
    autoscaling!: RunnerFarmAutoscaleConfigurationModel;
    @Field(() => RunnerFarmImageUpdateConfigurationModel)
    imageUpdates!: RunnerFarmImageUpdateConfigurationModel;
    @Field(() => Boolean)
    dashboardWidgetEnabled!: boolean;
}

@ObjectType('RunnerFarmRawSetting')
export class RunnerFarmRawSettingModel {
    @Field(() => String)
    key!: string;
    @Field(() => String)
    value!: string;
}

@ObjectType('RunnerFarmValidationIssue')
export class RunnerFarmValidationIssueModel {
    @Field(() => String)
    path!: string;
    @Field(() => String)
    code!: string;
    @Field(() => String)
    message!: string;
}

@ObjectType('RunnerFarmConfigurationSnapshot')
export class RunnerFarmConfigurationSnapshotModel {
    @Field(() => String)
    revision!: string;
    @Field(() => Boolean)
    valid!: boolean;
    @Field(() => [RunnerFarmValidationIssueModel])
    issues!: RunnerFarmValidationIssueModel[];
    @Field(() => RunnerFarmConfigurationModel, { nullable: true })
    configuration?: RunnerFarmConfigurationModel | null;
    @Field(() => [RunnerFarmRawSettingModel])
    rawSettings!: RunnerFarmRawSettingModel[];
    @Field(() => RunnerFarmCredentialPresenceModel)
    credentials!: RunnerFarmCredentialPresenceModel;
}

@ObjectType('RunnerFarmConfigurationValidation')
export class RunnerFarmConfigurationValidationModel {
    @Field(() => Boolean)
    valid!: boolean;
    @Field(() => [RunnerFarmValidationIssueModel])
    issues!: RunnerFarmValidationIssueModel[];
    @Field(() => RunnerFarmConfigurationModel, { nullable: true })
    normalized?: RunnerFarmConfigurationModel | null;
}
