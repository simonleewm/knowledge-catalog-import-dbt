#!/usr/bin/env bash
# =============================================================================
# kc_import.sh - Generate dbt artifacts and import them into Google Cloud
#                Knowledge Catalog (formerly Dataplex Universal Catalog).
#
# Reference: https://docs.cloud.google.com/knowledge-catalog/docs/dbt-transfer
#
# Usage:
#   scripts/kc_import.sh <command> [options]
#
# Commands:
#   check      Verify tooling (gcloud >= 586, dbt) and that all placeholders are filled.
#   setup      One-time: enable the API, provision the Knowledge Catalog service
#              agent, create the entry group and staging bucket, grant the
#              service agent read access to the bucket. Idempotent.
#   iam        Grant the caller (KC_PRINCIPAL) the roles needed to run imports.
#   generate   Run dbt to produce target/{manifest,catalog,run_results,sources}.json
#   import     Create a Knowledge Catalog metadata job from ./target (full sync).
#   all        generate + import
#   status     Describe a metadata job (--job-id, or the last job created here).
#   search     Search the catalog for dbt entries (optional query argument).
#   history    Print logs/kc_import.log: every gcloud/dbt/REST command this script
#              has executed, with timestamps (also echoed live as "$ ...").
#   lineage    Show BigQuery-native lineage (Data Lineage API) for the demo tables, or
#              for the table FQNs given as arguments (bigquery:project.dataset.table).
#   links      Physical -> logical proof: for each BigQuery table, the dbt entries that
#              claim it via Knowledge Catalog entry links (same FQN arguments as lineage).
#
# Options:
#   --dry-run             Print every gcloud/dbt command instead of executing it.
#   --env FILE            Env file to load (default: <repo>/.env). Shell env wins.
#   --job-id ID           Metadata job id for import/status.
#   --aspects-only        import: refresh aspects only (routine re-runs; no
#                         entries created/deleted, no entry links).
#   --validate-only       import: build + upload JSONL and validate, no ingest.
#   --async               import: return immediately.
#   --skip-bigquery-link  import: do not emit dbt node -> BigQuery table links.
#   --no-seed             generate: skip the demo `dbt seed` pre-step.
#   --force               generate/all: continue to the import even if `dbt build`
#                         hit runtime errors (failing tests never block the import).
#   --log-http            Append --log-http to every gcloud call: prints each HTTP
#                         request/response gcloud makes (verbose; tokens are redacted).
#   -h, --help            Show this help.
#
# Configuration (see .env.example):
#   DBT_GCP_PROJECT, DBT_BQ_LOCATION, DBT_DEFAULT_DATASET          (dbt / BigQuery)
#   KC_PROJECT_ID, KC_LOCATION, KC_ENTRY_GROUP,                     (Knowledge Catalog)
#   KC_STAGING_BUCKET, KC_STAGING_PREFIX, KC_SKIP_BIGQUERY_LINK, KC_PRINCIPAL
#   ENABLE_DATA_LINEAGE   true (default) -> `setup` also enables datalineage.googleapis.com
#   GCLOUD_ACCOUNT        gcloud account to pin (exported as CLOUDSDK_CORE_ACCOUNT);
#                         the script refuses to run if it is not authenticated and
#                         if dbt's Application Default Credentials belong to another user.
#   DBT_BIN (optional) path to the dbt executable; DBT_TARGET (optional) dbt target.
#
# Cloud Shell: gcloud is pre-authenticated and ADC are provided automatically.
#   unzip dbt_bq_demo_cloudshell.zip && cd dbt_bq_demo && ./scripts/bootstrap.sh
#   ./scripts/kc_import.sh setup && ./scripts/kc_import.sh all
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARTIFACTS_DIR="${REPO_ROOT}/target"
LAST_JOB_FILE="${ARTIFACTS_DIR}/.kc_last_job_id"

DRY_RUN=false
ENV_FILE="${REPO_ROOT}/.env"
JOB_ID=""
ASPECTS_ONLY=false
VALIDATE_ONLY=false
ASYNC=false
SKIP_BQ_LINK_FLAG=false
RUN_SEED=true
FORCE=false
COMMAND=""
EXTRA_ARGS=()
GCLOUD_EXTRA=()                                   # e.g. --log-http (see --log-http flag)
CMD_LOG="${KC_COMMAND_LOG:-${REPO_ROOT}/logs/kc_import.log}"

# ----------------------------------------------------------------------------- logging
if [[ -t 1 ]]; then
  C_INFO=$'\033[1;34m'; C_OK=$'\033[1;32m'; C_WARN=$'\033[1;33m'; C_ERR=$'\033[1;31m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
  C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_RST=""
fi
log()  { printf '%s[kc]%s %s\n' "$C_INFO" "$C_RST" "$*"; }
ok()   { printf '%s[kc]%s %s\n' "$C_OK" "$C_RST" "$*"; }
warn() { printf '%s[kc] WARN:%s %s\n' "$C_WARN" "$C_RST" "$*" >&2; }
die()  { printf '%s[kc] ERROR:%s %s\n' "$C_ERR" "$C_RST" "$*" >&2; exit 1; }

