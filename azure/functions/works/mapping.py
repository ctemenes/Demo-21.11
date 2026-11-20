"""Pure mapping and validation for the works management system.

No Azure or database imports here, so every rule can be unit tested.
"""
from __future__ import annotations

import re
from datetime import datetime, timezone

SUPPORTED_SCHEMA_MAJOR = "1"
CATEGORIES = {
    "pothole", "missed_bin", "street_light", "graffiti",
    "illegal_dumping", "fallen_tree", "other",
}
PRIORITIES = {"LOW", "MEDIUM", "HIGH"}
TRACKING_ID = re.compile(r"^SR-\d{8}-[A-Z0-9]{6}$")
ASSET_ID = re.compile(r"^[A-Z]{2}-\d{6}$")


class InvalidMessage(ValueError):
    """The message can never be processed. It belongs on the dead-letter queue."""


def _require(obj: dict, path: str):
    value = obj
    for key in path.split("."):
        if not isinstance(value, dict) or key not in value or value[key] in (None, ""):
            raise InvalidMessage(f"missing {path}")
        value = value[key]
    return value


def to_utc(text: str) -> datetime:
    """ISO 8601 with an offset -> naive UTC datetime for a datetime2 column."""
    try:
        parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except (AttributeError, ValueError) as exc:
        raise InvalidMessage(f"receivedAt is not an ISO date-time: {text!r}") from exc
    if parsed.tzinfo is None:
        raise InvalidMessage("receivedAt has no UTC offset")
    return parsed.astimezone(timezone.utc).replace(tzinfo=None, microsecond=0)


def canonical_to_row(message: dict) -> dict:
    """Canonical queue message (schema 1.x) -> dbo.ServiceRequest row."""
    if not isinstance(message, dict):
        raise InvalidMessage("message body is not a JSON object")
    version = str(message.get("schemaVersion", ""))
    if version.split(".")[0] != SUPPORTED_SCHEMA_MAJOR:
        raise InvalidMessage(f"unsupported schemaVersion {version!r}")

    tracking_id = _require(message, "trackingId")
    if not TRACKING_ID.match(tracking_id):
        raise InvalidMessage("trackingId is not in the expected format")
    category = _require(message, "request.category")
    if category not in CATEGORIES:
        raise InvalidMessage(f"unknown category {category!r}")
    priority = _require(message, "request.priority")
    if priority not in PRIORITIES:
        raise InvalidMessage(f"unknown priority {priority!r}")
    sla_hours = _require(message, "routing.slaHours")
    if not isinstance(sla_hours, int) or sla_hours <= 0:
        raise InvalidMessage("routing.slaHours must be a positive whole number")

    location = message.get("location") or {}
    reporter = message.get("reporter") or {}
    asset_id = message.get("assetId")
    if asset_id is not None and not ASSET_ID.match(asset_id):
        raise InvalidMessage("assetId is not in the expected format")

    return {
        "TrackingId": tracking_id,
        "CorrelationId": message.get("correlationId"),
        "CategoryCode": category,
        "PriorityCode": priority,
        "DepartmentName": _require(message, "routing.department"),
        "SlaHours": sla_hours,
        "Description": _require(message, "request.description")[:2000],
        "Address": location.get("address"),
        "SuburbName": location.get("suburb"),
        "Postcode": location.get("postcode"),
        "Latitude": location.get("latitude"),
        "Longitude": location.get("longitude"),
        "AssetId": asset_id,
        "ReporterName": reporter.get("name"),
        "ReporterEmail": reporter.get("email"),
        "ReporterPhone": reporter.get("phone"),
        "Channel": (message.get("source") or {}).get("channel", "web"),
        "ReceivedUtc": to_utc(_require(message, "receivedAt")),
    }


def row_to_works_record(row: dict) -> dict:
    """dbo.ServiceRequest row -> the works system API's own format.

    Reporter details are deliberately left out: status checks never expose them.
    """
    def iso(value):
        return None if value is None else value.replace(microsecond=0).isoformat() + "Z"

    return {
        "tracking_id": row["TrackingId"],
        "status_code": row["StatusCode"],
        "category_code": row["CategoryCode"],
        "priority_code": row["PriorityCode"],
        "department_name": row["DepartmentName"],
        "suburb_name": row.get("SuburbName"),
        "received_utc": iso(row["ReceivedUtc"]),
        "sla_due_utc": iso(row.get("SlaDueUtc")),
    }


def check_asset_batch(body) -> tuple[str, list[dict]]:
    """Validate the bulk asset payload sent by the ETL job."""
    if not isinstance(body, dict):
        raise InvalidMessage("body is not a JSON object")
    run_id = body.get("runId")
    assets = body.get("assets")
    if not isinstance(run_id, str) or not run_id:
        raise InvalidMessage("runId is required")
    if not isinstance(assets, list) or not assets:
        raise InvalidMessage("assets must be a non-empty list")
    if len(assets) > 500:
        raise InvalidMessage("at most 500 assets per call")
    for index, asset in enumerate(assets):
        if not isinstance(asset, dict) or not ASSET_ID.match(str(asset.get("assetId", ""))):
            raise InvalidMessage(f"assets[{index}].assetId is missing or malformed")
    return run_id, assets
