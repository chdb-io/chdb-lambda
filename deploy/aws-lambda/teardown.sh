#!/usr/bin/env bash
# Remove everything deploy.sh created: the function and its URL, the
# execution role, and the ECR repository with its images.
set -euo pipefail

REGION="${REGION:-us-west-2}"
NAME="${NAME:-chdb-analyst}"
ROLE="${NAME}-exec-role"

# only delete resources deploy.sh tagged as ours, so a pre-existing function
# or role that happens to share the name is never destroyed
FN_ARN="arn:aws:lambda:${REGION}:$(aws sts get-caller-identity --query Account --output text):function:${NAME}"
echo "==> deleting function ${NAME}"
if aws lambda get-function --function-name "${NAME}" --region "${REGION}" >/dev/null 2>&1; then
  if aws lambda list-tags --resource "${FN_ARN}" --query 'Tags."chdb-cookbook"' --output text 2>/dev/null | grep -q true; then
    aws lambda delete-function-url-config --function-name "${NAME}" --region "${REGION}" 2>/dev/null || true
    aws lambda delete-function --function-name "${NAME}" --region "${REGION}"
  else
    echo "    (function ${NAME} is not tagged chdb-cookbook — leaving it)"
  fi
else
  echo "    (no function to delete)"
fi

echo "==> deleting role ${ROLE}"
if aws iam get-role --role-name "${ROLE}" >/dev/null 2>&1; then
  if aws iam list-role-tags --role-name "${ROLE}" --query 'Tags[?Key==`chdb-cookbook`].Value' --output text 2>/dev/null | grep -q true; then
    aws iam detach-role-policy --role-name "${ROLE}" \
      --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null || true
    aws iam delete-role --role-name "${ROLE}"
  else
    echo "    (role ${ROLE} is not tagged chdb-cookbook — leaving it)"
  fi
else
  echo "    (no role to delete)"
fi

echo "==> removing our image from ECR repository ${NAME}"
if aws ecr describe-repositories --repository-names "${NAME}" --region "${REGION}" >/dev/null 2>&1; then
  # delete only the tag we pushed, then drop the repo only if it's now empty —
  # never force-delete a repo that already held unrelated images
  aws ecr batch-delete-image --repository-name "${NAME}" --region "${REGION}" \
    --image-ids imageTag=v1 >/dev/null 2>&1 || true
  if [ "$(aws ecr list-images --repository-name "${NAME}" --region "${REGION}" \
            --query 'length(imageIds)' --output text 2>/dev/null)" = "0" ]; then
    aws ecr delete-repository --repository-name "${NAME}" --region "${REGION}" >/dev/null
    echo "    repository was empty — deleted"
  else
    echo "    repository still holds other images — leaving it"
  fi
else
  echo "    (no repository to delete)"
fi

echo "done."