# ----------------------------------------------------------------------------- command tracing
# Every gcloud / dbt / REST call made by this script goes through one of the
# helpers below. Each call is echoed as "$ <command>" on fd 3 (a copy of the
# terminal's stderr, so it is visible even when the command's own output is
# captured or silenced) and appended with a timestamp to $CMD_LOG
# (logs/kc_import.log). Secrets are never traced: tokens are shown as ***.
exec 3>&2
render() { local r; r="$(printf '%q ' "$@")"; printf '%s' "${r% }"; }
trace() {
  printf '%s$ %s%s\n' "$C_DIM" "$1" "$C_RST" >&3
  { mkdir -p "$(dirname "$CMD_LOG")" && printf '%s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$CMD_LOG"; } 2>/dev/null || true
}
with_gcloud_extra() {               # appends --log-http etc. to gcloud commands
  if [[ "$1" == gcloud && ${#GCLOUD_EXTRA[@]} -gt 0 ]]; then printf '%s\n' "$@" "${GCLOUD_EXTRA[@]}"; else printf '%s\n' "$@"; fi
}
# run:   mutating / main command. Traced; skipped in --dry-run (returns 0).
run() {
  local -a cmd; mapfile -t cmd < <(with_gcloud_extra "$@")
  trace "$(render "${cmd[@]}")"
  [[ "$DRY_RUN" == true ]] && return 0
  "${cmd[@]}"
}
# query: remote read-only command whose output the script consumes. Traced;
#        skipped in --dry-run (returns 1 so "exists?" checks take the create path).
query() {
  local -a cmd; mapfile -t cmd < <(with_gcloud_extra "$@")
  trace "$(render "${cmd[@]}")"
  [[ "$DRY_RUN" == true ]] && return 1
  "${cmd[@]}"
}
# local_cmd: gcloud calls that only read local config/credentials (version,
#            auth list). Traced; always executed, also in --dry-run.
local_cmd() {
  trace "$(render "$@")"
  "$@"
}
trace_header() {
  { mkdir -p "$(dirname "$CMD_LOG")" && printf '\n# %s  kc_import.sh %s %s%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$COMMAND" "${EXTRA_ARGS[*]:-}" "$([[ "$DRY_RUN" == true ]] && echo ' (dry-run)')" >> "$CMD_LOG"; } 2>/dev/null || true
}
trace_footer() {
  local n; n="$(awk -v s="$TRACE_START_LINE" 'NR>s && /^20/ {c++} END {print c+0}' "$CMD_LOG" 2>/dev/null || echo 0)"
  local verb="executed by this run"; [[ "$DRY_RUN" == true ]] && verb="printed by this dry-run (not executed)"
  printf '%s[kc] %s command(s) %s; full list with timestamps: %s  (scripts/kc_import.sh history)%s\n' "$C_DIM" "$n" "$verb" "${CMD_LOG#"$REPO_ROOT"/}" "$C_RST" >&3
}

usage() { sed -n '2,/^# ====*$/p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,1\}//' | sed '$d'; }

# ----------------------------------------------------------------------------- args
while [[ $# -gt 0 ]]; do
  case "$1" in
    check|setup|iam|generate|import|all|status|search|lineage|links|history)
      [[ -z "$COMMAND" ]] && COMMAND="$1" || EXTRA_ARGS+=("$1") ;;
    --dry-run)            DRY_RUN=true ;;
    --env)                ENV_FILE="$2"; shift ;;
    --env=*)              ENV_FILE="${1#*=}" ;;
    --job-id)             JOB_ID="$2"; shift ;;
    --job-id=*)           JOB_ID="${1#*=}" ;;
    --aspects-only)       ASPECTS_ONLY=true ;;
    --validate-only)      VALIDATE_ONLY=true ;;
    --async)              ASYNC=true ;;
    --skip-bigquery-link) SKIP_BQ_LINK_FLAG=true ;;
    --no-seed)            RUN_SEED=false ;;
    --force)              FORCE=true ;;
    --log-http)           GCLOUD_EXTRA+=(--log-http) ;;
    -h|--help)            usage; exit 0 ;;
    *)                    EXTRA_ARGS+=("$1") ;;
  esac
  shift
done
[[ -n "$COMMAND" ]] || { usage; die "missing command"; }

