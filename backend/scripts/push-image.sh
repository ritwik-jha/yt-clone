#!/usr/bin/env bash
#
# Build the backend image and push it to the ECR repo created by
# backend/terraform. Run from anywhere; paths resolve off this script.
#
# The build platform must match backend/terraform's cpu_architecture
# (t4g.* instances are arm64). A mismatch produces an image the instance
# cannot run, and `docker compose up` fails with "exec format error".
#
# Usage:
#   scripts/push-image.sh              # tag from terraform (default: latest)
#   scripts/push-image.sh v3           # explicit tag
#   PLATFORM=linux/amd64 scripts/push-image.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="${TF_DIR:-$BACKEND_ROOT/terraform}"

die() { echo "error: $*" >&2; exit 1; }

command -v terraform >/dev/null || die "terraform is required"
command -v docker >/dev/null || die "docker is required"

tf() { terraform -chdir="$TF_DIR" output -raw "$1" 2>/dev/null; }

ECR_URL="$(tf ecr_repository_url)" || true
[[ -n "${ECR_URL:-}" ]] || die "no ecr_repository_url output — apply $TF_DIR first"

AWS_REGION="$(tf aws_region 2>/dev/null || true)"
[[ -n "$AWS_REGION" ]] || AWS_REGION="$(cut -d. -f4 <<<"$ECR_URL")"

TAG="${1:-}"
if [[ -z "$TAG" ]]; then
  IMAGE_REF="$(tf backend_image)" || die "could not determine image tag"
  TAG="${IMAGE_REF##*:}"
fi

# arm64 matches the t4g.small default in terraform.tfvars.example.
PLATFORM="${PLATFORM:-linux/arm64}"
REGISTRY="${ECR_URL%%/*}"

echo "building $ECR_URL:$TAG for $PLATFORM" >&2

aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null

docker buildx build \
  --platform "$PLATFORM" \
  -t "$ECR_URL:$TAG" \
  --push \
  "$BACKEND_ROOT"

echo "pushed $ECR_URL:$TAG" >&2
