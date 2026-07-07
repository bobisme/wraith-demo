# Provider-CI Red/Green Proof

This repository is the controlled Wraith provider-CI proof for a consumer
contract break.

## Contract

The checkout consumer contract is committed at
`contracts/packages/checkout-web.wic` and accepted by the provider at
`contracts/checkout-web/checkout-web.status.toml` with:

```toml
provider_status = "blocking"

[scenarios]
checkout_customer_order_contract = "active"
```

The active scenario is
`contracts/checkout-web/scenarios/checkout_customer_order_contract.lua`. Its
contract-sensitive assertions require `licenseAgreementID` on customer and order
responses.

## Red Run

Proof PR: https://github.com/bobisme/wraith-demo/pull/1

Break commit:
`f9fb8bb18abeae78e0be0b62c836625afb7726d7`

Change:

```text
licenseAgreementID -> license_agreement_id
```

GitHub Actions run:
https://github.com/bobisme/wraith-demo/actions/runs/28832105505

Failed job:
https://github.com/bobisme/wraith-demo/actions/runs/28832105505/job/85507989315

The failure names the consumer scenario and broken field:

```text
checkout_customer_order_contract
customer licenseAgreementID: expected lic_cus_000001_enterprise, got nil
```

## Green Run

Fix commit:
`aac893a7dd5e59891f75aaae899517c9d05b811a`

This commit reverts the deliberate field rename.

GitHub Actions run:
https://github.com/bobisme/wraith-demo/actions/runs/28832123871

Passing job:
https://github.com/bobisme/wraith-demo/actions/runs/28832123871/job/85508046802

The same Provider Contracts workflow installs Wraith and Sigil, starts the
provider, verifies the signed `.wic`, strict-inspects it, and runs the accepted
scenario suite successfully.

## Reproduce Locally

Run the green path:

```sh
PORT=8080 python3 provider/server.py
WRAITH_SESSION_BASE=local-demo scripts/verify_contracts.sh
```

Reproduce the red path on a branch:

```sh
python3 - <<'PY'
from pathlib import Path
p = Path("provider/server.py")
s = p.read_text()
s = s.replace("licenseAgreementID", "license_agreement_id")
p.write_text(s)
PY

PORT=8080 python3 provider/server.py
WRAITH_SESSION_BASE=local-break scripts/verify_contracts.sh
```

The verification script should fail at the `scenarios` step and report the
`customer licenseAgreementID` expectation.

## Rough Edges Filed

- Wraith bone `bn-3966v`: align Sigil helper resolution with Wraith's accepted
  contract scenario layout, or document the helper copy step as first-class.