# ----------------------------------------------------------------------------- env
# Load KEY=VALUE lines from the env file; variables already set in the shell win.
load_env_file() {
  local f="$1" line key val
  [[ -f "$f" ]] || { warn "env file not found: $f (copy .env.example to .env)"; return 0; }
  log "loading ${f} (shell environment takes precedence)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"              # ltrim
    [[ -z "$line" || "$line" == \#* ]] && continue       # blank / comment
    line="${line#export }"
    key="${line%%=*}"; val="${line#*=}"
    key="${key//[[:space:]]/}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    val="${val%"${val##*[![:space:]]}"}"                  # rtrim
    if [[ "$val" == \"*\" || "$val" == \'*\' ]]; then val="${val:1:${#val}-2}"; fi
    if [[ -z "${!key+x}" ]]; then export "$key=$val"; fi
  done < "$f"
}
load_env_file "$ENV_FILE"

# Defaults (only applied when neither shell nor env file set them)
: "${DBT_BQ_LOCATION:=us-central1}"
: "${DBT_DEFAULT_DATASET:=dbt_bq_demo}"
: "${KC_LOCATION:=${DBT_BQ_LOCATION}}"
: "${KC_ENTRY_GROUP:=dbt-metadata-ingestion}"
: "${KC_STAGING_PREFIX:=dbt-imports}"
: "${KC_SKIP_BIGQUERY_LINK:=false}"
: "${KC_PROJECT_ID:=${DBT_GCP_PROJECT:-}}"
: "${ENABLE_DATA_LINEAGE:=true}"
export DBT_BQ_LOCATION DBT_DEFAULT_DATASET

is_placeholder() { [[ -z "${1:-}" || "$1" == YOUR_* || "$1" == *_PLACEHOLDER ]]; }

# Pin the gcloud identity: every gcloud invocation from this script uses
# GCLOUD_ACCOUNT (if configured) regardless of the active gcloud config.
if ! is_placeholder "${GCLOUD_ACCOUNT:-}"; then
  export CLOUDSDK_CORE_ACCOUNT="${GCLOUD_ACCOUNT}"
else
  GCLOUD_ACCOUNT=""
fi
IN_CLOUD_SHELL=false; [[ "${CLOUD_SHELL:-}" == "true" ]] && IN_CLOUD_SHELL=true

# require_vars VAR...  -> dies listing any unset / placeholder variables
require_vars() {
  local missing=() v
  for v in "$@"; do
    if is_placeholder "${!v:-}"; then missing+=("$v"); fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "please set these variables in ${ENV_FILE} (see .env.example): ${missing[*]}"
  fi
}

STORAGE_URI="gs://${KC_STAGING_BUCKET:-YOUR_STAGING_BUCKET_NAME}/${KC_STAGING_PREFIX%/}/"

# ----------------------------------------------------------------------------- tools
find_dbt() {
  local candidate
  for candidate in \
      "${DBT_BIN:-}" \
      "$(command -v dbt 2>/dev/null || true)" \
      "${REPO_ROOT}/../venv/bin/dbt" \
      "${REPO_ROOT}/venv/bin/dbt" \
      "${REPO_ROOT}/.venv/bin/dbt"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      printf '%s' "$candidate"; return 0
    fi
  done
  return 1
}

# Prints the installed dbt version (e.g. 1.12.5). Falls back to 0 on failure.
dbt_version() {
  local out ver
  out="$("$DBT_BIN" --version 2>/dev/null || true)"
  ver="$(printf '%s\n' "$out" | sed -nE 's/.*installed:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -n1)"
  if [[ -z "$ver" ]]; then
    ver="$(printf '%s\n' "$out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
  fi
  if [[ -z "$ver" ]] && printf '%s' "$out" | grep -qi fusion; then ver="2.0.0"; fi
  printf '%s' "${ver:-0}"
}

# Is GCLOUD_ACCOUNT among the credentialed gcloud accounts? (no network call)
gcloud_account_authenticated() {
  [[ -n "$GCLOUD_ACCOUNT" ]] || return 0
  local_cmd gcloud auth list --filter="account=${GCLOUD_ACCOUNT}" --format='value(account)' 2>/dev/null \
    | grep -qx "${GCLOUD_ACCOUNT}"
}

need_gcloud() {
  command -v gcloud >/dev/null 2>&1 || die "gcloud CLI not found. Install: https://cloud.google.com/sdk/docs/install"
  [[ "$DRY_RUN" == true ]] && return 0
  if ! gcloud_account_authenticated; then
    if [[ "$IN_CLOUD_SHELL" == true ]]; then
      die "Cloud Shell is not authenticated as ${GCLOUD_ACCOUNT}. Open Cloud Shell as that user, or run: gcloud auth login ${GCLOUD_ACCOUNT}"
    fi
    die "gcloud has no credentials for ${GCLOUD_ACCOUNT}. Run: gcloud auth login ${GCLOUD_ACCOUNT}"
  fi
}

GCLOUD_VERSION=""
gcloud_version_ok() {
  local major
  [[ -n "$GCLOUD_VERSION" ]] || GCLOUD_VERSION="$(local_cmd gcloud version --format='value("Google Cloud SDK")' 2>/dev/null || true)"
  major="${GCLOUD_VERSION%%.*}"
  [[ -n "$major" && "$major" =~ ^[0-9]+$ && "$major" -ge 586 ]]
}

# Where will dbt's Application Default Credentials come from? (no network call)
adc_source() {
  local adc_file="${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}/application_default_credentials.json"
  if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]]; then
    printf 'GOOGLE_APPLICATION_CREDENTIALS=%s' "${GOOGLE_APPLICATION_CREDENTIALS}"
  elif [[ -f "$adc_file" ]]; then
    printf 'gcloud auth application-default login (%s)' "$adc_file"
  elif [[ "$IN_CLOUD_SHELL" == true ]]; then
    printf 'Cloud Shell (automatic, identity of the logged-in user)'
  else
    printf 'none'
  fi
}

# Best-effort: e-mail of the identity behind the current ADC (needs network).
adc_email() {
  local token
  command -v curl >/dev/null 2>&1 || return 0
  token="$(query gcloud auth application-default print-access-token 2>/dev/null || true)"
  [[ -n "$token" ]] || return 0
  trace 'curl -s -d "access_token=***" https://oauth2.googleapis.com/tokeninfo   # identity behind ADC'
  curl -s --max-time 10 -d "access_token=${token}" https://oauth2.googleapis.com/tokeninfo 2>/dev/null \
    | sed -nE 's/.*"email"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n1
}

# Refuse to run dbt when ADC resolve to a different *user* than GCLOUD_ACCOUNT.
# Service accounts are allowed (CI). Override with ALLOW_ADC_MISMATCH=true.
adc_guard() {
  [[ -n "$GCLOUD_ACCOUNT" && "$DRY_RUN" == false ]] || return 0
  local email; email="$(adc_email)"
  if [[ -z "$email" ]]; then
    if [[ "$(adc_source)" == "none" ]]; then
      die "no Application Default Credentials for dbt. Run: gcloud auth application-default login   (not needed in Cloud Shell)"
    fi
    warn "could not determine the ADC identity; continuing"; return 0
  fi
  if [[ "$email" == "$GCLOUD_ACCOUNT" || "$email" == *.gserviceaccount.com ]]; then
    ok "dbt will authenticate as ${email}"; return 0
  fi
  [[ "${ALLOW_ADC_MISMATCH:-false}" == "true" ]] && { warn "ADC identity ${email} != ${GCLOUD_ACCOUNT} (override active)"; return 0; }
  die "Application Default Credentials belong to ${email}, not ${GCLOUD_ACCOUNT}. Run: gcloud auth application-default login   (or set ALLOW_ADC_MISMATCH=true)"
}

# ----------------------------------------------------------------------------- commands
cmd_check() {
  log "repo root       : ${REPO_ROOT}"
  log "env file        : ${ENV_FILE} $([[ -f "$ENV_FILE" ]] && echo '(found)' || echo '(missing)')"
  log "dry run         : ${DRY_RUN}"
  echo
  log "dbt / BigQuery"
  printf '    %-22s %s\n' DBT_GCP_PROJECT "${DBT_GCP_PROJECT:-<unset>}" DBT_BQ_LOCATION "${DBT_BQ_LOCATION}" DBT_DEFAULT_DATASET "${DBT_DEFAULT_DATASET}"
  log "Knowledge Catalog"
  printf '    %-22s %s\n' KC_PROJECT_ID "${KC_PROJECT_ID:-<unset>}" KC_LOCATION "${KC_LOCATION}" KC_ENTRY_GROUP "${KC_ENTRY_GROUP}" \
         KC_STAGING_BUCKET "${KC_STAGING_BUCKET:-<unset>}" KC_STAGING_PREFIX "${KC_STAGING_PREFIX}" STORAGE_URI "${STORAGE_URI}" \
         KC_SKIP_BIGQUERY_LINK "${KC_SKIP_BIGQUERY_LINK}" KC_PRINCIPAL "${KC_PRINCIPAL:-<unset>}" ENABLE_DATA_LINEAGE "${ENABLE_DATA_LINEAGE}"
  echo
  local problems=0
  if DBT_BIN="$(find_dbt)"; then
    ok "dbt found: ${DBT_BIN} (version $(dbt_version))"
  else
    warn "dbt not found (activate the venv or set DBT_BIN)"; problems=$((problems+1))
  fi
  if command -v gcloud >/dev/null 2>&1; then
    if gcloud_version_ok; then ok "gcloud found: ${GCLOUD_VERSION} (>= 586 required for dbt import)"
    else warn "gcloud version is < 586.0.0; run: gcloud components update"; problems=$((problems+1)); fi
  else
    warn "gcloud not found"; problems=$((problems+1))
  fi
  local v
  for v in DBT_GCP_PROJECT KC_PROJECT_ID KC_STAGING_BUCKET; do
    if is_placeholder "${!v:-}"; then warn "${v} is not set / still a placeholder"; problems=$((problems+1)); fi
  done
  if [[ "$KC_LOCATION" != "$DBT_BQ_LOCATION" ]]; then
    warn "KC_LOCATION (${KC_LOCATION}) != DBT_BQ_LOCATION (${DBT_BQ_LOCATION}): dbt -> BigQuery entry links will be skipped for datasets outside the import location"
  fi
  echo
  log "identity"
  printf '    %-22s %s\n' GCLOUD_ACCOUNT "${GCLOUD_ACCOUNT:-<unset: active gcloud account is used>}" \
         "Cloud Shell" "${IN_CLOUD_SHELL}" "ADC source (dbt)" "$(adc_source)"
  if command -v gcloud >/dev/null 2>&1; then
    if [[ -n "$GCLOUD_ACCOUNT" ]]; then
      if gcloud_account_authenticated; then ok "gcloud is authenticated as ${GCLOUD_ACCOUNT}"
      else warn "gcloud has no credentials for ${GCLOUD_ACCOUNT}: run  gcloud auth login ${GCLOUD_ACCOUNT}"; problems=$((problems+1)); fi
    else
      log "active gcloud account: $(local_cmd gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null || echo '<none>')"
    fi
    if [[ "$DRY_RUN" == false ]]; then
      local email; email="$(adc_email)"
      if [[ -n "$email" ]]; then
        if [[ -z "$GCLOUD_ACCOUNT" || "$email" == "$GCLOUD_ACCOUNT" || "$email" == *.gserviceaccount.com ]]; then ok "dbt (ADC) will authenticate as ${email}"
        else warn "dbt (ADC) would authenticate as ${email}, not ${GCLOUD_ACCOUNT}: run  gcloud auth application-default login"; problems=$((problems+1)); fi
      elif [[ "$(adc_source)" == "none" ]]; then
        warn "no Application Default Credentials for dbt: run  gcloud auth application-default login  (automatic in Cloud Shell)"; problems=$((problems+1))
      fi
    fi
  fi
  echo
  if [[ $problems -eq 0 ]]; then ok "all checks passed"; else warn "${problems} problem(s) found"; return 1; fi
}

cmd_setup() {
  need_gcloud
  require_vars KC_PROJECT_ID KC_LOCATION KC_ENTRY_GROUP KC_STAGING_BUCKET
  # cloudresourcemanager: used by `gcloud dataplex dbt` to resolve projects.
  # datalineage: once enabled, BigQuery records native lineage (CTAS/INSERT/MERGE/
  # load jobs) for every job run *afterwards*; read it with `kc_import.sh lineage`.
  local kc_apis=(dataplex.googleapis.com storage.googleapis.com cloudresourcemanager.googleapis.com)
  local data_apis=(bigquery.googleapis.com dataplex.googleapis.com cloudresourcemanager.googleapis.com)
  if [[ "${ENABLE_DATA_LINEAGE,,}" == "true" ]]; then
    kc_apis+=(datalineage.googleapis.com); data_apis+=(datalineage.googleapis.com)
  fi
  if ! is_placeholder "${DBT_GCP_PROJECT:-}" && [[ "${DBT_GCP_PROJECT}" != "${KC_PROJECT_ID}" ]]; then
    log "enabling APIs in the catalog project ${KC_PROJECT_ID}"
    run gcloud services enable "${kc_apis[@]}" --project="${KC_PROJECT_ID}"
    log "enabling APIs in the BigQuery project ${DBT_GCP_PROJECT}"
    run gcloud services enable "${data_apis[@]}" --project="${DBT_GCP_PROJECT}"
  else
    log "enabling APIs in ${KC_PROJECT_ID}"
    run gcloud services enable "${kc_apis[@]}" bigquery.googleapis.com --project="${KC_PROJECT_ID}"
  fi

  log "provisioning the Knowledge Catalog service agent"
  run gcloud beta services identity create --service=dataplex.googleapis.com --project="${KC_PROJECT_ID}" || \
    warn "could not provision the service identity explicitly; it is usually created automatically"

  local project_number service_agent
  project_number="$(query gcloud projects describe "${KC_PROJECT_ID}" --format='value(projectNumber)' || true)"
  if [[ "$DRY_RUN" == true ]]; then project_number="<PROJECT_NUMBER>"; fi
  [[ -n "$project_number" ]] || die "could not resolve the project number for ${KC_PROJECT_ID}"
  service_agent="service-${project_number}@gcp-sa-dataplex.iam.gserviceaccount.com"

  log "entry group ${KC_ENTRY_GROUP} in ${KC_PROJECT_ID}/${KC_LOCATION}"
  if query gcloud dataplex entry-groups describe "${KC_ENTRY_GROUP}" \
        --location="${KC_LOCATION}" --project="${KC_PROJECT_ID}" >/dev/null 2>&1; then
    ok "entry group already exists"
  else
    run gcloud dataplex entry-groups create "${KC_ENTRY_GROUP}" \
      --location="${KC_LOCATION}" --project="${KC_PROJECT_ID}" \
      --display-name="dbt metadata" \
      --description="dbt Core metadata imported via gcloud dataplex dbt metadata-jobs"
  fi

  log "staging bucket gs://${KC_STAGING_BUCKET}"
  if query gcloud storage buckets describe "gs://${KC_STAGING_BUCKET}" >/dev/null 2>&1; then
    ok "bucket already exists"
  else
    run gcloud storage buckets create "gs://${KC_STAGING_BUCKET}" \
      --project="${KC_PROJECT_ID}" --location="${KC_LOCATION}" --uniform-bucket-level-access
  fi

  log "granting roles/storage.objectViewer on the staging bucket to ${service_agent}"
  run gcloud storage buckets add-iam-policy-binding "gs://${KC_STAGING_BUCKET}" \
    --member="serviceAccount:${service_agent}" --role="roles/storage.objectViewer"

  ok "setup complete. Next: scripts/kc_import.sh iam   (optional)  then  scripts/kc_import.sh all"
}

cmd_iam() {
  need_gcloud
  require_vars KC_PROJECT_ID KC_STAGING_BUCKET KC_PRINCIPAL
  log "granting import roles to ${KC_PRINCIPAL}"
  run gcloud projects add-iam-policy-binding "${KC_PROJECT_ID}" --member="${KC_PRINCIPAL}" --role="roles/dataplex.metadataJobOwner"
  # entryGroupOwner (rather than entryGroupImporter) is required when entry links are emitted (default).
  run gcloud projects add-iam-policy-binding "${KC_PROJECT_ID}" --member="${KC_PRINCIPAL}" --role="roles/dataplex.entryGroupOwner"
  run gcloud storage buckets add-iam-policy-binding "gs://${KC_STAGING_BUCKET}" --member="${KC_PRINCIPAL}" --role="roles/storage.objectCreator"
  if ! is_placeholder "${DBT_GCP_PROJECT:-}"; then
    # Needed for dbt model -> BigQuery table reference links.
    run gcloud projects add-iam-policy-binding "${DBT_GCP_PROJECT}" --member="${KC_PRINCIPAL}" --role="roles/dataplex.entryOwner"
  fi
  ok "IAM grants done (viewer role for browsing: roles/dataplex.catalogViewer)"
}

cmd_generate() {
  DBT_BIN="$(find_dbt)" || die "dbt not found. Run scripts/bootstrap.sh (creates the venv) or set DBT_BIN"
  adc_guard
  require_vars DBT_GCP_PROJECT
  export DBT_PROFILES_DIR="${DBT_PROFILES_DIR:-$REPO_ROOT}"
  local ver major dbt_target=()
  ver="$(dbt_version)"; major="${ver%%.*}"
  [[ -n "${DBT_TARGET:-}" ]] && dbt_target=(--target "${DBT_TARGET}")
  log "dbt ${ver} at ${DBT_BIN}; project ${REPO_ROOT}; BigQuery project ${DBT_GCP_PROJECT} (${DBT_BQ_LOCATION})"
  cd "${REPO_ROOT}"

  if [[ -f packages.yml || -f dependencies.yml ]]; then
    run "$DBT_BIN" deps || die "dbt deps failed"
  fi

  # Demo-only pre-step: load the seed CSVs so the `sources` tables exist before
  # freshness is measured (metadata-based freshness uses last-modified time).
  # This is also the first command that opens a BigQuery connection, so a hard
  # failure here (auth, project, permissions) aborts the run early.
  if [[ "$RUN_SEED" == true ]]; then
    run "$DBT_BIN" seed ${dbt_target[@]+"${dbt_target[@]}"} || die "dbt seed failed - check authentication (gcloud auth application-default login) and DBT_GCP_PROJECT"
  fi

  # Per the Knowledge Catalog docs, chain these with ';' semantics: a failing
  # test makes `dbt build` exit non-zero but the verdicts must still be imported.
  local rc_fresh=0 rc_build=0 rc_catalog=0
  run "$DBT_BIN" source freshness ${dbt_target[@]+"${dbt_target[@]}"} || rc_fresh=$?
  run "$DBT_BIN" build ${dbt_target[@]+"${dbt_target[@]}"}            || rc_build=$?

  if [[ "$major" -ge 2 ]]; then
    # dbt Core 2.x / Fusion: `docs generate` does not write catalog.json.
    run "$DBT_BIN" parse --write-catalog ${dbt_target[@]+"${dbt_target[@]}"} || rc_catalog=$?
  else
    # dbt Core 1.x: --no-compile keeps run_results.json from `dbt build` intact.
    run "$DBT_BIN" docs generate --no-compile ${dbt_target[@]+"${dbt_target[@]}"} || rc_catalog=$?
  fi

  echo
  log "exit codes: source freshness=${rc_fresh}  build=${rc_build}  catalog=${rc_catalog}"
  [[ $rc_fresh   -ne 0 ]] && warn "source freshness reported warnings/errors (still imported as freshness status)"
  [[ $rc_catalog -ne 0 ]] && warn "catalog generation failed: schema columns will be imported untyped"

  if [[ "$DRY_RUN" == true ]]; then return 0; fi
  local f missing=0
  for f in manifest.json catalog.json run_results.json sources.json; do
    if [[ -f "${ARTIFACTS_DIR}/${f}" ]]; then
      ok "artifact ${f} ($(date -u -r "${ARTIFACTS_DIR}/${f}" +%Y-%m-%dT%H:%M:%SZ))"
    else
      warn "artifact ${f} missing"; missing=$((missing+1))
    fi
  done
  [[ -f "${ARTIFACTS_DIR}/manifest.json" ]] || die "manifest.json is required for the import"
  [[ $missing -gt 0 ]] && warn "import will degrade gracefully without the missing optional artifacts"

  # Distinguish test *failures* (imported by design) from *runtime errors*
  # (table not found, permissions, contract violations ...). Runtime errors
  # skip every downstream node, so importing that run would publish a
  # half-built DAG; stop here unless --force is given.
  if [[ $rc_build -ne 0 ]]; then
    local rc_summary=0
    summarize_run_results || rc_summary=$?
    if [[ $rc_summary -eq 2 ]]; then
      if [[ "$FORCE" == true ]]; then
        warn "dbt build had runtime errors; continuing because --force was given"
      else
        die "dbt build had runtime errors (listed above) and skipped downstream nodes. Fix the cause (logs/dbt.log) and re-run, or pass --force to import anyway."
      fi
    else
      warn "dbt build exited non-zero because of failing tests; the verdicts will be imported as data-quality results"
    fi
  else
    summarize_run_results || true
  fi
  return 0
}

# Prints a status histogram of target/run_results.json and the runtime errors.
# Exit code: 0 = no runtime errors, 2 = runtime errors present.
summarize_run_results() {
  local py; py="$(dirname "$DBT_BIN")/python"; [[ -x "$py" ]] || py="python3"
  [[ -f "${ARTIFACTS_DIR}/run_results.json" ]] || { warn "no run_results.json to summarize"; return 0; }
  "$py" - "${ARTIFACTS_DIR}/run_results.json" <<'PY'
import json, sys, collections
results = json.load(open(sys.argv[1])).get("results", [])
hist = collections.Counter(r.get("status") for r in results)
print("[kc] dbt build results: " + ", ".join(f"{k}={v}" for k, v in sorted(hist.items(), key=lambda kv: str(kv[0]))))
errors = [r for r in results if r.get("status") in ("error", "runtime error")]
for r in errors:
    msg = (r.get("message") or "").strip().splitlines()
    print(f"[kc] RUNTIME ERROR {r.get('unique_id')}: {msg[0] if msg else ''}", file=sys.stderr)
sys.exit(2 if errors else 0)
PY
}

cmd_import() {
  need_gcloud
  require_vars KC_PROJECT_ID KC_LOCATION KC_ENTRY_GROUP KC_STAGING_BUCKET
  if [[ "$DRY_RUN" == false && ! -f "${ARTIFACTS_DIR}/manifest.json" ]]; then
    die "no manifest.json in ${ARTIFACTS_DIR}; run: scripts/kc_import.sh generate"
  fi
  local job_id="${JOB_ID:-dbt-bq-demo-$(date -u +%Y%m%d-%H%M%S)}"
  local args=(
    "$job_id"
    --project="${KC_PROJECT_ID}"
    --location="${KC_LOCATION}"
    --artifacts-path="${ARTIFACTS_DIR}"
    --entry-group="${KC_ENTRY_GROUP}"
    --storage-uri="${STORAGE_URI}"
  )
  [[ "$ASPECTS_ONLY"  == true ]] && args+=(--aspects-only)
  [[ "$VALIDATE_ONLY" == true ]] && args+=(--validate-only)
  [[ "$ASYNC"         == true ]] && args+=(--async)
  if [[ "$SKIP_BQ_LINK_FLAG" == true || "${KC_SKIP_BIGQUERY_LINK,,}" == "true" ]]; then
    args+=(--skip-bigquery-link)
  fi

  log "creating Knowledge Catalog metadata job ${job_id} (mode: $([[ "$ASPECTS_ONLY" == true ]] && echo 'aspects-only refresh' || echo 'full sync'))"
  run gcloud dataplex dbt metadata-jobs create "${args[@]}"
  if [[ "$DRY_RUN" == false ]]; then
    mkdir -p "${ARTIFACTS_DIR}"; printf '%s\n' "$job_id" > "${LAST_JOB_FILE}"
  fi
  ok "job ${job_id} submitted. Check with: scripts/kc_import.sh status --job-id ${job_id}"
  log "browse: https://console.cloud.google.com/dataplex/search?project=${KC_PROJECT_ID}&q=system%3DDBT"
}

cmd_status() {
  need_gcloud
  require_vars KC_PROJECT_ID KC_LOCATION
  local job_id="${JOB_ID:-}"
  if [[ -z "$job_id" && -f "${LAST_JOB_FILE}" ]]; then job_id="$(<"${LAST_JOB_FILE}")"; fi
  [[ -n "$job_id" ]] || die "no job id: pass --job-id ID (or run an import first)"
  run gcloud dataplex metadata-jobs describe "${job_id}" --project="${KC_PROJECT_ID}" --location="${KC_LOCATION}"
}

cmd_search() {
  need_gcloud
  require_vars KC_PROJECT_ID
  local query="${EXTRA_ARGS[0]:-system=DBT}"
  # Without --scope gcloud searches the project's *organization*; for projects
  # outside an organization that resolves to nothing and the result is empty.
  # Override with KC_SEARCH_SCOPE=organizations/<org_id> to search org-wide.
  local scope="${KC_SEARCH_SCOPE:-projects/${KC_PROJECT_ID}}"
  run gcloud dataplex entries search "${query}" --project="${KC_PROJECT_ID}" --scope="${scope}"
}

# BigQuery-native lineage from the Data Lineage API (needs datalineage.googleapis.com
# enabled in the BigQuery project *before* the dbt jobs ran). Arguments: table FQNs
# (bigquery:project.dataset.table); defaults to the six demo tables.
cmd_lineage() {
  need_gcloud
  require_vars DBT_GCP_PROJECT DBT_BQ_LOCATION KC_PROJECT_ID
  # Lineage is looked up in the BigQuery project (where BigQuery records its own
  # events) and, if different, in the catalog project (where a connector could
  # emit dbt-originated events) - both for the same table FQNs.
  local base="https://datalineage.googleapis.com/v1/projects/${DBT_GCP_PROJECT}/locations/${DBT_BQ_LOCATION}"
  local base_kc="https://datalineage.googleapis.com/v1/projects/${KC_PROJECT_ID}/locations/${KC_LOCATION}"
  [[ "${KC_PROJECT_ID}" == "${DBT_GCP_PROJECT}" ]] && base_kc=""
  local fqns=("${EXTRA_ARGS[@]}")
  if [[ ${#fqns[@]} -eq 0 ]]; then
    local ds t
    for ds in sources landing raw; do for t in customers sales; do fqns+=("bigquery:${DBT_GCP_PROJECT}.${ds}.${t}"); done; done
  fi
  log "Data Lineage API: ${base}"
  if [[ "$DRY_RUN" == true ]]; then
    printf '%s$ curl -X POST -H "Authorization: Bearer $(gcloud auth print-access-token)" %s:searchLinks -d '"'"'{"target":{"fullyQualifiedName":"%s"}}'"'"'%s\n' "$C_DIM" "$base" "${fqns[0]}" "$C_RST"
    printf '%s$ curl -H "Authorization: Bearer $(gcloud auth print-access-token)" %s/processes%s\n' "$C_DIM" "$base" "$C_RST"
    return 0
  fi
  local py; py="$(command -v python3 || true)"; [[ -n "$py" ]] || die "python3 is required for the lineage command"
  local token; token="$(query gcloud auth print-access-token)"
  LINEAGE_TOKEN="$token" KC_CMD_LOG="$CMD_LOG" LINEAGE_BASE_KC="$base_kc" "$py" - "$base" "${fqns[@]}" <<'PY'
import json, os, sys, time, urllib.request, urllib.error
base, *fqns = sys.argv[1:]
bases = [b for b in (base, os.environ.get("LINEAGE_BASE_KC", "")) if b]
hdr = {"Authorization": f"Bearer {os.environ['LINEAGE_TOKEN']}", "Content-Type": "application/json"}

def trace(line):   # mirror the shell tracer: echo + append to the command log (token redacted)
    print(f"\033[2m$ {line}\033[0m", file=sys.stderr)
    try:
        with open(os.environ["KC_CMD_LOG"], "a") as f:
            f.write(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()) + "  " + line + "\n")
    except Exception:
        pass

def call(url, body=None):
    if body is None:
        trace(f'curl -s -H "Authorization: Bearer ***" {url}')
    else:
        trace(f'curl -s -X POST -H "Authorization: Bearer ***" -H "Content-Type: application/json" {url} -d \'{json.dumps(body)}\'')
    req = urllib.request.Request(url, data=json.dumps(body).encode() if body is not None else None, headers=hdr,
                                 method="POST" if body is not None else "GET")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")
        if e.code == 403 and "datalineage.googleapis.com" in detail:
            sys.exit("[kc] ERROR: Data Lineage API is not enabled in this project. Run: scripts/kc_import.sh setup")
        sys.exit(f"[kc] ERROR: HTTP {e.code} from {url}: {detail[:400]}")

# Links: searchLinks returns every link the caller may see, whichever project is
# in the URL (that project is only used for billing/quota) - so query once.
pairs = {}
for fqn in fqns:
    for side in ("source", "target"):
        body, token = {side: {"fullyQualifiedName": fqn}, "pageSize": 100}, None
        while True:
            if token: body["pageToken"] = token
            data = call(f"{base}:searchLinks", body)
            for l in data.get("links", []):
                key = (l["source"]["fullyQualifiedName"], l["target"]["fullyQualifiedName"])
                pairs[key] = max(pairs.get(key, ""), l.get("endTime") or l.get("startTime") or "")
            token = data.get("nextPageToken")
            if not token: break
print()
if not pairs:
    print("[kc] no lineage links for the requested tables.")
    print("     BigQuery records lineage only for jobs run AFTER the API was enabled, and it can take a few")
    print("     minutes to appear. Run `scripts/kc_import.sh generate` or `dbt build` and retry.")
else:
    print(f"[kc] {len(pairs)} lineage link(s) (source -> target, last seen):")
    for (s, t), ts in sorted(pairs.items()):
        print(f"   {s}  ->  {t}   {ts[:19]}")

# Processes ARE stored per project: BigQuery's own jobs live in the BigQuery
# project; anything a connector emitted would live in the catalog project.
for b in bases:
    where = b.split("/projects/", 1)[-1]
    procs = call(f"{b}/processes?pageSize=100").get("processes", [])
    print(f"\n[kc] {len(procs)} lineage process(es) recorded under projects/{where}" + ("" if procs else "  (none)"))
    for p in procs:
        origin = (p.get("origin") or {}).get("sourceType", "")
        print(f"   {p.get('displayName', p['name'].rsplit('/', 1)[-1])}   origin={origin}   {p['name'].rsplit('/', 1)[-1]}")
PY
}

cmd_history() {
  [[ -f "$CMD_LOG" ]] || die "no command log yet at ${CMD_LOG}"
  log "commands executed by scripts/kc_import.sh (${CMD_LOG}):"
  cat "$CMD_LOG"
}

# Physical -> logical proof: for each BigQuery table, list the Knowledge Catalog
# entry links in which the table is the TARGET, i.e. the dbt entries (models,
# seeds) that materialize it. Arguments: table FQNs; defaults to the six demo tables.
cmd_links() {
  need_gcloud
  require_vars DBT_GCP_PROJECT DBT_BQ_LOCATION KC_PROJECT_ID
  local fqns=("${EXTRA_ARGS[@]}")
  if [[ ${#fqns[@]} -eq 0 ]]; then
    local ds t
    for ds in sources landing raw; do for t in customers sales; do fqns+=("bigquery:${DBT_GCP_PROJECT}.${ds}.${t}"); done; done
  fi
  log "Knowledge Catalog entry links where the BigQuery table is the TARGET (reference links)"
  if [[ "$DRY_RUN" == true ]]; then
    printf '%s$ curl -G -H "Authorization: Bearer $(gcloud auth print-access-token)" https://dataplex.googleapis.com/v1/projects/%s/locations/%s:lookupEntryLinks --data-urlencode entry=<bigquery entry of %s> --data-urlencode entryMode=TARGET --data-urlencode entryLinkTypes=projects/dataplex-types/locations/global/entryLinkTypes/reference%s\n' "$C_DIM" "$KC_PROJECT_ID" "$KC_LOCATION" "${fqns[0]}" "$C_RST"
    return 0
  fi
  local py; py="$(command -v python3 || true)"; [[ -n "$py" ]] || die "python3 is required for the links command"
  local token; token="$(query gcloud auth print-access-token)"
  LINEAGE_TOKEN="$token" KC_CMD_LOG="$CMD_LOG" "$py" - "$DBT_GCP_PROJECT" "$DBT_BQ_LOCATION" "$KC_PROJECT_ID" "${fqns[@]}" <<'PY'
import json, os, sys, time, urllib.request, urllib.error, urllib.parse
data_project, loc, kc_project, *fqns = sys.argv[1:]
hdr = {"Authorization": f"Bearer {os.environ['LINEAGE_TOKEN']}"}
REF = "projects/dataplex-types/locations/global/entryLinkTypes/reference"
API = "https://dataplex.googleapis.com/v1"

def trace(line):
    print(f"\033[2m$ {line}\033[0m", file=sys.stderr)
    try:
        with open(os.environ["KC_CMD_LOG"], "a") as f:
            f.write(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()) + "  " + line + "\n")
    except Exception:
        pass

def lookup(parent, entry):
    qs = urllib.parse.urlencode({"entry": entry, "entryMode": "TARGET", "entryLinkTypes": REF})
    url = f"{API}/{parent}:lookupEntryLinks?{qs}"
    trace(f'curl -s -H "Authorization: Bearer ***" "{url}"')
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=hdr), timeout=60) as r:
            return json.load(r).get("entryLinks", []), None
    except urllib.error.HTTPError as e:
        return [], f"HTTP {e.code}: {e.read().decode(errors='replace')[:200]}"

short = lambda n: n.split("/entries/", 1)[-1]
total = 0
for fqn in fqns:
    try:
        _, rest = fqn.split(":", 1); project, dataset, table = rest.split(".")
    except ValueError:
        print(f"   skipping {fqn!r}: expected bigquery:project.dataset.table"); continue
    entry = (f"projects/{project}/locations/{loc}/entryGroups/@bigquery/entries/"
             f"bigquery.googleapis.com/projects/{project}/datasets/{dataset}/tables/{table}")
    # Attribute the lookup to the catalog project (where the links live and the
    # Dataplex API is guaranteed to be enabled); fall back to the table's project.
    links, err = lookup(f"projects/{kc_project}/locations/{loc}", entry)
    if not links and project != kc_project:
        links2, err2 = lookup(f"projects/{project}/locations/{loc}", entry)
        if links2: links, err = links2, None
        elif err2: err = err or err2
    print(f"\n{fqn}")
    if err and not links:
        print(f"   lookup failed: {err}"); continue
    if not links:
        print("   no entry links (not materialized by a dbt node in the last FULL import)"); continue
    for l in links:
        srcs = [short(r["name"]) for r in l["entryReferences"] if r.get("type") == "SOURCE"]
        group = l["name"].split("/entryGroups/", 1)[-1].split("/", 1)[0]
        for s in srcs:
            print(f"   <- {s}   [entry group {group}, link {l['name'].rsplit('/', 1)[-1]}]"); total += 1
print(f"\n[kc] {total} dbt entry/entries linked to {len(fqns)} physical table(s)")
PY
}

[[ "$COMMAND" == history ]] || { trace_header; TRACE_START_LINE="$(wc -l < "$CMD_LOG" 2>/dev/null || echo 0)"; trap trace_footer EXIT; }

case "$COMMAND" in
  check)    cmd_check ;;
  setup)    cmd_setup ;;
  iam)      cmd_iam ;;
  generate) cmd_generate ;;
  import)   cmd_import ;;
  all)      cmd_generate; cmd_import ;;
  status)   cmd_status ;;
  search)   cmd_search ;;
  lineage)  cmd_lineage ;;
  links)    cmd_links ;;
  history)  cmd_history ;;
esac
