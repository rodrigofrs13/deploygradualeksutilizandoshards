#!/usr/bin/env bash
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
REPOSITORY="${ECR_REPOSITORY:-springboot-sharded-app}"
TAG="${1:-1.0.0}"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

aws ecr get-login-password --region "${REGION}" \
  | docker login --username AWS --password-stdin "${REGISTRY}"

cd "$(dirname "$0")/../apps"

mvn clean package -DskipTests

docker build -t "${REPOSITORY}:${TAG}" .
docker tag "${REPOSITORY}:${TAG}" "${REGISTRY}/${REPOSITORY}:${TAG}"
docker push "${REGISTRY}/${REPOSITORY}:${TAG}"

echo "Pushed ${REGISTRY}/${REPOSITORY}:${TAG}"
