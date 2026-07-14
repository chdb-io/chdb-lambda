#!/usr/bin/env bash
# Deploy the chDB analyst as a classic AWS Lambda container function.
#
# Creates (all in your account):
#   * an ECR repository and the image (built locally with docker/podman —
#     chDB exceeds the 250 MB zip limit, so container packaging is the way)
#   * a minimal execution role
#   * one Lambda function (4 GB, x86_64) with a public Function URL
#
# The image is the base's shared image; the Lambda Web Adapter it carries
# translates invocations into HTTP against the uvicorn app on Lambda and is
# inert on every other platform.
#
# Requires: AWS CLI v2 with credentials, docker or podman.
#
# Usage:
#   export ANTHROPIC_API_KEY=sk-...   # optional — omit to deploy /query only
#   ./deploy.sh                       # us-west-2 by default; REGION=... to override
set -euo pipefail
# repo root = two levels up from deploy/aws-lambda/ — the shared image and
# package (src/, pyproject.toml, Dockerfile) live there
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

REGION="${REGION:-us-west-2}"
NAME="${NAME:-chdb-analyst}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
DOCKER="${DOCKER:-docker}"   # DOCKER=podman works too
BAKE_PARTITIONS="${BAKE_PARTITIONS:-1}"

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
ECR="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
IMAGE="${ECR}/${NAME}:v1"
echo "==> account ${ACCOUNT}, region ${REGION}"

# --- 1. registry + image ------------------------------------------------------
# refuse to reuse a same-named repo this script didn't create — otherwise we'd
# overwrite its v1 tag with the chDB image. Tag the repo we create so reruns
# and teardown can tell it's ours.
if aws ecr describe-repositories --repository-names "${NAME}" --region "${REGION}" >/dev/null 2>&1; then
  OWN=$(aws ecr list-tags-for-resource --resource-arn \
    "arn:aws:ecr:${REGION}:$(aws sts get-caller-identity --query Account --output text):repository/${NAME}" \
    --query "tags[?Key=='chdb-cookbook'].Value" --output text 2>/dev/null)
  if [ "${OWN}" != "true" ]; then
    echo "refusing to reuse existing ECR repo '${NAME}' (not created by this script)."
    echo "set NAME=<name> to use a different repository."; exit 1
  fi
else
  aws ecr create-repository --repository-name "${NAME}" \
    --tags Key=chdb-cookbook,Value=true --region "${REGION}" >/dev/null
fi
aws ecr get-login-password --region "${REGION}" \
  | ${DOCKER} login --username AWS --password-stdin "${ECR}"
echo "==> building the shared image (bakes the store; needs an amd64 builder)"
${DOCKER} build --platform linux/amd64 -f "${ROOT}/Dockerfile" \
  --build-arg BAKE_PARTITIONS="${BAKE_PARTITIONS}" -t "${IMAGE}" "${ROOT}"
${DOCKER} push "${IMAGE}" | tail -1

# --- 2. execution role ---------------------------------------------------------
ROLE="${NAME}-exec-role"
if aws iam get-role --role-name "${ROLE}" >/dev/null 2>&1; then
  # refuse to touch a same-named role this script didn't create — otherwise we'd
  # attach policies to an unrelated role (and its trust policy may not even
  # allow lambda to assume it)
  OWN=$(aws iam list-role-tags --role-name "${ROLE}" \
    --query "Tags[?Key=='chdb-cookbook'].Value" --output text 2>/dev/null)
  if [ "${OWN}" != "true" ]; then
    echo "refusing to use existing role '${ROLE}' (not created by this script)."
    echo "set NAME=<name> to use a different role."; exit 1
  fi
else
  aws iam create-role --role-name "${ROLE}" \
    --tags Key=chdb-cookbook,Value=true \
    --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{"Effect": "Allow",
                   "Principal": {"Service": "lambda.amazonaws.com"},
                   "Action": "sts:AssumeRole"}]}' >/dev/null
  sleep 10   # IAM propagation before the function can assume it
fi
# attaching an already-attached managed policy is a no-op, so run it every
# time — otherwise a run that created the role but failed here would leave it
# permanently without log permissions
aws iam attach-role-policy --role-name "${ROLE}" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${ROLE}"

# --- 3. the function + a public URL -------------------------------------------
ENV_VARS="Variables={PORT=8080"
[ -n "${ANTHROPIC_API_KEY}" ] && ENV_VARS+=",ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}"
ENV_VARS+="}"
# Lambda's container filesystem is read-only except /tmp, and chDB needs a
# writable data directory (status file, locks). The command override copies
# the baked store to /tmp at boot — the image itself stays byte-identical
# to the Cloud Run / Container Apps recipes.
# rm the destination first: Lambda keeps /tmp across an execution-environment
# reset, so a bare `cp -r` onto an existing dir would nest chdb-data/chdb-data
BOOT_CMD='rm -rf /tmp/chdb-data; cp -r /app/chdb-data /tmp/chdb-data; CHDB_STORE=local:/tmp/chdb-data exec python -m chdb_serverless.server'
if aws lambda get-function --function-name "${NAME}" --region "${REGION}" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "${NAME}" \
    --image-uri "${IMAGE}" --region "${REGION}" >/dev/null
  aws lambda wait function-updated-v2 --function-name "${NAME}" --region "${REGION}"
  # re-apply env AND the image-config command + ephemeral storage on redeploy —
  # otherwise a function created without the /tmp override (or by an older
  # script) keeps the default CMD and crashes on Lambda's read-only /app
  aws lambda update-function-configuration --function-name "${NAME}" \
    --environment "${ENV_VARS}" --ephemeral-storage Size=1024 \
    --image-config "{\"Command\":[\"sh\",\"-c\",\"${BOOT_CMD}\"]}" \
    --region "${REGION}" >/dev/null
  aws lambda wait function-updated-v2 --function-name "${NAME}" --region "${REGION}"
