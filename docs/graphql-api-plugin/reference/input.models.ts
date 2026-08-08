/** Code-first mutation and configuration input models. */
import { Field, Float, ID, InputType, Int } from '@nestjs/graphql';
import { Type } from 'class-transformer';
import {
    ArrayMaxSize,
    IsArray,
    IsBoolean,
    IsEnum,
    IsInt,
    IsOptional,
    IsString,
    Matches,
    Max,
    MaxLength,
    Min,
    ValidateNested,
} from 'class-validator';
import { GraphQLBigInt } from 'graphql-scalars';
import {
    RunnerFarmAuthMode,
    RunnerFarmBackend,
    RunnerFarmGitHubScope,
    RunnerFarmImageSource,
    RunnerFarmMaintenanceMode,
    RunnerFarmMemorySwapMode,
    RunnerFarmMode,
    RunnerFarmNetworkIsolation,
    RunnerFarmPoolAutoscaleMode,
    RunnerFarmWorkspaceMode,
} from './enums.js';

const SHA256 = /^[0-9a-f]{64}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const POOL_ID = /^[a-z](?:[a-z0-9-]{0,22}[a-z0-9])?$/;
const REPOSITORY = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;
const RUNNER_NAME = /^ci-runner-(?:[0-9]+|[a-z](?:[a-z0-9-]{0,22}[a-z0-9])?-[0-9]+|jit-[a-z0-9]+(?:-[a-z0-9]+)*-[0-9a-f]{20})$/;

@InputType()
export class RunnerFarmConfigRevisionInput {
    @Field(() => String)
    @Matches(SHA256)
    configRevision!: string;
}

@InputType()
export class RunnerFarmFleetRevisionInput {
    @Field(() => String)
    @Matches(SHA256)
    configRevision!: string;

    @Field(() => String)
    @Matches(SHA256)
    inventoryRevision!: string;
}

@InputType()
export class RunnerFarmCredentialRevisionInput {
    @Field(() => String)
    @Matches(SHA256)
    configRevision!: string;

    @Field(() => String)
    @Matches(SHA256)
    credentialRevision!: string;
}

@InputType()
export class RunnerFarmTransitionRevisionInput {
    @Field(() => String)
    @Matches(SHA256)
    configRevision!: string;
    @Field(() => String)
    @Matches(SHA256)
    ownershipRevision!: string;
    @Field(() => String)
    @Matches(SHA256)
    compatibilityRecordId!: string;
    @Field(() => String)
    @Matches(SHA256)
    transitionRevision!: string;
}

@InputType()
export class RunnerFarmScaleInput {
    @Field(() => String, { nullable: true })
    @IsOptional()
    @Matches(POOL_ID)
    poolId?: string;
    @Field(() => Int)
    @IsInt()
    @Min(0)
    @Max(64)
    target!: number;
    @Field(() => RunnerFarmFleetRevisionInput)
    @ValidateNested()
    @Type(() => RunnerFarmFleetRevisionInput)
    expected!: RunnerFarmFleetRevisionInput;
}

@InputType()
export class RunnerFarmPrewarmInput {
    @Field(() => String)
    @Matches(POOL_ID)
    poolId!: string;
    @Field(() => Int)
    @IsInt()
    @Min(0)
    @Max(64)
    target!: number;
    @Field(() => String)
    @Matches(SHA256)
    expectedConfigRevision!: string;
}

@InputType()
export class RunnerFarmRecycleInput {
    @Field(() => String)
    @Matches(RUNNER_NAME)
    runnerName!: string;
    @Field(() => RunnerFarmFleetRevisionInput)
    @ValidateNested()
    @Type(() => RunnerFarmFleetRevisionInput)
    expected!: RunnerFarmFleetRevisionInput;
}

@InputType()
export class RunnerFarmMaintenanceInput {
    @Field(() => RunnerFarmMaintenanceMode)
    @IsEnum(RunnerFarmMaintenanceMode)
    mode!: RunnerFarmMaintenanceMode;
    @Field(() => String)
    @Matches(SHA256)
    expectedConfigRevision!: string;
}

