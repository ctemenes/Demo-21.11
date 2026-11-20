#!/usr/bin/env bash
# Reads what the MuleSoft application needs straight from Azure, at deploy time.
# Nothing here is stored in the repository or typed by a person.
# In GitHub Actions it masks each secret and exports the values to later steps.
set -euo pipefail

RG="${RG:-rg-service-request-integration-dev}"
out() { az deployment group show -g "$RG" -n service-request-integration --query "properties.outputs.$1.value" -o tsv; }

FUNCTION_APP="$(out functionAppName)"
SB_NAMESPACE="$(out serviceBusNamespace)"
STORAGE="$(out storageAccount)"
CONTAINER="$(out assetContainer)"
QUEUE="$(out queueName)"

SB_KEY="$(az servicebus queue authorization-rule keys list -g "$RG" --namespace-name "$SB_NAMESPACE" \
  --queue-name "$QUEUE" --name mule-send --query primaryKey -o tsv)"
WORKS_KEY="$(az functionapp keys list -g "$RG" -n "$FUNCTION_APP" --query functionKeys.default -o tsv)"
# Read-only, one file, seven days. The weekly pipeline run replaces it before it expires.
EXPIRY="$(date -u -d '+7 days' '+%Y-%m-%dT%H:%MZ')"
ASSET_SAS="$(az storage blob generate-sas --account-name "$STORAGE" --container-name "$CONTAINER" \
  --name asset-register.csv --permissions r --expiry "$EXPIRY" --https-only --as-user --auth-mode login -o tsv)"

if [ -n "${GITHUB_ENV:-}" ]; then
  for secret in "$SB_KEY" "$WORKS_KEY" "$ASSET_SAS"; do echo "::add-mask::$secret"; done
  {
    echo "SB_NAMESPACE=$SB_NAMESPACE"
    echo "WORKS_HOST=$(out functionHost)"
    echo "ASSET_HOST=$STORAGE.blob.core.windows.net"
    echo "SB_KEY=$SB_KEY"
    echo "WORKS_KEY=$WORKS_KEY"
    echo "ASSET_SAS=$ASSET_SAS"
  } >> "$GITHUB_ENV"
  echo "Settings and secrets loaded for $FUNCTION_APP and $SB_NAMESPACE"
else
  echo "Run inside the pipeline. Refusing to print secrets to a terminal." >&2
  exit 1
fi
