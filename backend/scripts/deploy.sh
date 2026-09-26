#!/usr/bin/env bash
#
# Runs ON the EC2 instance, as root, via the video-backend systemd unit.
#
#   1. Pull the dotenv out of SSM Parameter Store into /opt/video-backend/.env
#   2. Authenticate to ECR
#   3. Pull the backend image and bring both containers up
#
# Idempotent: safe to re-run after pushing a new image or a new .env.
# Configuration comes from /etc/video-backend/deploy.conf, written by the
# instance user_data in backend/terraform/ec2.tf.

set -euo pipefail

CONF_FILE=/etc/video-backend/deploy.conf
APP_DIR=/opt/video-backend
ENV_FILE="$APP_DIR/.env"

die() { echo "deploy: $*" >&2; exit 1; }
log() { echo "deploy: $*"; }

[[ -f "$CONF_FILE" ]] || die "$CONF_FILE not found"
# shellcheck source=/dev/null
. "$CONF_FILE"

: "${AWS_REGION:?not set in $CONF_FILE}"
: "${ENV_PARAM:?not set in $CONF_FILE}"
: "${BACKEND_IMAGE:?not set in $CONF_FILE}"
: "${ECR_REGISTRY:?not set in $CONF_FILE}"

# --- 1. dotenv from SSM ---------------------------------------------------

log "fetching $ENV_PARAM"
ENV_BODY="$(aws ssm get-parameter \
  --name "$ENV_PARAM" \
  --with-decryption \
  --region "$AWS_REGION" \
  --query Parameter.Value \
  --output text)" || die "could not read $ENV_PARAM"

# Terraform seeds the parameter with a placeholder so that `apply` never has
# to hold the Cognito secret. Until generate-env.sh --push-ssm overwrites it
# there is nothing to start, and failing loudly is better than booting the
# containers into a crash loop on missing config.
case "$ENV_BODY" in
  PLACEHOLDER*)
    die "$ENV_PARAM still holds the Terraform placeholder — run 'backend/scripts/generate-env.sh --push-ssm' from your workstation, then retry"
    ;;
esac

install -d -m 755 "$APP_DIR"
umask 077
printf '%s\n' "$ENV_BODY" >"$ENV_FILE"
chmod 600 "$ENV_FILE"
umask 022

# --- 2. ECR login ---------------------------------------------------------

log "logging in to $ECR_REGISTRY"
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY" >/dev/null

# --- 3. bring the stack up ------------------------------------------------

cd "$APP_DIR"

export BACKEND_IMAGE AWS_REGION
export LOG_GROUP="${LOG_GROUP:-/video-backend}"
# Container ports bind on all interfaces here; the instance security group is
# what decides who can actually reach them.
export API_BIND="${API_BIND:-0.0.0.0}"

log "pulling $BACKEND_IMAGE"
docker compose pull

log "starting containers"
docker compose up -d --remove-orphans

# Keep the root volume from filling with superseded image layers.
docker image prune -f >/dev/null

docker compose ps
log "done"