@InputType()
export class RunnerFarmQueueCancelInput {
    @Field(() => String)
    @Matches(REPOSITORY)
    repository!: string;
    @Field(() => String)
    @Matches(/^[0-9]{1,20}$/)
    runId!: string;
}

@InputType()
export class RunnerFarmLogInput {
    @Field(() => String)
    @Matches(RUNNER_NAME)
    runnerName!: string;
    @Field(() => Int, { defaultValue: 150 })
    @IsInt()
    @Min(1)
    @Max(500)
    lines = 150;
}

@InputType()
export class RunnerFarmPoolPatchInput {
    @Field(() => String)
    @Matches(POOL_ID)
    id!: string;
    @Field(() => String)
    @MaxLength(63)
    @Matches(/^[a-z0-9](?:[a-z0-9._-]*[a-z0-9])?$/)
    routingLabel!: string;
    @Field(() => [String], { defaultValue: [] })
    @IsArray()
    @Matches(/^[a-z0-9](?:[a-z0-9._-]*[a-z0-9])?$/, { each: true })
    additionalLabels: string[] = [];
    @Field(() => Int)
    @IsInt()
    @Min(1)
    @Max(64)
    fixed!: number;
    @Field(() => Int)
    @IsInt()
    @Min(0)
    @Max(64)
    min!: number;
    @Field(() => Int, { nullable: true })
    @IsOptional()
    @IsInt()
    @Min(0)
    @Max(64)
    max?: number | null;
    @Field(() => Boolean, { defaultValue: false })
    @IsBoolean()
    maxAutomatic = false;
    @Field(() => Int)
    @IsInt()
    @Min(0)
    @Max(64)
    idleBuffer!: number;
    @Field(() => GraphQLBigInt)
    cpuMilli!: bigint;
    @Field(() => GraphQLBigInt)
    memoryBytes!: bigint;
    @Field(() => Boolean)
    @IsBoolean()
    autoscaleEnabled!: boolean;
}

@InputType()
export class RunnerFarmGitHubConfigurationPatchInput {
    @Field(() => RunnerFarmGitHubScope, { nullable: true })
    @IsOptional()
    @IsEnum(RunnerFarmGitHubScope)
    scope?: RunnerFarmGitHubScope;
    @Field(() => String, { nullable: true })
    @IsOptional()
    @Matches(/^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$/)
    owner?: string;
    @Field(() => [String], { nullable: true })
    @IsOptional()
    @IsArray()
    @Matches(REPOSITORY, { each: true })
    repositories?: string[];
    @Field(() => String, { nullable: true })
    @IsOptional()
    @MaxLength(100)
    runnerGroup?: string | null;
    @Field(() => RunnerFarmAuthMode, { nullable: true })
    @IsOptional()
    @IsEnum(RunnerFarmAuthMode)
    authMode?: RunnerFarmAuthMode;
    @Field(() => String, { nullable: true })
    @IsOptional()
    @Matches(/^[0-9]{1,20}$/)
    githubAppId?: string | null;
    @Field(() => String, { nullable: true })
    @IsOptional()
    @Matches(/^[0-9]{1,20}$/)
    githubAppInstallationId?: string | null;
}

@InputType()
export class RunnerFarmPoolAutoscalePolicyInput {
    @Field(() => RunnerFarmPoolAutoscaleMode)
    @IsEnum(RunnerFarmPoolAutoscaleMode)
    mode!: RunnerFarmPoolAutoscaleMode;

    @Field(() => [String], { defaultValue: [] })
    @IsArray()
    @Matches(POOL_ID, { each: true })
    poolIds: string[] = [];
}

