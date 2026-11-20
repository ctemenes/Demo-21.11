"""Works management system: the Azure side of the service request integration.

- Queue trigger: stores each service request from the Service Bus queue.
- HTTP API: status lookups, bulk asset upserts from the ETL job, ETL run reports.
"""
import json
import logging

import azure.functions as func

from works import mapping, store

app = func.FunctionApp()


def _json(body, status: int = 200) -> func.HttpResponse:
    return func.HttpResponse(json.dumps(body), status_code=status, mimetype="application/json")


@app.function_name("store_service_request")
@app.service_bus_queue_trigger(
    arg_name="msg", queue_name="%SERVICEBUS_QUEUE%", connection="ServiceBusConnection"
)
def store_service_request(msg: func.ServiceBusMessage) -> None:
    """Store one service request. Safe to run twice for the same message.

    If the message is malformed or the database is down, the exception sends it
    back to the queue. After the queue's maximum delivery count it moves to the
    dead-letter queue, where nothing is lost and someone can look at it.
    """
    try:
        message = json.loads(msg.get_body().decode("utf-8"))
        row = mapping.canonical_to_row(message)
    except (ValueError, UnicodeDecodeError) as exc:
        logging.error("Rejected message messageId=%s delivery=%s reason=%s",
                      msg.message_id, msg.delivery_count, exc)
        raise
    action = store.upsert_service_request(row)
    logging.info("Stored trackingId=%s correlationId=%s action=%s delivery=%s",
                 row["TrackingId"], row["CorrelationId"], action, msg.delivery_count)


@app.route(route="service-requests/{tracking_id}", methods=["GET"], auth_level=func.AuthLevel.FUNCTION)
def get_service_request(req: func.HttpRequest) -> func.HttpResponse:
    tracking_id = req.route_params.get("tracking_id", "")
    if not mapping.TRACKING_ID.match(tracking_id):
        return _json({"error": "tracking id is not in the expected format"}, 400)
    row = store.get_service_request(tracking_id)
    if row is None:
        return _json({"error": "not found"}, 404)
    return _json(mapping.row_to_works_record(row))


@app.route(route="assets/batch", methods=["PUT"], auth_level=func.AuthLevel.FUNCTION)
def upsert_assets(req: func.HttpRequest) -> func.HttpResponse:
    try:
        run_id, assets = mapping.check_asset_batch(req.get_json())
    except ValueError as exc:
        return _json({"error": str(exc)}, 400)
    result = store.upsert_assets(run_id, assets)
    logging.info("Asset block run=%s received=%s inserted=%s updated=%s",
                 run_id, result["received"], result["inserted"], result["updated"])
    return _json(result)


@app.route(route="etl-runs", methods=["POST"], auth_level=func.AuthLevel.FUNCTION)
def record_etl_run(req: func.HttpRequest) -> func.HttpResponse:
    try:
        report = req.get_json()
        if not isinstance(report, dict) or not report.get("runId"):
            raise ValueError("runId is required")
    except ValueError as exc:
        return _json({"error": str(exc)}, 400)
    store.record_etl_run(report)
    logging.info("ETL run recorded run=%s total=%s loaded=%s rejected=%s", report.get("runId"),
                 report.get("totalRows"), report.get("loadedRows"), report.get("rejectedRows"))
    return _json({"recorded": report["runId"]}, 201)


@app.route(route="health", methods=["GET"], auth_level=func.AuthLevel.ANONYMOUS)
def health(req: func.HttpRequest) -> func.HttpResponse:
    return _json({"status": "UP", "system": "works-management"})
