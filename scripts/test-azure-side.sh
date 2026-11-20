#!/usr/bin/env bash
# Checks the Azure half on its own: puts one canonical message on the queue the way
# MuleSoft will, then asks the works system for it. Run from a signed-in shell.
set -euo pipefail

RG="${RG:-rg-service-request-integration-dev}"
out() { az deployment group show -g "$RG" -n service-request-integration --query "properties.outputs.$1.value" -o tsv; }
NS="$(out serviceBusNamespace)"; QUEUE="$(out queueName)"; HOST="$(out functionHost)"; APP="$(out functionAppName)"

ME="$(az ad signed-in-user show --query id -o tsv)"
NS_ID="$(az servicebus namespace show -g "$RG" -n "$NS" --query id -o tsv)"
az role assignment create --assignee-object-id "$ME" --assignee-principal-type User \
  --role "Azure Service Bus Data Sender" --scope "$NS_ID" --output none 2>/dev/null || true

ID="SR-$(date -u +%Y%m%d)-$(tr -dc 'A-Z0-9' </dev/urandom | head -c 6)"
BODY=$(cat <<JSON
{"schemaVersion":"1.0","trackingId":"$ID","correlationId":"azure-side-test","receivedAt":"$(date -u +%Y-%m-%dT%H:%M:%S)+00:00",
 "source":{"system":"test-azure-side","channel":"web"},
 "request":{"category":"street_light","priority":"MEDIUM","description":"Azure-side test: street light out near the bus stop."},
 "routing":{"department":"Roads and Drainage","slaHours":120},
 "location":{"address":"1 Test Street","suburb":"TOOWONG","postcode":"4066"},
 "reporter":{"name":"Azure Side Test","email":"test@example.com"}}
JSON
)

echo "Sending $ID to $NS/$QUEUE"
for attempt in 1 2 3 4 5 6; do
  TOKEN="$(az account get-access-token --resource https://servicebus.azure.net --query accessToken -o tsv)"
  CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST "https://$NS.servicebus.windows.net/$QUEUE/messages" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -H "BrokerProperties: {\"MessageId\":\"$ID\",\"Label\":\"service-request.v1\"}" -d "$BODY")"
  [ "$CODE" = "201" ] && break
  echo "   queue answered $CODE, waiting for the sender role to take effect ($attempt)"; sleep 20
done
[ "$CODE" = "201" ] || { echo "Could not send to the queue."; exit 1; }

KEY="$(az functionapp keys list -g "$RG" -n "$APP" --query functionKeys.default -o tsv)"
for attempt in $(seq 1 24); do
  CODE="$(curl -s -o /tmp/status.json -w '%{http_code}' -H "x-functions-key: $KEY" "https://$HOST/api/service-requests/$ID")"
  if [ "$CODE" = "200" ]; then echo "Stored and readable:"; cat /tmp/status.json; echo; exit 0; fi
  echo "   works system answered $CODE, waiting ($attempt)"; sleep 5
done
echo "The message was not stored in time. Check the Function App logs."; exit 1
