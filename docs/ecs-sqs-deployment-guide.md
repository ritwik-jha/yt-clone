# ECS Fargate Transcoder Deployment & SQS Consumer Manual

This implementation manual provides the step-by-step configurations, deployment blueprints, and complete orchestration code required to deploy an asynchronous, serverless video transcoding pipeline. 

The pipeline connects **Amazon S3** upload events, an **Amazon SQS** message queue, a **Python Consumer Service** daemon, and an on-demand **AWS ECS Fargate Task** running FFmpeg.

---

## 1. Asynchronous Task Dispatch Flow

The diagram below outlines the sequence of operations from the moment a user finishes uploading a video to the final teardown of the serverless transcoding container:

```
[ Flutter Client ]
        │
        │ 1. Direct Multipart PUT Upload
        ▼
[ S3 Raw Video Bucket ]
        │
        │ 2. Trigger s3:ObjectCreated Notification
        ▼
[ Amazon SQS Queue ] <─── Polling daemon (Long Poll: 10s) ─── [ Python Consumer ]
                                                                     │
                                                                     │ 3. SQS Message Received
                                                                     │    & S3 Coordinates Parsed
                                                                     ▼
                                                             [ Run ECS Fargate Task ]
                                                                     │
                                                                     │ 4. ecs:RunTask API Call
                                                                     │    with Env Overrides
                                                                     ▼
                                                             [ AWS ECS Fargate ]
                                                                     │
                                                                     │ 5. Spins up container
                                                                     ▼
                                                           [ FFmpeg Transcoder Task ]
                                                                     │
                                                                     │ 6. Process Raw S3 File -> DASH
                                                                     │ 7. Write to Processed S3 Bucket
                                                                     │ 8. Call FastAPI Webhook Callback
                                                                     ▼
                                                                ( Container Exits )
```

---

## 2. AWS ECS Fargate Task Definition Blueprint

The task definition is a declarative JSON configuration instructing AWS ECS how to provision the serverless container. It defines CPU, RAM, network configuration, CloudWatch logging streams, and required IAM roles.

### Task Definition JSON (`task-definition.json`)
Create a file named `task-definition.json` with the following schema:

```json
{
  "family": "video-transcoder",
  "requiresCompatibilities": [
    "FARGATE"
  ],
  "networkMode": "awsvpc",
  "cpu": "1024",
  "memory": "2048",
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
          "value": "default-key.mp4"
        },
        {
          "name": "FASTAPI_WEBHOOK_URL",
          "value": "https://your-ngrok-or-domain.ngrok-free.app"
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

### Architectural Parameter Decodes:
*   **`requiresCompatibilities: ["FARGATE"]`**: Ensures the task executes in a serverless model where AWS manages the host instances.
*   **`networkMode: "awsvpc"`**: Allocates a unique Elastic Network Interface (ENI) and a private IP address directly to the running container within your VPC.
*   **`executionRoleArn`**: The IAM role utilized by the AWS ECS Agent *before* the container starts to pull your private container image from ECR and configure logging streams.
*   **`taskRoleArn`**: The IAM role utilized by your running Python application code to grant programmatic access to S3 buckets, SQS, and other cloud services.
*   **`containerDefinitions.name`**: **Crucial Alignment**. This must match exactly with the container overrides specified inside your Python Consumer script (`"name": "video-transcoder"`) to dynamically inject environment variables.

### Registering the Task Definition with the AWS CLI
To upload and register this definition to your AWS account, execute the following command in your terminal:

```bash
aws ecs register-task-definition \
    --cli-input-json file://task-definition.json \
    --region ap-south-1
```

*Note: Executing this command creates a new incremental revision of your task (e.g., `video-transcoder:1` or `video-transcoder:2`). Keep track of the revision number to supply it to your Python Consumer.*

---

## 3. Python SQS Consumer & ECS Dispatcher

The Python consumer runs as a persistent daemon. It long-polls Amazon SQS for new S3 events, extracts object metadata, triggers the serverless ECS container on-demand, and safely removes the message from SQS on success.

### Consumer Implementation (`consumer.py`)

```python
import boto3
import json
import time
import sys

# AWS Settings configuration
AWS_REGION = "ap-south-1"
SQS_QUEUE_URL = "https://sqs.ap-south-1.amazonaws.com/123456789012/video-processing-queue"
ECS_CLUSTER_NAME = "ran-transcoder-cluster"
ECS_TASK_DEFINITION = "video-transcoder:2"  # Matches family:revision
CONTAINER_NAME = "video-transcoder"          # Must match container name in JSON definition

# VPC Networking specifications for Fargate container launch
VPC_SUBNETS = [
    "subnet-0123456789abcdef0",
    "subnet-0123456789abcdef1",
    "subnet-0123456789abcdef2"
]
SECURITY_GROUPS = [
    "sg-0987654321fedcba0"
]

