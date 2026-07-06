# wraith-demo

Controlled provider-CI proof repository for Wraith.

This repository is intentionally small. It is a deterministic toy provider used
to demonstrate a Wraith consumer contract going red in provider CI when a
provider response shape breaks, then green again when the provider is fixed.
It is not production sample code.

## Provider

Run the provider with Python 3.11+:

```sh
PORT=8080 python3 provider/server.py
```

The server binds to `127.0.0.1` by default. Override `HOST` or pass explicit
flags when needed:

```sh
python3 provider/server.py --host 0.0.0.0 --port 8080
```

Endpoints:

- `GET /health`
- `POST /customers`
- `GET /customers/{id}`
- `POST /orders`
- `GET /orders/{id}`
- `GET /orders/summary`

The API uses process-local state and deterministic IDs (`cus_000001`,
`ord_000001`, ...). Customer and order responses include
`licenseAgreementID`, a deliberately contract-sensitive field used by the
provider-CI red/green demonstration.

## Smoke Test

In one shell:

```sh
PORT=8080 python3 provider/server.py
```

In another shell:

```sh
python3 scripts/smoke_test.py --base-url http://127.0.0.1:8080
```

The smoke test creates a customer, reads it back, creates an order, reads it
back, and checks the computed order summary. No external credentials, services,
or network access are required.