@InputType()
export class RunnerFarmRunnerConfigurationPatchInput {
    @Field(() => RunnerFarmMode, { nullable: true })
    @IsOptional()
    @IsEnum(RunnerFarmMode)
    mode?: RunnerFarmMode;
    @Field(() => Int, { nullable: true })
    @IsOptional()
    @IsInt()
    @Min(0)
    @Max(64)
    count?: number;
    @Field(() => [String], { nullable: true })
    @IsOptional()
    @IsArray()
    labels?: string[];
    @Field(() => RunnerFarmBackend, { nullable: true })
    @IsOptional()
    @IsEnum(RunnerFarmBackend)
    poolBackend?: RunnerFarmBackend;
    @Field(() => [RunnerFarmPoolPatchInput], { nullable: true })
    @IsOptional()
    @IsArray()
    @ArrayMaxSize(8)
    @ValidateNested({ each: true })
    @Type(() => RunnerFarmPoolPatchInput)
    pools?: RunnerFarmPoolPatchInput[];
    @Field(() => RunnerFarmPoolAutoscalePolicyInput, { nullable: true })
    @IsOptional()
    @ValidateNested()
    @Type(() => RunnerFarmPoolAutoscalePolicyInput)
    poolAutoscalePolicy?: RunnerFarmPoolAutoscalePolicyInput;
    @Field(() => GraphQLBigInt, { nullable: true })
    @IsOptional()
    defaultCpuMilli?: bigint | null;
    @Field(() => GraphQLBigInt, { nullable: true })
    @IsOptional()
    defaultMemoryBytes?: bigint | null;
    @Field(() => Boolean, { nullable: true })
    @IsOptional()
    @IsBoolean()
    ephemeral?: boolean;
    @Field(() => Boolean, { nullable: true })
    @IsOptional()
    @IsBoolean()
    runAsRoot?: boolean;
}

@InputType()
export class RunnerFarmResourceConfigurationPatchInput {
    @Field(() => GraphQLBigInt, { nullable: true })
    @IsOptional()
    cpuBudgetMilli?: bigint | null;
    @Field(() => GraphQLBigInt, { nullable: true })
    @IsOptional()
    memoryBudgetBytes?: bigint | null;
    @Field(() => GraphQLBigInt, { nullable: true })
    @IsOptional()
    cpuReserveMilli?: bigint;
    @Field(() => GraphQLBigInt, { nullable: true })
    @IsOptional()
    memoryReserveBytes?: bigint;
    @Field(() => Float, { nullable: true })
    @IsOptional()
    @Min(1)
    @Max(4)
    cpuOvercommit?: number;
    @Field(() => RunnerFarmMemorySwapMode, { nullable: true })
    @IsOptional()
    @IsEnum(RunnerFarmMemorySwapMode)
    memorySwapMode?: RunnerFarmMemorySwapMode;
    @Field(() => Int, { nullable: true })
    @IsOptional()
    @IsInt()
    @Min(0)
    pidsLimit?: number;
}

@InputType()
export class RunnerFarmStorageConfigurationPatchInput {
    @Field(() => String, { nullable: true })
    @IsOptional()
    @MaxLength(4096)
    cacheRoot?: string;
    @Field(() => RunnerFarmWorkspaceMode, { nullable: true })
    @IsOptional()
    @IsEnum(RunnerFarmWorkspaceMode)
    workspaceMode?: RunnerFarmWorkspaceMode;
    @Field(() => GraphQLBigInt, { nullable: true })
    @IsOptional()
    workspaceTmpfsBytes?: bigint | null;
    @Field(() => [String], { nullable: true })
    @IsOptional()
    @IsArray()
    cacheMounts?: string[];
}

@InputType()
export class RunnerFarmImageConfigurationPatchInput {
    @Field(() => RunnerFarmImageSource, { nullable: true })
    @IsOptional()
    @IsEnum(RunnerFarmImageSource)
    source?: RunnerFarmImageSource;
    @Field(() => String, { nullable: true })
    @IsOptional()
    @MaxLength(4096)
    image?: string | null;
    @Field(() => String, { nullable: true })
    @IsOptional()
    @MaxLength(4096)
    registryServer?: string | null;
    @Field(() => String, { nullable: true })
    @IsOptional()
    @MaxLength(4096)
    registryUsername?: string | null;
}

