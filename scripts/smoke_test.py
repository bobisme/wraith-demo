#!/usr/bin/env python3
"""Smoke test the local Wraith demo provider."""

from __future__ import annotations

import argparse
import json
from urllib.error import HTTPError
from urllib.request import Request, urlopen


def request(method: str, url: str, payload: dict | None = None) -> dict:
    data = None
    headers = {"Accept": "application/json"}
    if payload is not None:
        data = json.dumps(payload).encode()
        headers["Content-Type"] = "application/json"
    req = Request(url, data=data, headers=headers, method=method)
    try:
        with urlopen(req, timeout=5) as response:
            return json.loads(response.read())
    except HTTPError as exc:
        raise AssertionError(f"{method} {url} failed: HTTP {exc.code}") from exc


def main() -> None:
    parser = argparse.ArgumentParser(description="Smoke test the Wraith demo provider.")
    parser.add_argument("--base-url", default="http://127.0.0.1:8080")
    args = parser.parse_args()
    base = args.base_url.rstrip("/")

    health = request("GET", f"{base}/health")
    assert health == {"ok": True, "service": "wraith-demo"}

    customer = request(
        "POST",
        f"{base}/customers",
        {"name": "Acme QA", "plan": "enterprise"},
    )
    assert customer["id"] == "cus_000001"
    assert customer["licenseAgreementID"] == "lic_cus_000001_enterprise"

    customer_read = request("GET", f"{base}/customers/{customer['id']}")
    assert customer_read == customer

    order = request(
        "POST",
        f"{base}/orders",
        {
            "customerId": customer["id"],
            "items": [
                {"sku": "seat", "quantity": 3, "unitCents": 1200},
                {"sku": "support", "quantity": 1, "unitCents": 5000},
            ],
        },
    )
    assert order["id"] == "ord_000001"
    assert order["customerId"] == customer["id"]
    assert order["licenseAgreementID"] == customer["licenseAgreementID"]
    assert order["totalCents"] == 8600

    order_read = request("GET", f"{base}/orders/{order['id']}")
    assert order_read == order

    summary = request("GET", f"{base}/orders/summary")
    assert summary == {"currency": "USD", "orderCount": 1, "totalCents": 8600}

    print("smoke test passed")


if __name__ == "__main__":
    main()
