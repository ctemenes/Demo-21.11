import copy
from datetime import datetime

import pytest

from works import mapping

MESSAGE = {
    "schemaVersion": "1.0",
    "trackingId": "SR-20261121-8F3K2A",
    "correlationId": "c0ffee00-0000-4000-8000-000000000001",
    "receivedAt": "2026-11-21T09:30:00+10:00",
    "source": {"system": "service-request-api", "channel": "web"},
    "request": {"category": "pothole", "priority": "HIGH", "description": "Deep pothole in the left lane."},
    "routing": {"department": "Roads and Drainage", "slaHours": 48},
    "location": {"address": "14 Example Street", "suburb": "PADDINGTON", "postcode": "4064",
                 "latitude": -27.4598, "longitude": 153.0029},
    "assetId": "RD-004512",
    "reporter": {"name": "Alex Citizen", "email": "alex.citizen@example.com", "phone": "0400000000"},
}


def test_maps_every_column():
    row = mapping.canonical_to_row(MESSAGE)
    assert row["TrackingId"] == "SR-20261121-8F3K2A"
    assert row["DepartmentName"] == "Roads and Drainage"
    assert row["SlaHours"] == 48
    assert row["SuburbName"] == "PADDINGTON"
    assert row["AssetId"] == "RD-004512"
    assert row["Channel"] == "web"


def test_brisbane_time_is_stored_as_utc():
    row = mapping.canonical_to_row(MESSAGE)
    assert row["ReceivedUtc"] == datetime(2026, 11, 20, 23, 30, 0)


def test_optional_fields_can_be_absent():
    message = copy.deepcopy(MESSAGE)
    del message["assetId"]
    del message["location"]["latitude"]
    del message["reporter"]["phone"]
    row = mapping.canonical_to_row(message)
    assert row["AssetId"] is None and row["Latitude"] is None and row["ReporterPhone"] is None


@pytest.mark.parametrize("path, value, reason", [
    (("schemaVersion",), "2.0", "unsupported schemaVersion"),
    (("trackingId",), "12345", "trackingId"),
    (("request", "category"), "alien_landing", "unknown category"),
    (("request", "priority"), "URGENT", "unknown priority"),
    (("routing", "slaHours"), 0, "slaHours"),
    (("routing", "slaHours"), "48", "slaHours"),
    (("receivedAt",), "yesterday", "receivedAt"),
    (("receivedAt",), "2026-11-21T09:30:00", "no UTC offset"),
    (("assetId",), "pothole-1", "assetId"),
    (("request", "description"), "", "missing request.description"),
])
def test_bad_messages_are_rejected_with_a_reason(path, value, reason):
    message = copy.deepcopy(MESSAGE)
    target = message
    for key in path[:-1]:
        target = target[key]
    target[path[-1]] = value
    with pytest.raises(mapping.InvalidMessage, match=reason):
        mapping.canonical_to_row(message)


def test_body_that_is_not_an_object_is_rejected():
    with pytest.raises(mapping.InvalidMessage):
        mapping.canonical_to_row(["not", "an", "object"])


def test_status_record_never_exposes_the_reporter():
    row = {
        "TrackingId": "SR-20261121-8F3K2A", "StatusCode": "RECEIVED", "CategoryCode": "pothole",
        "PriorityCode": "HIGH", "DepartmentName": "Roads and Drainage", "SuburbName": "PADDINGTON",
        "ReceivedUtc": datetime(2026, 11, 20, 23, 30, 0), "SlaDueUtc": datetime(2026, 11, 22, 23, 30, 0),
        "ReporterName": "Alex Citizen", "ReporterEmail": "alex.citizen@example.com",
    }
    record = mapping.row_to_works_record(row)
    assert record["received_utc"] == "2026-11-20T23:30:00Z"
    assert record["sla_due_utc"] == "2026-11-22T23:30:00Z"
    assert not any("reporter" in key.lower() for key in record)
    assert "alex" not in str(record).lower()


def test_asset_batch_checks():
    run_id, assets = mapping.check_asset_batch({"runId": "ETL-1", "assets": [{"assetId": "RD-000001"}]})
    assert run_id == "ETL-1" and len(assets) == 1
    for bad in (None, {}, {"runId": "ETL-1", "assets": []}, {"runId": "", "assets": [{"assetId": "RD-000001"}]},
                {"runId": "ETL-1", "assets": [{"assetId": "nope"}]},
                {"runId": "ETL-1", "assets": [{"assetId": "RD-000001"}] * 501}):
        with pytest.raises(mapping.InvalidMessage):
            mapping.check_asset_batch(bad)