# Initialize boto3 clients
sqs_client = boto3.client("sqs", region_name=AWS_REGION)
ecs_client = boto3.client("ecs", region_name=AWS_REGION)

def launch_fargate_transcoder(bucket_name: str, s3_key: str) -> bool:
    """
    Invokes the AWS ECS run_task API to spawn an ephemeral Fargate container
    with runtime overrides carrying S3 coordinates.
    """
    try:
        print(f"Spawning Fargate task for S3 Target: s3://{bucket_name}/{s3_key}")
        
        response = ecs_client.run_task(
            cluster=ECS_CLUSTER_NAME,
            launchType="FARGATE",
            taskDefinition=ECS_TASK_DEFINITION,
            overrides={
                "containerOverrides": [
                    {
                        "name": CONTAINER_NAME,
                        "environment": [
                            {"name": "S3_BUCKET", "value": bucket_name},
                            {"name": "S3_KEY", "value": s3_key}
                        ]
                    }
                ]
            },
            networkConfiguration={
                "awsvpcConfiguration": {
                    "subnets": VPC_SUBNETS,
                    "securityGroups": SECURITY_GROUPS,
                    "assignPublicIp": "ENABLED"  # Enabled to pull ECR images and upload to S3
                }
            }
        )
        
        task_arn = response["tasks"][0]["taskArn"]
        print(f"Fargate Task dispatched successfully. Task ARN: {task_arn}")
        return True
    except Exception as e:
        print(f"Critical failure launching ECS Task: {e}", file=sys.stderr)
        return False

def run_consumer():
    print("Initializing persistent SQS Polling daemon...")
    
    while True:
        try:
            # 1. Long Poll SQS to minimize network overhead and API call costs
            response = sqs_client.receive_message(
                QueueUrl=SQS_QUEUE_URL,
                MaxNumberOfMessages=1,
                WaitTimeSeconds=10  # Block thread up to 10s to await messages
            )
            
            messages = response.get("Messages", [])
            if not messages:
                continue  # Queue empty, cycle loop
                
            for message in messages:
                receipt_handle = message.get("ReceiptHandle")
                message_body = json.loads(message.get("Body"))
                
                # 2. Filter out AWS S3 Connection Test Events
                if "Service" in message_body and message_body.get("Event") == "s3:TestEvent":
                    print("Intercepted AWS S3 Test Event. Safe deletion.")
                    sqs_client.delete_message(QueueUrl=SQS_QUEUE_URL, ReceiptHandle=receipt_handle)
                    continue
                
                # 3. Parse valid S3 ObjectCreated events
                if "Records" in message_body:
                    for record in message_body["Records"]:
                        bucket_name = record["s3"]["bucket"]["name"]
                        # S3 object key is URL-encoded by default; decode formatting spaces
                        s3_key = record["s3"]["object"]["key"].replace("+", " ")
                        
                        # Only trigger pipeline for target MP4 videos
                        if s3_key.endswith(".mp4"):
                            print(f"Parsed Video Event: s3://{bucket_name}/{s3_key}")
                            
                            # Dispatch task
                            success = launch_fargate_transcoder(bucket_name, s3_key)
                            
                            if success:
                                # 4. Remove message from SQS to finalize transactions
                                sqs_client.delete_message(
                                    QueueUrl=SQS_QUEUE_URL,
                                    ReceiptHandle=receipt_handle
                                )
                                print("SQS transaction completed. Message purged.")
                            else:
                                print("Pipeline execution failed. Message preserved in queue for retry.")
                                
        except KeyboardInterrupt:
            print("\nShutting down Consumer gracefully...")
            break
        except Exception as e:
            print(f"Error executing SQS queue lookup loop: {e}", file=sys.stderr)
            time.sleep(5)  # Error mitigation backoff

if __name__ == "__main__":
    run_consumer()
```

---

## 4. Key Orchestration Best Practices

1.  **VPC Networking Rules**: Fargate containers require egress internet access to resolve API dependencies, fetch repository image layers from **ECR**, and write segments to public S3 buckets. Always run your task in public subnets with `assignPublicIp="ENABLED"` or in private subnets routed through an active **NAT Gateway**.
2.  **Idempotence & Dead Letter Queues (DLQ)**: Ensure that your raw video processing behaves idempotently. If a container crashes mid-stream, SQS will return the message to the queue after its **Visibility Timeout** expires. Configure an active **Dead Letter Queue (DLQ)** with a maximum receive count of 3 to safely isolate corrupted, un-transcodable video files.
3.  **Clean Purge Policies**: Always invoke `sqs_client.delete_message` **after** the `ecs_client.run_task` call returns a valid, successful Task ARN. Deleting the message prematurely risks silent processing dropouts if Fargate fails to provision.
