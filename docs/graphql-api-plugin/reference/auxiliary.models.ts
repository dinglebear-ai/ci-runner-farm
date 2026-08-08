/** Queue, statistics, cache, image, Dockerfile, and log models. */
import { Field, GraphQLISODateTime, Int, ObjectType } from '@nestjs/graphql';
import { GraphQLBigInt } from 'graphql-scalars';
import { RunnerFarmImageSource } from './enums.js';

@ObjectType('RunnerFarmQueueJob')
export class RunnerFarmQueueJobModel {
    @Field(() => String)
    runId!: string;
    @Field(() => String)
    jobId!: string;
    @Field(() => String)
    repository!: string;
    @Field(() => String)
    workflow!: string;
    @Field(() => [String])
    labels!: string[];
    @Field(() => String)
    poolId!: string;
    @Field(() => String)
    reason!: string;
    @Field(() => GraphQLISODateTime, { nullable: true })
    createdAt?: Date | null;
    @Field(() => String, { nullable: true })
    url?: string | null;
}

@ObjectType('RunnerFarmQueueSnapshot')
export class RunnerFarmQueueSnapshotModel {
    @Field(() => Int, { nullable: true })
    queued?: number | null;
    @Field(() => Int)
    knownQueued!: number;
    @Field(() => Int, { nullable: true })
    workflowRuns?: number | null;
    @Field(() => Boolean)
    partial!: boolean;
    @Field(() => Boolean)
    truncated!: boolean;
    @Field(() => Boolean)
    detailComplete!: boolean;
    @Field(() => Int)
    ageSeconds!: number;
    @Field(() => [RunnerFarmQueueJobModel])
    jobs!: RunnerFarmQueueJobModel[];
}

@ObjectType('RunnerFarmRunStatistics')
export class RunnerFarmRunStatisticsModel {
    @Field(() => Int)
    succeeded!: number;
    @Field(() => Int)
    failed!: number;
    @Field(() => Int)
    cancelled!: number;
    @Field(() => Int)
    other!: number;
    @Field(() => Int, { nullable: true })
    total?: number | null;
    @Field(() => Int)
    ageSeconds!: number;
}

@ObjectType('RunnerFarmCacheUsage')
export class RunnerFarmCacheUsageModel {
    @Field(() => GraphQLBigInt, { nullable: true })
    totalBytes?: bigint | null;
    @Field(() => GraphQLBigInt)
    packageBytes!: bigint;
    @Field(() => Int)
    ageSeconds!: number;
}

@ObjectType('RunnerFarmImageInfo')
export class RunnerFarmImageInfoModel {
    @Field(() => Boolean)
    exists!: boolean;
    @Field(() => String)
    image!: string;
    @Field(() => RunnerFarmImageSource)
    source!: RunnerFarmImageSource;
    @Field(() => String, { nullable: true })
    imageId?: string | null;
    @Field(() => GraphQLISODateTime, { nullable: true })
    createdAt?: Date | null;
    @Field(() => GraphQLBigInt, { nullable: true })
    sizeBytes?: bigint | null;
    @Field(() => String, { nullable: true })
    baseImage?: string | null;
    @Field(() => Int)
    runnersUsingImage!: number;
    @Field(() => String, { nullable: true })
    dockerfilePath?: string | null;
}

@ObjectType('RunnerFarmDockerfile')
export class RunnerFarmDockerfileModel {
    @Field(() => String)
    content!: string;
    @Field(() => String)
    sha256!: string;
    @Field(() => String)
    defaultContent!: string;
}

@ObjectType('RunnerFarmLog')
export class RunnerFarmLogModel {
    @Field(() => String)
    source!: string;
    @Field(() => String)
    content!: string;
    @Field(() => Boolean)
    truncated!: boolean;
}
