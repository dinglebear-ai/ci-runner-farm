/** Code-first fleet status models for the Runner Farm API plugin. */
import { Field, Float, GraphQLISODateTime, Int, ObjectType } from '@nestjs/graphql';
import { GraphQLBigInt } from 'graphql-scalars';
import {
    RunnerFarmBackendStateModel,
    RunnerFarmCompatibilityModel,
    RunnerFarmCredentialPresenceModel,
    RunnerFarmOperationModel,
    RunnerFarmReasonModel,
    RunnerFarmRecentActivityModel,
    RunnerFarmReservationModel,
    RunnerFarmResourcesModel,
} from './common.models.js';
import { RunnerFarmModeState } from './enums.js';

@ObjectType('RunnerFarmPool')
export class RunnerFarmPoolModel {
    @Field(() => String)
    id!: string;
    @Field(() => String)
    label!: string;
    @Field(() => String)
    routingLabel!: string;
    @Field(() => [String])
    additionalLabels!: string[];
    @Field(() => [String])
    effectiveLabels!: string[];
    @Field(() => GraphQLBigInt)
    cpuMilli!: bigint;
    @Field(() => GraphQLBigInt)
    memoryBytes!: bigint;
    @Field(() => RunnerFarmReasonModel, { nullable: true })
    blockedReason?: RunnerFarmReasonModel | null;
    @Field(() => Boolean)
    autoscaleEnabled!: boolean;
    @Field(() => Int)
    configuredTarget!: number;
    @Field(() => Int)
    effectiveTarget!: number;
    @Field(() => Int)
    count!: number;
    @Field(() => Int)
    up!: number;
    @Field(() => Int)
    busy!: number;
    @Field(() => Int)
    idle!: number;
    @Field(() => Int)
    starting!: number;
    @Field(() => Int)
    error!: number;
    @Field(() => Int)
    completed!: number;
    @Field(() => Int)
    stale!: number;
    @Field(() => Int)
    retiring!: number;
    @Field(() => Int)
    pending!: number;
    @Field(() => Int)
    min!: number;
    @Field(() => Int, { nullable: true })
    max?: number | null;
    @Field(() => Boolean)
    maxAutomatic!: boolean;
    @Field(() => Int)
    idleBuffer!: number;
    @Field(() => Int, { nullable: true })
    assignedJobs?: number | null;
    @Field(() => Boolean)
    demandFresh!: boolean;
    @Field(() => Int)
    desired!: number;
    @Field(() => Int)
    admitted!: number;
    @Field(() => Int)
    advertisedCapacity!: number;
    @Field(() => Int, { nullable: true })
    leaseAgeSeconds?: number | null;
    @Field(() => Boolean)
    sessionHealthy!: boolean;
    @Field(() => String)
    ownershipState!: string;
    @Field(() => GraphQLBigInt, { nullable: true })
    remoteScaleSetId?: bigint | null;
    @Field(() => Boolean)
    tombstone!: boolean;
    @Field(() => Boolean)
    orphan!: boolean;
}

@ObjectType('RunnerFarmRunner')
export class RunnerFarmRunnerModel {
    @Field(() => String)
    name!: string;
    @Field(() => String)
    poolId!: string;
    @Field(() => String)
    routingLabel!: string;
    @Field(() => String)
    scopeTarget!: string;
    @Field(() => Int)
    poolIndex!: number;
    @Field(() => String)
    state!: string;
    @Field(() => String)
    phase!: string;
    @Field(() => String, { nullable: true })
    job?: string | null;
    @Field(() => GraphQLISODateTime, { nullable: true })
    jobStartedAt?: Date | null;
    @Field(() => GraphQLISODateTime, { nullable: true })
    startedAt?: Date | null;
    @Field(() => String, { nullable: true })
    repository?: string | null;
    @Field(() => Int, { nullable: true })
    pullRequest?: number | null;
    @Field(() => String, { nullable: true })
    branch?: string | null;
    @Field(() => String, { nullable: true })
    workflowRunId?: string | null;
    @Field(() => GraphQLBigInt, { nullable: true })
    cpuLimitMilli?: bigint | null;
    @Field(() => GraphQLBigInt, { nullable: true })
    memoryLimitBytes?: bigint | null;
    @Field(() => Float, { nullable: true })
    cpuPercent?: number | null;
    @Field(() => GraphQLBigInt, { nullable: true })
    memoryUsedBytes?: bigint | null;
    @Field(() => Boolean)
    completed!: boolean;
    @Field(() => Boolean)
    stale!: boolean;
    @Field(() => Boolean)
    retiring!: boolean;
}

@ObjectType('RunnerFarmStatus')
export class RunnerFarmStatusModel {
    @Field(() => Int)
    schemaVersion!: number;
    @Field(() => String)
    configRevision!: string;
    @Field(() => GraphQLISODateTime)
    observedAt!: Date;
    @Field(() => String)
    inventoryRevision!: string;
    @Field(() => RunnerFarmBackendStateModel)
    backend!: RunnerFarmBackendStateModel;
    @Field(() => RunnerFarmCompatibilityModel)
    compatibility!: RunnerFarmCompatibilityModel;
    @Field(() => RunnerFarmOperationModel, { nullable: true })
    operation?: RunnerFarmOperationModel | null;
    @Field(() => Boolean)
    maintenance!: boolean;
    @Field(() => RunnerFarmResourcesModel)
    resources!: RunnerFarmResourcesModel;
    @Field(() => [RunnerFarmReservationModel])
    reservations!: RunnerFarmReservationModel[];
    @Field(() => [RunnerFarmRecentActivityModel])
    recentActivity!: RunnerFarmRecentActivityModel[];
    @Field(() => RunnerFarmModeState)
    mode!: RunnerFarmModeState;
    @Field(() => String, { nullable: true })
    configError?: string | null;
    @Field(() => Int)
    count!: number;
    @Field(() => Int)
    configured!: number;
    @Field(() => RunnerFarmCredentialPresenceModel)
    credentials!: RunnerFarmCredentialPresenceModel;
    @Field(() => Boolean)
    autoscaleEnabled!: boolean;
    @Field(() => Int)
    autoscaleMax!: number;
    @Field(() => String)
    autoscaleState!: string;
    @Field(() => String)
    imageAutoUpdateState!: string;
    @Field(() => String, { nullable: true })
    warning?: string | null;
    @Field(() => String, { nullable: true })
    securityWarning?: string | null;
    @Field(() => Int)
    stale!: number;
    @Field(() => Int)
    retiring!: number;
    @Field(() => Int)
    blockedCapacity!: number;
    @Field(() => [RunnerFarmPoolModel])
    pools!: RunnerFarmPoolModel[];
    @Field(() => [RunnerFarmRunnerModel])
    runners!: RunnerFarmRunnerModel[];
}

@ObjectType('RunnerFarmReadiness')
export class RunnerFarmReadinessModel {
    @Field(() => Int)
    schemaVersion!: number;
    @Field(() => RunnerFarmBackendStateModel)
    backend!: RunnerFarmBackendStateModel;
    @Field(() => RunnerFarmCompatibilityModel)
    compatibility!: RunnerFarmCompatibilityModel;
    @Field(() => RunnerFarmOperationModel, { nullable: true })
    operation?: RunnerFarmOperationModel | null;
    @Field(() => Int, { nullable: true })
    count?: number | null;
}