@InputType()
export class RunnerFarmDockerConfigurationPatchInput {
    @Field(() => Boolean, { nullable: true })
    @IsOptional()
    @IsBoolean()
    shareDockerSocket?: boolean;
    @Field(() => Boolean, { nullable: true })
    @IsOptional()
    @IsBoolean()
    dockerInDocker?: boolean;
    @Field(() => Boolean, { nullable: true })
    @IsOptional()
    @IsBoolean()
    sharedImageCache?: boolean;
    @Field(() => RunnerFarmNetworkIsolation, { nullable: true })
    @IsOptional()
    @IsEnum(RunnerFarmNetworkIsolation)
    networkIsolation?: RunnerFarmNetworkIsolation;
    @Field(() => String, { nullable: true })
    @IsOptional()
    @MaxLength(63)
    runnerNetwork?: string;
    @Field(() => Int, { nullable: true })
    @IsOptional()
    @IsInt()
    @Min(1)
    @Max(65535)
    mirrorPort?: number;
}

@InputType()
export class RunnerFarmAutoscaleConfigurationPatchInput {
    @Field(() => Boolean, { nullable: true })
    @IsOptional()
    @IsBoolean()
    enabled?: boolean;
    @Field(() => Int, { nullable: true })
    @IsOptional()
    @IsInt()
    @Min(0)
    @Max(64)
    min?: number;
    @Field(() => Int, { nullable: true })
    @IsOptional()
    @IsInt()
    @Min(1)
    @Max(64)
    max?: number;
    @Field(() => Int, { nullable: true })
    @IsOptional()
    @IsInt()
    @Min(0)
    @Max(64)
    minIdle?: number;
    @Field(() => Int, { nullable: true })
    @IsOptional()
    @IsInt()
    @Min(1)
    @Max(64)
    step?: number;
    @Field(() => Int, { nullable: true })
    @IsOptional()
    @IsInt()
    @Min(0)
    intervalSeconds?: number;
    @Field(() => Int, { nullable: true })
    @IsOptional()
    @IsInt()
    @Min(0)
    idleGraceSeconds?: number;
}

@InputType()
export class RunnerFarmImageUpdateConfigurationPatchInput {
    @Field(() => Boolean, { nullable: true })
    @IsOptional()
    @IsBoolean()
    enabled?: boolean;
    @Field(() => Int, { nullable: true })
    @IsOptional()
    @IsInt()
    @Min(300)
    @Max(86400)
    intervalSeconds?: number;
    @Field(() => Int, { nullable: true })
    @IsOptional()
    @IsInt()
    @Min(0)
    @Max(86400)
    drainTimeoutSeconds?: number;
}

@InputType()
export class RunnerFarmConfigurationPatchInput {
    @Field(() => RunnerFarmGitHubConfigurationPatchInput, { nullable: true })
    @IsOptional()
    @ValidateNested()
    @Type(() => RunnerFarmGitHubConfigurationPatchInput)
    github?: RunnerFarmGitHubConfigurationPatchInput;
    @Field(() => RunnerFarmRunnerConfigurationPatchInput, { nullable: true })
    @IsOptional()
    @ValidateNested()
    @Type(() => RunnerFarmRunnerConfigurationPatchInput)
    runners?: RunnerFarmRunnerConfigurationPatchInput;
    @Field(() => RunnerFarmResourceConfigurationPatchInput, { nullable: true })
    @IsOptional()
    @ValidateNested()
    @Type(() => RunnerFarmResourceConfigurationPatchInput)
    resources?: RunnerFarmResourceConfigurationPatchInput;
    @Field(() => RunnerFarmStorageConfigurationPatchInput, { nullable: true })
    @IsOptional()
    @ValidateNested()
    @Type(() => RunnerFarmStorageConfigurationPatchInput)
    storage?: RunnerFarmStorageConfigurationPatchInput;
    @Field(() => RunnerFarmImageConfigurationPatchInput, { nullable: true })
    @IsOptional()
    @ValidateNested()
    @Type(() => RunnerFarmImageConfigurationPatchInput)
    image?: RunnerFarmImageConfigurationPatchInput;
    @Field(() => RunnerFarmDockerConfigurationPatchInput, { nullable: true })
    @IsOptional()
    @ValidateNested()
    @Type(() => RunnerFarmDockerConfigurationPatchInput)
    docker?: RunnerFarmDockerConfigurationPatchInput;
    @Field(() => RunnerFarmAutoscaleConfigurationPatchInput, { nullable: true })
    @IsOptional()
    @ValidateNested()
    @Type(() => RunnerFarmAutoscaleConfigurationPatchInput)
    autoscaling?: RunnerFarmAutoscaleConfigurationPatchInput;
    @Field(() => RunnerFarmImageUpdateConfigurationPatchInput, { nullable: true })
    @IsOptional()
    @ValidateNested()
    @Type(() => RunnerFarmImageUpdateConfigurationPatchInput)
    imageUpdates?: RunnerFarmImageUpdateConfigurationPatchInput;
    @Field(() => Boolean, { nullable: true })
    @IsOptional()
    @IsBoolean()
    dashboardWidgetEnabled?: boolean;
}

