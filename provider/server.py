#!/usr/bin/env python3
"""Tiny deterministic provider API for the Wraith provider-CI demo."""

from __future__ import annotations

import argparse
import json
import os
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import urlparse


def _json_bytes(payload: dict[str, Any]) -> bytes:
    return (json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n").encode()


class DemoStore:
    """In-memory deterministic state for one provider process."""

    def __init__(self) -> None:
        self.customer_seq = 0
        self.order_seq = 0
        self.customers: dict[str, dict[str, Any]] = {}
        self.orders: dict[str, dict[str, Any]] = {}

    def next_customer_id(self) -> str:
        self.customer_seq += 1
        return f"cus_{self.customer_seq:06d}"

    def next_order_id(self) -> str:
        self.order_seq += 1
        return f"ord_{self.order_seq:06d}"


class DemoHandler(BaseHTTPRequestHandler):
    server_version = "wraith-demo/0.1"

    @property
    def store(self) -> DemoStore:
        return self.server.store  # type: ignore[attr-defined]

    def do_GET(self) -> None:
        path = urlparse(self.path).path

        if path == "/health":
            self.respond(HTTPStatus.OK, {"ok": True, "service": "wraith-demo"})
            return

        if path.startswith("/customers/"):
            customer_id = path.removeprefix("/customers/")
            customer = self.store.customers.get(customer_id)
            if customer is None:
                self.respond(HTTPStatus.NOT_FOUND, {"error": "customer_not_found"})
                return
            self.respond(HTTPStatus.OK, customer)
            return

        if path == "/orders/summary":
            total_cents = sum(order["totalCents"] for order in self.store.orders.values())
            self.respond(
                HTTPStatus.OK,
                {
                    "currency": "USD",
                    "orderCount": len(self.store.orders),
                    "totalCents": total_cents,
                },
            )
            return

        if path.startswith("/orders/"):
            order_id = path.removeprefix("/orders/")
            order = self.store.orders.get(order_id)
            if order is None:
                self.respond(HTTPStatus.NOT_FOUND, {"error": "order_not_found"})
                return
            self.respond(HTTPStatus.OK, order)
            return

        self.respond(HTTPStatus.NOT_FOUND, {"error": "not_found"})

    def do_POST(self) -> None:
        path = urlparse(self.path).path
        body = self.read_json_body()
        if body is None:
            return

        if path == "/customers":
            name = str(body.get("name", "unknown"))
            plan = str(body.get("plan", "starter"))
            customer_id = self.store.next_customer_id()
            customer = {
                "id": customer_id,
                "licenseAgreementID": f"lic_{customer_id}_{plan}",
                "name": name,
                "plan": plan,
                "status": "active",
            }
            self.store.customers[customer_id] = customer
            self.respond(HTTPStatus.CREATED, customer)
            return

        if path == "/orders":
            customer_id = str(body.get("customerId", ""))
            if customer_id not in self.store.customers:
                self.respond(HTTPStatus.BAD_REQUEST, {"error": "unknown_customer"})
                return

            items = body.get("items")
            if not isinstance(items, list) or not items:
                self.respond(HTTPStatus.BAD_REQUEST, {"error": "items_required"})
                return

            total_cents = 0
            normalized_items: list[dict[str, Any]] = []
            for item in items:
                if not isinstance(item, dict):
                    self.respond(HTTPStatus.BAD_REQUEST, {"error": "invalid_item"})
                    return
                sku = str(item.get("sku", "unknown"))
                quantity = int(item.get("quantity", 1))
                unit_cents = int(item.get("unitCents", 0))
                total_cents += quantity * unit_cents
                normalized_items.append(
                    {"quantity": quantity, "sku": sku, "unitCents": unit_cents}
                )

            order_id = self.store.next_order_id()
            order = {
                "customerId": customer_id,
                "id": order_id,
                "items": normalized_items,
                "licenseAgreementID": self.store.customers[customer_id][
                    "licenseAgreementID"
                ],
                "status": "accepted",
                "totalCents": total_cents,
            }
            self.store.orders[order_id] = order
            self.respond(HTTPStatus.CREATED, order)
            return

        self.respond(HTTPStatus.NOT_FOUND, {"error": "not_found"})

    def read_json_body(self) -> dict[str, Any] | None:
        try:
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length)
            payload = json.loads(raw or b"{}")
        except (ValueError, json.JSONDecodeError):
            self.respond(HTTPStatus.BAD_REQUEST, {"error": "invalid_json"})
            return None
        if not isinstance(payload, dict):
            self.respond(HTTPStatus.BAD_REQUEST, {"error": "object_required"})
            return None
        return payload

    def respond(self, status: HTTPStatus, payload: dict[str, Any]) -> None:
        body = _json_bytes(payload)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: Any) -> None:
        if os.environ.get("WRAITH_DEMO_LOGS") == "1":
            super().log_message(format, *args)


class DemoServer(ThreadingHTTPServer):
    def __init__(self, server_address: tuple[str, int]) -> None:
        super().__init__(server_address, DemoHandler)
        self.store = DemoStore()


def main() -> None:
    parser = argparse.ArgumentParser(description="Run the Wraith demo provider API.")
    parser.add_argument("--host", default=os.environ.get("HOST", "127.0.0.1"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("PORT", "8080")))
    args = parser.parse_args()

    server = DemoServer((args.host, args.port))
    print(f"wraith-demo provider listening on http://{args.host}:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
