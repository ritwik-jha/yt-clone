# AWS ECS Fargate Task Definition & Infrastructure Requirements

This document provides a technical specification of the **AWS ECS Fargate Task Definition** and the required AWS cloud infrastructure resources for running the on-demand video transcoding service in a serverless, event-driven video streaming architecture.

---

## 1. Architectural Role

The **Transcoder Service** runs as an ephemeral, short-lived container task on **AWS ECS Fargate**. Instead of keeping dedicated compute servers running continuously, the system provisions an ECS task dynamically whenever a video upload notification is pulled from the Amazon SQS queue.

```
[S3 Raw Upload] ──> [SQS Queue] ──> [Poller / Lambda] ──(ecs:RunTask)──> [ECS Fargate Container]
                                                                                │
                                                                                ▼
                                                                     [Transcode & Push to S3]
```

---

## 2. Complete Task Definition Specification (`task-definition.json`)

The task definition acts as the blueprint describing container specifications, CPU/RAM allocations, network modes, IAM permissions, and log drivers required by AWS Fargate.

```json
{
  "family": "video-transcoder",
  "requiresCompatibilities": [
    "FARGATE"
  ],
  "networkMode": "awsvpc",
  "cpu": "1024",
  "memory": "2048",
  "runtimePlatform": {
    "cpuArchitecture": "ARM64",
    "operatingSystemFamily": "LINUX"
  },
  "executionRoleArn": "arn:aws:iam::123456789012:role/ecsTaskExecutionRole",
  "taskRoleArn": "arn:aws:iam::123456789012:role/videoTranscoderTaskRole",
  "containerDefinitions": [
    {
      "name": "video-transcoder",
      "image": "123456789012.dkr.ecr.ap-south-1.amazonaws.com/video-transcoder:latest",
      "essential": true,
      "environment": [
        {
          "name": "S3_BUCKET",
          "value": "default-raw-bucket"
        },
        {
          "name": "S3_KEY",
          "value": "default-video.mp4"
        },
        {
          "name": "FASTAPI_WEBHOOK_URL",
          "value": "https://api.yourdomain.com"
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/video-transcoder",
          "awslogs-region": "ap-south-1",
          "awslogs-stream-prefix": "transcoder"
        }
      }
    }
  ]
}
```

---

## 3. Configuration Parameters Breakdown

| Field | Value / Setting | Description |
| :--- | :--- | :--- |
| `family` | `video-transcoder` | Unique name grouping revisions of this task definition. |
| `requiresCompatibilities` | `["FARGATE"]` | Enforces serverless execution without managing EC2 instances. |
| `networkMode` | `awsvpc` | **Mandatory for Fargate.** Attaches a dedicated Elastic Network Interface (ENI) to the container. |
| `cpu` | `1024` | Allocates 1 vCPU (`1024` CPU units). |
| `memory` | `2048` | Allocates 2 GB (2048 MB) of RAM. |
| `runtimePlatform` | `ARM64 / LINUX` | Specifies the CPU architecture matching the ECR Docker image build. |
| `executionRoleArn` | IAM Role | Used by the **ECS Agent** to pull images from ECR and send logs to CloudWatch. |
| `taskRoleArn` | IAM Role | Granted to the **running container application** to access S3 buckets and AWS APIs. |
| `containerDefinitions.name` | `video-transcoder` | Must match the container name referenced in `containerOverrides` by dispatchers. |

---

## 4. Required AWS Infrastructure Resources

To execute task provisioning programmatically via `boto3` (from an AWS Lambda function or a custom SQS poller service), the following infrastructure components must be established:

### 1. ECS Cluster
* **Cluster Name**: `ran-transcoder-cluster` (or custom cluster name).
* Hosts short-lived Fargate tasks inside your designated AWS Region.

### 2. Amazon ECR Repository
* Private Docker registry hosting the transcoding image (built with Python, `boto3`, and static **FFmpeg** binaries).
* **URI Format**: `{account_id}.dkr.ecr.{region}.amazonaws.com/video-transcoder:latest`

### 3. VPC Networking Components (`awsvpcConfiguration`)
* **Subnets**: Public or private subnet IDs with outbound routing to ECR and S3.
* **Security Groups**: Allows outbound HTTPS (443) traffic.
* **Public IP Assignment**: `assignPublicIp="ENABLED"` (required when running on public subnets to enable ECR image pulling and S3 uploads).

### 4. IAM Roles & Permissions

#### A. ECS Task Execution Role (`ecsTaskExecutionRole`)
Grants ECS permissions before the application starts:
* `ecr:GetAuthorizationToken`
* `ecr:BatchCheckLayerAvailability`
* `ecr:GetDownloadUrlForLayer`
* `ecr:BatchGetImage`
* `logs:CreateLogStream`
* `logs:PutLogEvents`

#### B. ECS Task Role (`videoTranscoderTaskRole`)
Grants application-level access to the running container:
* `s3:GetObject` on Raw Video Bucket (`arn:aws:s3:::raw-bucket/*`)
* `s3:PutObject` & `s3:PutObjectAcl` on Processed Video Bucket (`arn:aws:s3:::processed-bucket/*`)

#### C. Dispatcher IAM Permissions (Poller Service or AWS Lambda)
Allows the poller daemon/Lambda function to spawn Fargate tasks:
* `ecs:RunTask` on cluster `arn:aws:ecs:*:*:cluster/*`
* `iam:PassRole` for both `executionRoleArn` and `taskRoleArn`

---

## 5. Dynamic Container Overrides Dispatch Logic

When a message is consumed from SQS, the poller or Lambda function passes the extracted S3 bucket and object key dynamically using `containerOverrides`:

```python
import boto3

ecs_client = boto3.client("ecs", region_name="ap-south-1")

def dispatch_transcoder_task(bucket_name: str, s3_key: str):
    response = ecs_client.run_task(
        cluster="ran-transcoder-cluster",
        launchType="FARGATE",
        taskDefinition="video-transcoder:1",
        overrides={
            "containerOverrides": [
                {
                    "name": "video-transcoder",
                    "environment": [
                        {"name": "S3_BUCKET", "value": bucket_name},
                        {"name": "S3_KEY", "value": s3_key}
                    ]
                }
            ]
        },
        networkConfiguration={
            "awsvpcConfiguration": {
                "subnets": ["subnet-0123456789abcdef0"],
                "securityGroups": ["sg-0123456789abcdef0"],
                "assignPublicIp": "ENABLED"
            }
        }
    )
    return response
```

---

## 6. AWS CLI Management Commands

### Register Task Definition
```bash
aws ecs register-task-definition \
  --cli-input-json file://task-definition.json \
  --region ap-south-1
```

### Manual Test Execution
```bash
aws ecs run-task \
  --cluster ran-transcoder-cluster \
  --launch-type FARGATE \
  --task-definition video-transcoder:1 \
  --network-configuration "awsvpcConfiguration={subnets=[subnet-0123456789abcdef0],securityGroups=[sg-0123456789abcdef0],assignPublicIp=ENABLED}" \
  --region ap-south-1
```
