"""Apply the database schema and give the Function App's managed identity access.

Signs in with the caller's own Entra token (from the Azure CLI), so no password is
involved. Opens the SQL firewall for this machine only while it runs.
"""
import argparse
import json
import re
import struct
import subprocess
import sys
import time
import urllib.request


def az(*args: str) -> str:
    return subprocess.run(["az", *args], check=True, capture_output=True, text=True).stdout.strip()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--resource-group", required=True)
    parser.add_argument("--server", required=True, help="fully qualified server name")
    parser.add_argument("--database", required=True)
    parser.add_argument("--schema", required=True)
    parser.add_argument("--grant-identity", required=True, help="Function App name")
    args = parser.parse_args()

    try:
        import pyodbc
    except ImportError:
        subprocess.run([sys.executable, "-m", "pip", "install", "--user", "--quiet", "pyodbc"], check=True)
        import site
        sys.path.append(site.getusersitepackages())
        import pyodbc

    server_name = args.server.split(".")[0]
    my_ip = urllib.request.urlopen("https://api.ipify.org", timeout=20).read().decode().strip()
    rule = "temp-schema-deploy"
    az("sql", "server", "firewall-rule", "create", "-g", args.resource_group, "-s", server_name,
       "-n", rule, "--start-ip-address", my_ip, "--end-ip-address", my_ip, "-o", "none")
    try:
        token = json.loads(az("account", "get-access-token", "--resource", "https://database.windows.net/"))
        raw = token["accessToken"].encode("utf-16-le")
        attrs = {1256: struct.pack(f"<I{len(raw)}s", len(raw), raw)}
        driver = next((d for d in pyodbc.drivers() if "ODBC Driver" in d and "SQL Server" in d), None)
        if driver is None:
            print("No SQL Server ODBC driver on this machine.", file=sys.stderr)
            return 2
        conn_str = (f"Driver={{{driver}}};Server=tcp:{args.server},1433;Database={args.database};"
                    "Encrypt=yes;TrustServerCertificate=no;Connection Timeout=60;")
        conn = None
        for attempt in range(8):  # firewall rule and a paused serverless database both take a moment
            try:
                conn = pyodbc.connect(conn_str, attrs_before=attrs, autocommit=True)
                break
            except pyodbc.Error as exc:
                print(f"   database not reachable yet ({attempt + 1}): {str(exc)[:120]}")
                time.sleep(15)
        if conn is None:
            return 3
        cursor = conn.cursor()
        script = open(args.schema, encoding="utf-8").read()
        for batch in re.split(r"(?im)^\s*GO\s*$", script):
            if batch.strip():
                cursor.execute(batch)
        identity = args.grant_identity.replace("]", "]]")
        cursor.execute(
            f"IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'{identity}') "
            f"CREATE USER [{identity}] FROM EXTERNAL PROVIDER;")
        for role in ("db_datareader", "db_datawriter"):
            cursor.execute(f"ALTER ROLE {role} ADD MEMBER [{identity}];")
        cursor.execute("SELECT COUNT(*) FROM sys.tables WHERE name IN ('ServiceRequest', 'Asset', 'EtlRun')")
        print(f"   schema applied, {cursor.fetchone()[0]} of 3 tables present, {args.grant_identity} can read and write")
        conn.close()
        return 0
    finally:
        az("sql", "server", "firewall-rule", "delete", "-g", args.resource_group, "-s", server_name, "-n", rule)


if __name__ == "__main__":
    sys.exit(main())
