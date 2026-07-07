#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE="${WRAITH_CONTRACT_PACKAGE:-contracts/packages/checkout-web.wic}"
TRUST_STORE="${WRAITH_TRUST_STORE:-trusted-signers}"
SCENARIOS="${WRAITH_CONTRACT_SCENARIOS:-contracts/checkout-web/scenarios}"
ENDPOINT="${WRAITH_PROVIDER_URL:-http://127.0.0.1:${PORT:-8080}}"
RESULT_DIR="${WRAITH_CONTRACT_RESULTS_DIR:-${ROOT_DIR}/contract-results}"
STATUS_FILE="${RESULT_DIR}/status.tsv"
SUMMARY_FILE="${RESULT_DIR}/provider-contracts-summary.json"

if [[ -z "${WRAITH_SESSION_BASE:-}" ]]; then
  if [[ -n "${GITHUB_RUN_ID:-}" ]]; then
    export WRAITH_SESSION_BASE="provider-contracts-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT:-1}"
  else
    export WRAITH_SESSION_BASE="provider-contracts-local-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  fi
fi

cd "$ROOT_DIR"
mkdir -p "$RESULT_DIR"
: >"$STATUS_FILE"

run_json_step() {
  local name="$1"
  shift

  local stdout_file="${RESULT_DIR}/${name}.json"
  local stderr_file="${RESULT_DIR}/${name}.stderr.log"
  local exit_code

  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    printf '::group::%s\n' "$name"
  else
    printf '==> %s\n' "$name" >&2
  fi

  set +e
  "$@" >"$stdout_file" 2>"$stderr_file"
  exit_code=$?
  set -e

  cat "$stdout_file"
  if [[ -s "$stderr_file" ]]; then
    cat "$stderr_file" >&2
  fi

  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    printf '::endgroup::\n'
  fi

  printf '%s\t%s\t%s\t%s\n' "$name" "$exit_code" "$stdout_file" "$stderr_file" >>"$STATUS_FILE"
}

run_json_step verify_package \
  wraith contract verify-package "$PACKAGE" \
    --trust-store "$TRUST_STORE" \
    --format json

run_json_step inspect_strict \
  wraith contract inspect "$PACKAGE" \
    --strict \
    --format json

run_json_step scenarios \
  sigil run "$SCENARIOS" \
    --endpoint "$ENDPOINT" \
    --env WRAITH_SESSION_BASE \
    --json

python3 - "$STATUS_FILE" "$SUMMARY_FILE" <<'PY'
import json
import os
import pathlib
import sys

status_path = pathlib.Path(sys.argv[1])
summary_path = pathlib.Path(sys.argv[2])

steps = []
overall_ok = True

for line in status_path.read_text().splitlines():
    name, exit_code_raw, stdout_raw, stderr_raw = line.split("\t", 3)
    exit_code = int(exit_code_raw)
    stdout_path = pathlib.Path(stdout_raw)
    stderr_path = pathlib.Path(stderr_raw)
    overall_ok = overall_ok and exit_code == 0

    stdout_text = stdout_path.read_text() if stdout_path.exists() else ""
    stderr_text = stderr_path.read_text() if stderr_path.exists() else ""
    try:
        payload = json.loads(stdout_text) if stdout_text.strip() else None
    except json.JSONDecodeError:
        payload = {"raw_stdout": stdout_text}

    steps.append(
        {
            "name": name,
            "exit_code": exit_code,
            "status": "passed" if exit_code == 0 else "failed",
            "stdout": str(stdout_path),
            "stderr": str(stderr_path),
            "stderr_tail": stderr_text[-4000:],
            "result": payload,
        }
    )

summary = {
    "status": "passed" if overall_ok else "failed",
    "endpoint": os.environ.get("WRAITH_PROVIDER_URL")
    or f"http://127.0.0.1:{os.environ.get('PORT', '8080')}",
    "session_base": os.environ.get("WRAITH_SESSION_BASE"),
    "steps": steps,
}

summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
print(json.dumps(summary, indent=2, sort_keys=True))
sys.exit(0 if overall_ok else 1)
PY
