/** Code-first common output models for the Runner Farm API plugin. */
import { Field, GraphQLISODateTime, ID, Int, ObjectType } from '@nestjs/graphql';
import { GraphQLBigInt } from 'graphql-scalars';
import {
    RunnerFarmAuthModeState,
    RunnerFarmBackendStateValue,
    RunnerFarmConclusion,
    RunnerFarmOperationKind,
    RunnerFarmOperationState,
} from './enums.js';

@ObjectType('RunnerFarmReason')
export class RunnerFarmReasonModel {
    @Field(() => String)
    code!: string;

    @Field(() => String, { nullable: true })
    message?: string | null;
}

@ObjectType('RunnerFarmRevisionSet')
export class RunnerFarmRevisionSetModel {
    @Field(() => String)
    configRevision!: string;

    @Field(() => String)
    inventoryRevision!: string;

    @Field(() => String)
    transitionRevision!: string;

    @Field(() => String)
    ownershipRevision!: string;

    @Field(() => String)
    compatibilityRecordId!: string;

    @Field(() => String, { nullable: true })
    credentialRevision?: string | null;
}

@ObjectType('RunnerFarmBackendState')
export class RunnerFarmBackendStateModel {
    @Field(() => RunnerFarmBackendStateValue)
    requested!: RunnerFarmBackendStateValue;

    @Field(() => RunnerFarmBackendStateValue)
    effective!: RunnerFarmBackendStateValue;

    @Field(() => String)
    transitionPhase!: string;

    @Field(() => ID, { nullable: true })
    transitionId?: string | null;

    @Field(() => String)
    transitionRevision!: string;

    @Field(() => String)
    ownershipRevision!: string;
}

@ObjectType('RunnerFarmCompatibility')
export class RunnerFarmCompatibilityModel {
    @Field(() => Boolean)
    valid!: boolean;

    @Field(() => RunnerFarmReasonModel)
    reason!: RunnerFarmReasonModel;

    @Field(() => String, { nullable: true })
    recordId?: string | null;

    @Field(() => GraphQLISODateTime, { nullable: true })
    testedAt?: Date | null;

    @Field(() => Int, { nullable: true })
    ageSeconds?: number | null;

    @Field(() => String, { nullable: true })
    helperDigest?: string | null;

    @Field(() => String, { nullable: true })
    pluginDigest?: string | null;

    @Field(() => String, { nullable: true })
    imageDigest?: string | null;

    @Field(() => String, { nullable: true })
    entrypointDigest?: string | null;

    @Field(() => String, { nullable: true })
    moduleRevision?: string | null;

    @Field(() => String, { nullable: true })
    goVersion?: string | null;

    @Field(() => GraphQLBigInt, { nullable: true })
    runnerGroupId?: bigint | null;

    @Field(() => String, { nullable: true })
    runnerGroupPolicy?: string | null;

    @Field(() => String, { nullable: true })
    owner?: string | null;

    @Field(() => RunnerFarmAuthModeState)
    authMode!: RunnerFarmAuthModeState;

    @Field(() => Boolean)
    privateKeyConfigured!: boolean;
}

@ObjectType('RunnerFarmOperation')
export class RunnerFarmOperationModel {
    @Field(() => ID)
    id!: string;

    @Field(() => RunnerFarmOperationKind)
    kind!: RunnerFarmOperationKind;

    @Field(() => RunnerFarmOperationState)
    state!: RunnerFarmOperationState;

    @Field(() => String)
    code!: string;

    @Field(() => String)
    message!: string;

    @Field(() => GraphQLISODateTime)
    createdAt!: Date;

    @Field(() => GraphQLISODateTime)
    updatedAt!: Date;

    @Field(() => GraphQLISODateTime, { nullable: true })
    finishedAt?: Date | null;

    @Field(() => [String])
    output!: string[];
}

@ObjectType('RunnerFarmResourceQuantity')
export class RunnerFarmResourceQuantityModel {
    @Field(() => GraphQLBigInt)
    budget!: bigint;

    @Field(() => GraphQLBigInt)
    reserve!: bigint;

    @Field(() => GraphQLBigInt)
    reserved!: bigint;

    @Field(() => GraphQLBigInt)
    admissible!: bigint;
}

@ObjectType('RunnerFarmResources')
export class RunnerFarmResourcesModel {
    @Field(() => Boolean)
    available!: boolean;

    @Field(() => RunnerFarmReasonModel, { nullable: true })
    reason?: RunnerFarmReasonModel | null;

    @Field(() => RunnerFarmResourceQuantityModel)
    cpuMilli!: RunnerFarmResourceQuantityModel;

    @Field(() => RunnerFarmResourceQuantityModel)
    memoryBytes!: RunnerFarmResourceQuantityModel;
}

@ObjectType('RunnerFarmReservation')
export class RunnerFarmReservationModel {
    @Field(() => ID)
    operationId!: string;

    @Field(() => String)
    poolId!: string;

    @Field(() => String, { nullable: true })
    runnerName?: string | null;

    @Field(() => GraphQLBigInt)
    cpuMilli!: bigint;

    @Field(() => GraphQLBigInt)
    memoryBytes!: bigint;

    @Field(() => GraphQLISODateTime)
    deadline!: Date;

    @Field(() => String)
    phase!: string;
}

@ObjectType('RunnerFarmRecentActivity')
export class RunnerFarmRecentActivityModel {
    @Field(() => Int)
    schemaVersion!: number;

    @Field(() => GraphQLISODateTime)
    observedAt!: Date;

    @Field(() => GraphQLISODateTime)
    completedAt!: Date;

    @Field(() => String)
    runnerName!: string;

    @Field(() => String)
    poolId!: string;

    @Field(() => String)
    workHandle!: string;

    @Field(() => String)
    job!: string;

    @Field(() => RunnerFarmConclusion)
    conclusion!: RunnerFarmConclusion;
}

@ObjectType('RunnerFarmCredentialPresence')
export class RunnerFarmCredentialPresenceModel {
    @Field(() => String)
    revision!: string;

    @Field(() => Boolean)
    githubPat!: boolean;

    @Field(() => Boolean)
    githubAppPrivateKey!: boolean;

    @Field(() => Boolean)
    registryToken!: boolean;
}

@ObjectType('RunnerFarmActionResult')
export class RunnerFarmActionResultModel {
    @Field(() => Boolean)
    ok!: boolean;

    @Field(() => String)
    code!: string;

    @Field(() => String)
    message!: string;

    @Field(() => RunnerFarmRevisionSetModel)
    revisions!: RunnerFarmRevisionSetModel;

    @Field(() => RunnerFarmOperationModel, { nullable: true })
    operation?: RunnerFarmOperationModel | null;
}

@ObjectType('RunnerFarmDockerfileSaveResult')
export class RunnerFarmDockerfileSaveResultModel {
    @Field(() => Boolean)
    ok!: boolean;

    @Field(() => String)
    code!: string;

    @Field(() => String)
    message!: string;

    @Field(() => String, { nullable: true })
    sha256?: string | null;
}
