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

## Contract Assets

The committed contract is the checkout consumer's expectation for this provider:

- `contracts/packages/checkout-web.wic` is the signed Wraith intent-contract
  package.
- `contracts/checkout-web/checkout-web.status.toml` is the provider decision
  sidecar. It is set to `provider_status = "blocking"` for CI.
- `contracts/checkout-web/scenarios/checkout_customer_order_contract.lua` is the
  accepted runnable scenario.
- `contracts/staged/checkout-web/` is the reviewed staged source tree used to
  build the `.wic`.
- `trusted-signers/demo-team.ed25519.pub` is the deterministic demo public key.

Run the accepted contract against the live provider:

```sh
PORT=8080 python3 provider/server.py
sigil run contracts/checkout-web/scenarios \
  --endpoint http://127.0.0.1:8080 \
  --env WRAITH_SESSION_BASE=local-demo \
  --json
```

`sigil run` resolves Wraith helper modules from `.sigil/scenarios/lib`, so this
repo commits `.sigil/scenarios/lib/wraith.lua` as the canonical helper copy used
by local and CI runs.

## Regenerating The Contract

The package was generated from a real Wraith recording and then reviewed to
promote the contract-sensitive assertions to hard failures. No credentials are
required.

```sh
# 1. Start the provider.
PORT=18080 python3 provider/server.py

# 2. In another shell, initialize or refresh the twin, then record the smoke flow.
wraith init wraith-demo --base-url http://127.0.0.1:18080
wraith record wraith-demo --port 18081 --tag checkout-contract --duration 8
python3 scripts/smoke_test.py --base-url http://127.0.0.1:18081
wraith synth wraith-demo --tag checkout-contract

# 3. Propose from the recorded evidence.
wraith contract propose wraith-demo \
  --out contracts/staged/checkout-web --force \
  --consumer checkout-web --provider wraith-demo --owner demo-team \
  --base wraith-demo@sha256:b855e20cae92dc61dc47183a1e51f966ed23c6fe91de955272fb148d08f8444f \
  --overlay wraith-demo@sha256:b855e20cae92dc61dc47183a1e51f966ed23c6fe91de955272fb148d08f8444f \
  --tag checkout-contract

# 4. Review contracts/staged/checkout-web/scenarios/*.lua.
#    Keep generated provenance, but promote the intended checks to hard failures.

# 5. Pack with the deterministic demo signing key and accept as blocking.
WRAITH_SIGN_KEY=$(wraith key gen --seed 424242 --format json | jq -r .key.secret_b64)
wraith contract pack contracts/staged/checkout-web \
  --output contracts/packages/checkout-web.wic \
  --key "$WRAITH_SIGN_KEY"
wraith contract verify-package contracts/packages/checkout-web.wic \
  --trust-store trusted-signers
wraith contract inspect contracts/packages/checkout-web.wic --strict
wraith contract accept contracts/packages/checkout-web.wic \
  --trust-store trusted-signers \
  --accepted-by demo-team \
  --root . \
  --force
wraith contract set-status blocking \
  --consumer checkout-web \
  --name checkout-web \
  --by demo-team \
  --reason "required for provider CI red/green demo" \
  --root .
```

The `--seed 424242` key is intentionally predictable and is only for this public
demo fixture. Do not use deterministic signing keys for real consumer contracts.