@InputType()
export class RunnerFarmApplyConfigurationInput {
    @Field(() => String)
    @Matches(SHA256)
    expectedConfigRevision!: string;
    @Field(() => RunnerFarmConfigurationPatchInput)
    @ValidateNested()
    @Type(() => RunnerFarmConfigurationPatchInput)
    patch!: RunnerFarmConfigurationPatchInput;
}

@InputType()
export class RunnerFarmValidateConfigurationInput {
    @Field(() => String)
    @Matches(SHA256)
    expectedConfigRevision!: string;
    @Field(() => RunnerFarmConfigurationPatchInput)
    @ValidateNested()
    @Type(() => RunnerFarmConfigurationPatchInput)
    patch!: RunnerFarmConfigurationPatchInput;
}

@InputType()
export class RunnerFarmSetGithubPatInput {
    @Field(() => String)
    @Matches(SHA256)
    expectedConfigRevision!: string;
    @Field(() => String)
    @Matches(SHA256)
    expectedCredentialRevision!: string;
    @Field(() => String)
    @IsString()
    @MaxLength(255)
    value!: string;
}

@InputType()
export class RunnerFarmSetGithubAppPrivateKeyInput {
    @Field(() => String)
    @Matches(SHA256)
    expectedConfigRevision!: string;
    @Field(() => String)
    @Matches(SHA256)
    expectedCredentialRevision!: string;
    @Field(() => String)
    @IsString()
    @MaxLength(32_768)
    value!: string;
}

@InputType()
export class RunnerFarmSetRegistryTokenInput {
    @Field(() => String)
    @Matches(SHA256)
    expectedConfigRevision!: string;
    @Field(() => String)
    @Matches(SHA256)
    expectedCredentialRevision!: string;
    @Field(() => String)
    @IsString()
    @MaxLength(4_096)
    value!: string;
}

@InputType()
export class RunnerFarmSaveDockerfileInput {
    @Field(() => String)
    @Matches(SHA256)
    expectedDockerfileSha256!: string;
    @Field(() => String)
    @IsString()
    @MaxLength(1_048_576)
    content!: string;
}

@InputType()
export class RunnerFarmStartImageBuildInput {
    @Field(() => String)
    @Matches(SHA256)
    dockerfileSha256!: string;
}

@InputType()
export class RunnerFarmStartProvisioningValidationInput {
    @Field(() => String)
    @Matches(SHA256)
    expectedConfigRevision!: string;
}

@InputType()
export class RunnerFarmStartCompatibilityTestInput {
    @Field(() => String)
    @Matches(SHA256)
    expectedConfigRevision!: string;
}

@InputType()
export class RunnerFarmOperationInput {
    @Field(() => ID)
    @Matches(UUID)
    operationId!: string;
}
