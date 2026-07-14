#!/usr/bin/env bash
# Deploy the chDB analyst to Azure Container Apps as a scale-to-zero service.
#
# Creates (all in your subscription):
#   * a resource group, a Basic container registry, a Container Apps environment
#   * the image, built server-side by ACR Tasks from this directory's
#     Dockerfile (no local Docker needed) — the 1M-row store is baked in
#   * one container app: external ingress, 2 vCPU / 4 GiB, min-replicas 0
#
# Requires: az login, a subscription where you can create these resources.
# The script registers the Microsoft.App / Microsoft.ContainerRegistry /
# Microsoft.OperationalInsights providers if needed.
#
# Usage:
#   export ANTHROPIC_API_KEY=sk-...   # optional — omit to deploy /query only
#   ./deploy.sh                       # westus by default; REGION=... to override
set -euo pipefail
cd "$(dirname "$0")/../.."   # repo root: shared Dockerfile + src/ for the ACR build

REGION="${REGION:-westus}"
RG="${RESOURCE_GROUP:-chdb-analyst-rg}"
APP="${APP:-chdb-analyst}"
ENVIRONMENT="${ENVIRONMENT:-chdb-analyst-env}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
# ACR names are global and alphanumeric-only. Derive a deterministic name
# from the subscription + resource group so teardown recomputes the exact
# same one (no random suffix, no prefix-matching that could catch registries
# from other deployments in a shared group).
SUB=$(az account show --query id -o tsv)
ACR="${ACR:-chdbanalyst$(printf '%s/%s' "${SUB}" "${RG}" | shasum | cut -c1-12)}"

echo "==> region ${REGION}, resource group ${RG}"
for ns in Microsoft.App Microsoft.ContainerRegistry Microsoft.OperationalInsights; do
  az provider register -n "$ns" --wait -o none
done
# create the group only if it doesn't already exist, and tag the one we create
# so teardown can tell ours apart from a pre-existing (possibly empty) group
if az group show -n "${RG}" >/dev/null 2>&1; then
  echo "    (resource group ${RG} already exists — leaving its ownership alone)"
else
  az group create -n "${RG}" -l "${REGION}" --tags chdb-cookbook=true -o none
fi

echo "==> registry ${ACR} + server-side image build (bakes the 1M-row store)"
# tag every resource we create with chdb-cookbook so teardown can remove them
# even when they live in a pre-existing (untaggable) resource group.
# No admin user: the app pulls with a managed identity (below), so no
# registry password ever lands in a command line.
az acr create -g "${RG}" -n "${ACR}" --sku Basic --admin-enabled false \
  --tags chdb-cookbook=true -o none
az acr build -r "${ACR}" -t chdb-analyst:v1 \
  --build-arg BAKE_PARTITIONS="${BAKE_PARTITIONS:-1}" . 2>&1 | tail -2

echo "==> Container Apps environment ${ENVIRONMENT}"
az containerapp env create -g "${RG}" -n "${ENVIRONMENT}" -l "${REGION}" \
  --logs-destination none --tags chdb-cookbook=true -o none

ENV_FLAG=()
if [ -n "${ANTHROPIC_API_KEY}" ]; then
  # env var for a demo; use --secrets + secretref for production
  ENV_FLAG=(--env-vars "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}")
fi
# /query runs caller-supplied ClickHouse SQL, so an internet-facing endpoint
# lets anyone who finds the FQDN run arbitrary (and mutating) queries. Deploy
# with internal ingress by default; PUBLIC=1 switches to external for a
# throwaway public demo — front it with Container Apps auth for anything real.
if [ "${PUBLIC:-}" = "1" ]; then
  echo "!! PUBLIC=1: exposing an external endpoint that executes arbitrary SQL."
  INGRESS=external
else
  INGRESS=internal
fi
# pull with the app's system-assigned managed identity — the CLI assigns the
# registry's AcrPull role to it, so no registry password is passed in argv
az containerapp create -g "${RG}" -n "${APP}" --environment "${ENVIRONMENT}" \
  --image "${ACR}.azurecr.io/chdb-analyst:v1" \
  --registry-server "${ACR}.azurecr.io" --registry-identity system \
  --cpu 2 --memory 4Gi --min-replicas 0 --max-replicas 3 \
  --ingress "${INGRESS}" --target-port 8080 --tags chdb-cookbook=true "${ENV_FLAG[@]}" -o none

URL="https://$(az containerapp show -g "${RG}" -n "${APP}" \
  --query properties.configuration.ingress.fqdn -o tsv)"
echo "==> service ${URL} (ingress: ${INGRESS})"

if [ "${INGRESS}" = "external" ]; then
  python3 - "$URL" <<'EOF'
import sys, time, urllib.request
url = sys.argv[1]
t0 = time.time()
body = urllib.request.urlopen(f"{url}/health", timeout=180).read().decode()
print(f"==> first hit (cold: instance start + engine init): {(time.time()-t0)*1000:.0f} ms")
print(f"    {body}")
for _ in range(3):
    t0 = time.time()
    urllib.request.urlopen(f"{url}/health", timeout=30).read()
    print(f"==> warm hit: {(time.time()-t0)*1000:.0f} ms")
EOF
  cat <<EOF

Deployed (public). Talk to the analyst:

  curl -s ${URL}/query -H 'Content-Type: application/json' \\
    -d '{"sql": "SELECT RegionID, count() AS hits FROM demo.hits GROUP BY RegionID ORDER BY hits DESC LIMIT 5"}'
  curl -s ${URL}/ask -H 'Content-Type: application/json' \\
    -d '{"question": "Which regions drive the most traffic?"}'
EOF
else
  cat <<EOF

Deployed (internal ingress — reachable only inside the Container Apps
environment's network, not from your laptop). Reach it from a workload in
the same environment, or redeploy with PUBLIC=1 for a throwaway public URL.
EOF
fi

cat <<EOF

Scale-to-zero: with no traffic the replica count drops to 0 and compute
stops billing; the next request pays the cold start.

Teardown: ./teardown.sh   (RESOURCE_GROUP=${RG})
EOF
