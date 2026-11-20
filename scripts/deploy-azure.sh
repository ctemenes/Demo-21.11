#!/usr/bin/env bash
# Deploys the Azure side from a signed-in shell (Azure Cloud Shell or a pipeline agent).
# Idempotent: run it again after any change.
set -euo pipefail

RG="${RG:-rg-service-request-integration-dev}"
LOCATION="${LOCATION:-australiaeast}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "== 1. Infrastructure (Bicep) =="
az group create --name "$RG" --location "$LOCATION" --output none
ADMIN_ID="${SQL_ADMIN_OBJECT_ID:-$(az ad signed-in-user show --query id -o tsv)}"
ADMIN_LOGIN="${SQL_ADMIN_LOGIN:-$(az ad signed-in-user show --query userPrincipalName -o tsv)}"
az deployment group create --resource-group "$RG" --name service-request-integration \
  --template-file "$ROOT/azure/infra/main.bicep" \
  --parameters sqlAdminObjectId="$ADMIN_ID" sqlAdminLogin="$ADMIN_LOGIN" --output none
out() { az deployment group show -g "$RG" -n service-request-integration --query "properties.outputs.$1.value" -o tsv; }
FUNCTION_APP="$(out functionAppName)"; FUNCTION_HOST="$(out functionHost)"
SB_NAMESPACE="$(out serviceBusNamespace)"; STORAGE="$(out storageAccount)"
SQL_HOST="$(out sqlServerHost)"; SQL_DB="$(out sqlDatabase)"; CONTAINER="$(out assetContainer)"

echo "== 2. Database schema and the Function App's database user =="
python3 "$ROOT/scripts/sql_apply.py" --resource-group "$RG" --server "$SQL_HOST" --database "$SQL_DB" \
  --schema "$ROOT/azure/sql/schema.sql" --grant-identity "$FUNCTION_APP"

echo "== 3. Works system code (Azure Functions) =="
PACKAGE="$(mktemp -d)/works-system.zip"
(cd "$ROOT/azure/functions" && zip -qr "$PACKAGE" . -x 'tests/*' -x '__pycache__/*' -x '*/__pycache__/*' -x '.pytest_cache/*')
az functionapp deployment source config-zip --resource-group "$RG" --name "$FUNCTION_APP" \
  --src "$PACKAGE" --build-remote true --output none

echo "== 4. Sample asset register file =="
ME="$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)"
STORAGE_ID="$(az storage account show -g "$RG" -n "$STORAGE" --query id -o tsv)"
if [ -n "$ME" ]; then
  az role assignment create --assignee-object-id "$ME" --assignee-principal-type User \
    --role "Storage Blob Data Contributor" --scope "$STORAGE_ID" --output none 2>/dev/null || true
fi
for attempt in 1 2 3 4 5 6; do
  if az storage blob upload --auth-mode login --account-name "$STORAGE" --container-name "$CONTAINER" \
       --name asset-register.csv --file "$ROOT/data/asset-register.csv" --overwrite --output none 2>/dev/null; then
    break
  fi
  echo "   waiting for the storage role to take effect ($attempt)"; sleep 20
done

echo "== 5. Check the works system answers =="
curl -fsS "https://$FUNCTION_HOST/api/health" && echo

cat <<SUMMARY

Deployed. Non-secret settings for the MuleSoft application:
  servicebus.namespace = $SB_NAMESPACE
  works.host           = $FUNCTION_HOST
  assetfile.host       = $STORAGE.blob.core.windows.net
Secrets are not printed. scripts/mule-secrets.sh reads them straight from Azure at deploy time.
SUMMARY
