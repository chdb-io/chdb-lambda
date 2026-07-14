#!/usr/bin/env bash
# Remove what deploy.sh created, identified by the chdb-cookbook tag it stamps
# on every resource — so this works even when deploy.sh targeted a pre-existing
# resource group, and never deletes a same-named resource it didn't create.
# The resource group itself is deleted only if deploy.sh created it (the group
# carries the tag) and it ends up empty.
set -euo pipefail

RG="${RESOURCE_GROUP:-chdb-analyst-rg}"
APP="${APP:-chdb-analyst}"
ENVIRONMENT="${ENVIRONMENT:-chdb-analyst-env}"

if ! az group show -n "${RG}" >/dev/null 2>&1; then
  echo "    (no resource group ${RG} to clean up)"; exit 0
fi

# delete a named resource only if it carries our tag
tagged() {  # <resource-id>
  [ "$(az resource show --ids "$1" --query "tags.\"chdb-cookbook\"" -o tsv 2>/dev/null)" = "true" ]
}

APP_ID=$(az containerapp show -g "${RG}" -n "${APP}" --query id -o tsv 2>/dev/null || true)
if [ -n "${APP_ID}" ] && tagged "${APP_ID}"; then
  echo "==> deleting container app ${APP}"
  az containerapp delete -g "${RG}" -n "${APP}" --yes -o none
else
  echo "    (container app ${APP} absent or not cookbook-tagged — leaving it)"
fi

ENV_ID=$(az containerapp env show -g "${RG}" -n "${ENVIRONMENT}" --query id -o tsv 2>/dev/null || true)
if [ -n "${ENV_ID}" ] && tagged "${ENV_ID}"; then
  echo "==> deleting Container Apps environment ${ENVIRONMENT}"
  az containerapp env delete -g "${RG}" -n "${ENVIRONMENT}" --yes -o none
else
  echo "    (environment ${ENVIRONMENT} absent or not cookbook-tagged — leaving it)"
fi

# recompute the exact registry name deploy.sh derived (subscription + RG)
SUB=$(az account show --query id -o tsv)
ACR="${ACR:-chdbanalyst$(printf '%s/%s' "${SUB}" "${RG}" | shasum | cut -c1-12)}"
ACR_ID=$(az acr show -n "${ACR}" -g "${RG}" --query id -o tsv 2>/dev/null || true)
if [ -n "${ACR_ID}" ] && tagged "${ACR_ID}"; then
  echo "==> deleting registry ${ACR}"
  az acr delete -n "${ACR}" -g "${RG}" --yes -o none
else
  echo "    (registry ${ACR} absent or not cookbook-tagged — leaving it)"
fi

# delete the group only if deploy.sh created it (tag) and it's now empty
OWNED=$(az group show -n "${RG}" --query "tags.\"chdb-cookbook\"" -o tsv 2>/dev/null)
if [ "${OWNED}" = "true" ] && [ "$(az resource list -g "${RG}" --query 'length(@)' -o tsv 2>/dev/null)" = "0" ]; then
  echo "==> resource group ${RG} is cookbook-created and empty — deleting it"
  az group delete -n "${RG}" --yes
else
  echo "==> leaving resource group ${RG} (not cookbook-created, or not empty)"
fi
echo "done."
