# Design docs

Grouped by kind. Where a doc disagrees with the code, the code is
authoritative; the root `README.md` (*Design docs*) lists the known
divergences.

## `specs/` — what the system is

| Doc | Covers |
|---|---|
| [`api-and-db-schema-spec.md`](specs/api-and-db-schema-spec.md) | Every API route and table. The contract the backend implements. |
| [`frontend-screens-spec.md`](specs/frontend-screens-spec.md) | The client's screens and their state. Written for the mobile app; the web app follows `frontend/PLAN.md`. |
| [`ecs-task-definition-spec.md`](specs/ecs-task-definition-spec.md) | The transcoder's Fargate task and the AWS resources around it. Now built in `IAC/terraform/`. |

## `guides/` — how it was first built

Early walkthroughs, kept as design rationale. Don't copy request shapes from
them (`frontend/AGENTS.md`).

| Doc | Covers |
|---|---|
| [`auth-implementation-guide.md`](guides/auth-implementation-guide.md) | Cognito sign-up, OTP, login, and the HttpOnly cookie session. |
| [`s3-upload-and-metadata-guide.md`](guides/s3-upload-and-metadata-guide.md) | Presigned S3 uploads and saving video metadata. |
| [`ecs-sqs-deployment-guide.md`](guides/ecs-sqs-deployment-guide.md) | The SQS → ECS transcoding pipeline. |

## `architecture/` — analysis

| Doc | Covers |
|---|---|
| [`video-streaming-scaling-and-bottlenecks.md`](architecture/video-streaming-scaling-and-bottlenecks.md) | Where the pipeline breaks under load, and designs to scale it. Mostly not built. |

## `plans/` — features not built yet

| Doc | Covers | Depends on |
|---|---|---|
| [`watch-history-plan.md`](plans/watch-history-plan.md) | Watch history, resume across browsers, the History page, progress bars on thumbnails. | — |
| [`recommendations-plan.md`](plans/recommendations-plan.md) | Tags, likes, subscriptions, *Not interested*; a personalised home feed and related videos for *Up next*; impressions and A/B measurement. | Watch history |

Deployment runbooks live outside `docs/`: `DEPLOY_AWS.md` at the root, and
`IAC/deployment-guide.md`.
