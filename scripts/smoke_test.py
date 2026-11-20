"""End-to-end check against the deployed integration.

Lodges a request through the MuleSoft API, then asks for its status until the
works system has stored it. Proves every hop: API, mapping, queue, function,
database, and the mapping back. Also checks the error paths.
"""
import argparse
import json
import sys
import time
import urllib.error
import urllib.request


def call(method, url, body=None):
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(url, data=data, method=method,
                                     headers={"Content-Type": "application/json", "Accept": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.status, json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        raw = error.read()
        try:
            return error.code, json.loads(raw or b"{}")
        except ValueError:
            return error.code, {"raw": raw.decode(errors="replace")[:300]}


def check(name, condition, detail=""):
    print(f"{'PASS' if condition else 'FAIL'}  {name}{'  ' + str(detail) if detail and not condition else ''}")
    return condition


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", required=True, help="for example https://host/api")
    parser.add_argument("--wait-seconds", type=int, default=180)
    args = parser.parse_args()
    base = args.base_url.rstrip("/")
    ok = True

    status, body = call("GET", f"{base}/health")
    ok &= check("health answers UP", status == 200 and body.get("status") == "UP", (status, body))

    request = {
        "category": "pothole",
        "description": "Smoke test: deep pothole in the left lane outside number 14.",
        "location": {"address": "14 Example Street", "suburb": "Paddington", "postcode": "4064"},
        "assetId": "RD-001002",
        "reporter": {"name": "Pipeline Check", "email": "pipeline.check@example.com"},
    }
    status, receipt = call("POST", f"{base}/service-requests", request)
    ok &= check("request accepted with 202", status == 202, (status, receipt))
    tracking_id = receipt.get("trackingId", "")
    ok &= check("receipt routes to Roads and Drainage in 48 hours",
                receipt.get("department") == "Roads and Drainage" and receipt.get("targetResolutionHours") == 48, receipt)

    stored, deadline = None, time.time() + args.wait_seconds
    while tracking_id and time.time() < deadline:
        status, stored = call("GET", f"{base}/service-requests/{tracking_id}")
        if status == 200:
            break
        time.sleep(5)
    ok &= check("works system stored it and the status comes back", status == 200 and stored.get("status") == "RECEIVED", (status, stored))
    if status == 200:
        ok &= check("suburb was normalised", stored.get("suburb") == "PADDINGTON", stored)
        ok &= check("status never exposes the reporter", "reporter" not in json.dumps(stored).lower(), stored)

    bad = dict(request, category="alien_landing")
    status, body = call("POST", f"{base}/service-requests", bad)
    ok &= check("unknown category is rejected with 400", status == 400 and body.get("code") == "BAD_REQUEST", (status, body))

    status, body = call("POST", f"{base}/service-requests", {k: v for k, v in request.items() if k != "reporter"})
    ok &= check("missing reporter is rejected with 400", status == 400, (status, body))

    status, body = call("GET", f"{base}/service-requests/SR-19990101-ZZZZZZ")
    ok &= check("unknown tracking id gives 404", status == 404 and body.get("code") == "NOT_FOUND", (status, body))

    print("\nAll checks passed." if ok else "\nSome checks failed.")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