else
  aws lambda create-function --function-name "${NAME}" \
    --package-type Image --code "ImageUri=${IMAGE}" \
    --role "${ROLE_ARN}" --architectures x86_64 \
    --memory-size 4096 --timeout 120 --ephemeral-storage Size=1024 \
    --image-config "{\"Command\":[\"sh\",\"-c\",\"${BOOT_CMD}\"]}" \
    --environment "${ENV_VARS}" --tags chdb-cookbook=true --region "${REGION}" >/dev/null
fi
aws lambda wait function-active-v2 --function-name "${NAME}" --region "${REGION}"

# /query runs caller-supplied SQL and /ask spends real model tokens, so a
# public URL is an open door + a bill. Default the Function URL to AWS_IAM
# (callers SigV4-sign); PUBLIC=1 opts into an unauthenticated NONE URL for a
# throwaway demo — front it with your own auth before exposing anything real.
if [ "${PUBLIC:-}" = "1" ]; then
  echo "!! PUBLIC=1: unauthenticated Function URL — anyone can run SQL and spend /ask tokens."
  AUTH_TYPE=NONE
else
  AUTH_TYPE=AWS_IAM
fi
if URL=$(aws lambda get-function-url-config --function-name "${NAME}" \
           --region "${REGION}" --query FunctionUrl --output text 2>/dev/null); then
  # reconcile the auth mode on redeploy — a URL previously created as NONE
  # must flip back to AWS_IAM when rerun without PUBLIC (and vice versa)
  aws lambda update-function-url-config --function-name "${NAME}" \
    --auth-type "${AUTH_TYPE}" --region "${REGION}" >/dev/null
else
  URL=$(aws lambda create-function-url-config --function-name "${NAME}" \
          --auth-type "${AUTH_TYPE}" --region "${REGION}" --query FunctionUrl --output text)
fi
if [ "${AUTH_TYPE}" = "NONE" ]; then
  # a public (NONE) URL needs both actions under AWS's current model; add-permission
  # errors if the statement-id exists, so || true makes each idempotent/self-healing
  aws lambda add-permission --function-name "${NAME}" \
    --action lambda:InvokeFunctionUrl --principal '*' \
    --function-url-auth-type NONE --statement-id public-url \
    --region "${REGION}" >/dev/null 2>&1 || true
  aws lambda add-permission --function-name "${NAME}" \
    --action lambda:InvokeFunction --principal '*' \
    --function-url-auth-type NONE --statement-id public-url-invoke \
    --region "${REGION}" >/dev/null 2>&1 || true
else
  # flipping back to IAM: drop any public grants a previous PUBLIC=1 run left
  aws lambda remove-permission --function-name "${NAME}" --statement-id public-url \
    --region "${REGION}" >/dev/null 2>&1 || true
  aws lambda remove-permission --function-name "${NAME}" --statement-id public-url-invoke \
    --region "${REGION}" >/dev/null 2>&1 || true
fi
URL="${URL%/}"
echo "==> function URL ${URL} (auth: ${AUTH_TYPE})"

# --- 4. smoke test with timings (only for a public URL — an IAM URL needs a
#        SigV4-signed request, so we print how to reach it instead) ----------
if [ "${AUTH_TYPE}" = "NONE" ]; then
  python3 - "$URL" <<'EOF'
import sys, time, urllib.request
url = sys.argv[1]
t0 = time.time()
body = urllib.request.urlopen(f"{url}/health", timeout=180).read().decode()
print(f"==> first hit (cold: sandbox init + engine init): {(time.time()-t0)*1000:.0f} ms")
print(f"    {body}")
for _ in range(3):
    t0 = time.time()
    urllib.request.urlopen(f"{url}/health", timeout=30).read()
    print(f"==> warm hit: {(time.time()-t0)*1000:.0f} ms")
EOF
fi

if [ "${AUTH_TYPE}" = "NONE" ]; then
cat <<EOF

Deployed (public). Talk to the analyst:

  curl -s ${URL}/query -H 'Content-Type: application/json' \\
    -d '{"sql": "SELECT RegionID, count() AS hits FROM demo.hits GROUP BY RegionID ORDER BY hits DESC LIMIT 5"}'
  curl -s ${URL}/ask -H 'Content-Type: application/json' \\
    -d '{"question": "Which regions drive the most traffic?"}'

Idle costs nothing (per-request billing); the next request after an idle
gap pays the cold start you measured above.

Teardown: ./teardown.sh
EOF
else
cat <<EOF

Deployed (private, auth: AWS_IAM). The Function URL requires a SigV4-signed
request — call it with an IAM identity, e.g.:

  awscurl --service lambda --region ${REGION} ${URL}/health

or run PUBLIC=1 ./deploy.sh for a throwaway unauthenticated URL.

Teardown: ./teardown.sh
EOF
fi
