"""Azure SQL access for the works management system.

Signs in with the Function App's managed identity, so there is no database
password anywhere. Retries while a serverless database wakes up.
"""
from __future__ import annotations

import json
import logging
import os
import struct
import time
from contextlib import contextmanager

import pyodbc
from azure.identity import DefaultAzureCredential

_SQL_COPT_SS_ACCESS_TOKEN = 1256
_credential = DefaultAzureCredential()
_TRANSIENT = ("40613", "40197", "40501", "49918", "08001", "HYT00", "08S01")


def _connection_string() -> str:
    return (
        "Driver={ODBC Driver 18 for SQL Server};"
        f"Server=tcp:{os.environ['SQL_SERVER']},1433;"
        f"Database={os.environ['SQL_DATABASE']};"
        "Encrypt=yes;TrustServerCertificate=no;Connection Timeout=60;"
    )


@contextmanager
def _session():
    """Open a connection and always close it, even when the query fails."""
    conn = _connect()
    try:
        yield conn
    finally:
        conn.close()


def _connect() -> pyodbc.Connection:
    token = _credential.get_token("https://database.windows.net/.default").token.encode("utf-16-le")
    token_struct = struct.pack(f"<I{len(token)}s", len(token), token)
    last_error = None
    for attempt in range(4):
        try:
            return pyodbc.connect(_connection_string(), attrs_before={_SQL_COPT_SS_ACCESS_TOKEN: token_struct})
        except pyodbc.Error as exc:  # serverless database resuming, or a network blip
            last_error = exc
            if not any(code in str(exc) for code in _TRANSIENT):
                raise
            logging.warning("SQL not ready (attempt %s), retrying", attempt + 1)
            time.sleep(5 * (attempt + 1))
    raise last_error


_UPSERT_REQUEST = """
MERGE dbo.ServiceRequest AS target
USING (SELECT ? AS TrackingId) AS source ON target.TrackingId = source.TrackingId
WHEN MATCHED THEN
    UPDATE SET DeliveryCount = target.DeliveryCount + 1
WHEN NOT MATCHED THEN
    INSERT (TrackingId, CorrelationId, CategoryCode, PriorityCode, DepartmentName, SlaHours,
            Description, Address, SuburbName, Postcode, Latitude, Longitude, AssetId,
            ReporterName, ReporterEmail, ReporterPhone, Channel, ReceivedUtc)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
OUTPUT $action;
"""

_COLUMNS = [
    "TrackingId", "CorrelationId", "CategoryCode", "PriorityCode", "DepartmentName", "SlaHours",
    "Description", "Address", "SuburbName", "Postcode", "Latitude", "Longitude", "AssetId",
    "ReporterName", "ReporterEmail", "ReporterPhone", "Channel", "ReceivedUtc",
]


def upsert_service_request(row: dict) -> str:
    """Insert once. A redelivered message only bumps DeliveryCount. Returns INSERT or UPDATE."""
    with _session() as conn:
        cursor = conn.cursor()
        cursor.execute(_UPSERT_REQUEST, [row["TrackingId"]] + [row[c] for c in _COLUMNS])
        action = cursor.fetchone()[0]
        conn.commit()
        return action


def get_service_request(tracking_id: str) -> dict | None:
    with _session() as conn:
        cursor = conn.cursor()
        cursor.execute(
            "SELECT TrackingId, StatusCode, CategoryCode, PriorityCode, DepartmentName, SuburbName,"
            " ReceivedUtc, SlaDueUtc FROM dbo.ServiceRequest WHERE TrackingId = ?",
            tracking_id,
        )
        record = cursor.fetchone()
        if record is None:
            return None
        return dict(zip([column[0] for column in cursor.description], record))


_UPSERT_ASSETS = """
MERGE dbo.Asset AS target
USING (
    SELECT assetId, assetType, description, suburb, postcode, latitude, longitude, status, installedOn
    FROM OPENJSON(?) WITH (
        assetId varchar(9) '$.assetId', assetType varchar(20) '$.assetType',
        description nvarchar(200) '$.description', suburb nvarchar(80) '$.suburb',
        postcode char(4) '$.postcode', latitude decimal(9,6) '$.latitude',
        longitude decimal(9,6) '$.longitude', status varchar(16) '$.status',
        installedOn date '$.installedOn')
) AS source ON target.AssetId = source.assetId
WHEN MATCHED THEN UPDATE SET
    AssetType = source.assetType, Description = source.description, SuburbName = source.suburb,
    Postcode = source.postcode, Latitude = source.latitude, Longitude = source.longitude,
    StatusCode = source.status, InstalledOn = source.installedOn, LastRunId = ?, UpdatedUtc = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (AssetId, AssetType, Description, SuburbName, Postcode, Latitude, Longitude, StatusCode, InstalledOn, LastRunId)
    VALUES (source.assetId, source.assetType, source.description, source.suburb, source.postcode,
            source.latitude, source.longitude, source.status, source.installedOn, ?)
OUTPUT $action;
"""


def upsert_assets(run_id: str, assets: list[dict]) -> dict:
    """One set-based MERGE per block: the whole block lands or none of it does."""
    with _session() as conn:
        cursor = conn.cursor()
        cursor.execute(_UPSERT_ASSETS, json.dumps(assets), run_id, run_id)
        actions = [record[0] for record in cursor.fetchall()]
        conn.commit()
    return {
        "received": len(assets),
        "inserted": actions.count("INSERT"),
        "updated": actions.count("UPDATE"),
    }


def record_etl_run(report: dict) -> None:
    with _session() as conn:
        conn.cursor().execute(
            "INSERT INTO dbo.EtlRun (RunId, Source, TotalRows, LoadedRows, RejectedRows, ElapsedMs)"
            " VALUES (?, ?, ?, ?, ?, ?)",
            report.get("runId"), report.get("source"), report.get("totalRows"),
            report.get("loadedRows"), report.get("rejectedRows"), report.get("elapsedMs"),
        )
        conn.commit()
