#!/usr/bin/env bash
# Remove everything deploy.sh created: the Cloud Run service and the
# container images Cloud Build pushed for it.
set -euo pipefail

REGION="${REGION:-us-central1}"
SERVICE="${SERVICE:-chdb-analyst}"
PROJECT=$(gcloud config get-value project 2>/dev/null)

echo "==> deleting service ${SERVICE}"
LABEL=$(gcloud run services describe "${SERVICE}" --region "${REGION}" \
  --format 'value(metadata.labels.chdb-cookbook)' 2>/dev/null || true)
if [ "${LABEL}" = "true" ]; then
  gcloud run services delete "${SERVICE}" --region "${REGION}" --quiet
elif [ -n "$(gcloud run services describe "${SERVICE}" --region "${REGION}" --format 'value(metadata.name)' 2>/dev/null || true)" ]; then
  echo "    (service ${SERVICE} exists but isn't cookbook-labeled — leaving it and its images)"
  echo "done."; exit 0
else
  echo "    (no service to delete)"
fi

# `gcloud run deploy --source` pushes images into the auto-created
# cloud-run-source-deploy repository; delete ours to stop storage charges.
# --include-tags makes the listing emit digest versions (without it the
# version column is empty and nothing gets deleted).
REPO="${REGION}-docker.pkg.dev/${PROJECT}/cloud-run-source-deploy/${SERVICE}"
echo "==> deleting images under ${REPO}"
DIGESTS=$(gcloud artifacts docker images list "${REPO}" \
  --include-tags --format='value(version)' 2>/dev/null || true)
if [ -n "${DIGESTS}" ]; then
  echo "${DIGESTS}" | while read -r v; do
    [ -n "${v}" ] && gcloud artifacts docker images delete "${REPO}@${v}" --delete-tags --quiet
  done
else
  echo "    (no images to delete)"
fi

SECRET="${SERVICE}-anthropic-key"
if gcloud secrets describe "${SECRET}" >/dev/null 2>&1; then
  echo "==> deleting secret ${SECRET}"
  gcloud secrets delete "${SECRET}" --quiet
fi

echo "done."
