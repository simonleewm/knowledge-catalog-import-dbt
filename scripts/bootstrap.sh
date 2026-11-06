#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh - prepare Cloud Shell (or any Linux/macOS box) to run dbt_bq_demo.
#
#   1. create a Python virtualenv and install the pinned dbt packages
#      (reuses ../venv if it already contains dbt, otherwise creates ./.venv)
#   2. run scripts/kc_import.sh check  (tooling, placeholders, identity, ADC)
#
# Usage:  ./scripts/bootstrap.sh            # from anywhere
#         VENV_DIR=/path/to/venv ./scripts/bootstrap.sh
#
# Re-running is safe; it only upgrades packages if requirements.txt changed.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

log()  { printf '\033[1;34m[bootstrap]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[bootstrap]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[bootstrap] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

cd "${REPO_ROOT}"
chmod +x scripts/*.sh 2>/dev/null || true

if [[ "${CLOUD_SHELL:-}" == "true" ]]; then
  printf '\033[2m$ gcloud config get-value account\033[0m\n' >&2
  log "running in Cloud Shell (user: $(gcloud config get-value account 2>/dev/null || echo '?'))"
fi

# ----------------------------------------------------------------------------- .env
if [[ ! -f .env ]]; then
  cp .env.example .env
  log "created .env from .env.example - fill in the YOUR_* placeholders before running setup/all"
fi

# ----------------------------------------------------------------------------- python
PYTHON_BIN="${PYTHON_BIN:-}"
if [[ -z "$PYTHON_BIN" ]]; then
  for c in python3.13 python3.12 python3.11 python3.10 python3.9 python3; do
    if command -v "$c" >/dev/null 2>&1; then PYTHON_BIN="$(command -v "$c")"; break; fi
  done
fi
[[ -n "$PYTHON_BIN" ]] || die "python3 (3.9+) not found"
log "python: ${PYTHON_BIN} ($("$PYTHON_BIN" --version 2>&1))"

if [[ -z "${VENV_DIR:-}" ]]; then
  if [[ -x "${REPO_ROOT}/../venv/bin/dbt" ]]; then
    VENV_DIR="$(cd "${REPO_ROOT}/.." && pwd)/venv"
  else
    VENV_DIR="${REPO_ROOT}/.venv"
  fi
fi

if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
  log "creating virtualenv at ${VENV_DIR}"
  if ! "$PYTHON_BIN" -m venv "${VENV_DIR}" 2>/dev/null; then
    if "$PYTHON_BIN" -m virtualenv --version >/dev/null 2>&1; then
      "$PYTHON_BIN" -m virtualenv -q "${VENV_DIR}"
    else
      die "could not create a virtualenv. On Debian/Ubuntu/Cloud Shell run: sudo apt-get install -y python3-venv  (then re-run)"
    fi
  fi
else
  log "using existing virtualenv at ${VENV_DIR}"
fi

VPY="${VENV_DIR}/bin/python"
STAMP="${VENV_DIR}/.requirements.sha256"
REQ_HASH="$(sha256sum requirements.txt | cut -d' ' -f1)"
if [[ -x "${VENV_DIR}/bin/dbt" && -f "$STAMP" && "$(<"$STAMP")" == "$REQ_HASH" ]]; then
  ok "dbt already installed and up to date"
else
  log "installing pinned dbt packages (this takes a minute or two)"
  "$VPY" -m pip install --quiet --upgrade pip
  "$VPY" -m pip install --quiet -r requirements.txt
  printf '%s\n' "$REQ_HASH" > "$STAMP"
fi
"${VENV_DIR}/bin/dbt" --version | sed 's/^/    /'

# ----------------------------------------------------------------------------- checks
echo
export DBT_BIN="${VENV_DIR}/bin/dbt"
if "${SCRIPT_DIR}/kc_import.sh" check; then
  echo
  ok "ready. Next steps:"
  cat <<EOF
    ${SCRIPT_DIR#"$PWD"/}/kc_import.sh setup     # one-time: API, entry group, staging bucket, service-agent IAM
    ${SCRIPT_DIR#"$PWD"/}/kc_import.sh all       # dbt seed/freshness/build/docs  ->  Knowledge Catalog import
    ${SCRIPT_DIR#"$PWD"/}/kc_import.sh status    # job status
    (or: make setup && make all)
    Tip: 'source ${VENV_DIR#"$PWD"/}/bin/activate' to use plain 'dbt ...' commands.
EOF
else
  echo
  die "fix the problems above, then re-run ./scripts/bootstrap.sh"
fi
