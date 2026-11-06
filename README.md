# dbt_bq_demo

A minimal, layered **dbt Core + BigQuery** project used to demonstrate
importing dbt metadata into **Google Cloud Knowledge Catalog**
(formerly Dataplex Universal Catalog).

```
sources.customers ──▶ landing.customers ──▶ raw.customers ──▶ (curated) ──▶ (conformed)
sources.sales     ──▶ landing.sales     ──▶ raw.sales     ──▶ (curated) ──▶ (conformed)
  ▲ dbt seed            1:1 copy            typed / cleaned     no models yet
```

| Layer       | Folder             | BigQuery dataset | Content                                                                 |
|-------------|--------------------|------------------|-------------------------------------------------------------------------|
| sources     | `seeds/`           | `sources`        | Two demo extracts (`customers`, `sales`, ≤ 20 rows each), all `STRING`  |
| landing     | `models/landing/`  | `landing`        | 1:1 copy of each source + `_loaded_at`, `_dbt_invocation_id`            |
| raw         | `models/raw/`      | `raw`            | `SAFE_CAST` to real types, trim / case-normalise, de-duplicate on key   |
| curated     | `models/curated/`  | `curated`        | *placeholder – no models yet*                                           |
| conformed   | `models/conformed/`| `conformed`      | *placeholder – no models yet*                                           |

Dataset names are used verbatim thanks to
[`macros/generate_schema_name.sql`](macros/generate_schema_name.sql)
(dbt would otherwise prefix them with the profile dataset). Model names are
prefixed (`lnd_`, `raw_`) to stay unique inside dbt, while `alias` keeps the
physical table names identical across layers (`landing.customers`, `raw.customers`, …).

## Repository layout

```
dbt_bq_demo/
├── dbt_project.yml            layer -> dataset mapping, materialization, persist_docs
├── profiles.yml               BigQuery profile (OAuth / ADC), driven by env vars
├── .env.example               all placeholders (copy to .env)
├── requirements.txt           dbt-core 1.12.5, dbt-bigquery 1.12.1
├── Makefile                   shortcuts (make help)
├── macros/generate_schema_name.sql
├── seeds/                     customers.csv, sales.csv, _seeds.yml
├── models/
│   ├── landing/               _landing__sources.yml, lnd_customers.sql, lnd_sales.sql, _landing__models.yml
│   ├── raw/                   raw_customers.sql, raw_sales.sql, _raw__models.yml (contracts + tests)
│   ├── curated/.gitkeep
│   └── conformed/.gitkeep
└── scripts/kc_import.sh       generate artifacts + import into Knowledge Catalog
```

## Prerequisites

* Python 3.9+ (`scripts/bootstrap.sh` creates a virtualenv and installs pinned dbt)
* `gcloud` CLI **≥ 586.0.0** (needed for `gcloud alpha dataplex dbt …`) — Cloud Shell has it
* A GCP project with BigQuery enabled and permission to create datasets
* Application Default Credentials for dbt: automatic in Cloud Shell, otherwise
  `gcloud auth application-default login`

## Run in Cloud Shell (recommended)

1. Open [Cloud Shell](https://shell.cloud.google.com) **as the account set in
   `GCLOUD_ACCOUNT`** (`.env`). Everything is pinned to that account: the scripts
   export `CLOUDSDK_CORE_ACCOUNT`, refuse to run if that account is not
   authenticated, and refuse to run dbt if the Application Default Credentials
   belong to a different user.
2. Clone the repo, then:

```bash
git clone https://github.com/simonleewm/knowledge-catalog-import-dbt.git && cd knowledge-catalog-import-dbt
./scripts/bootstrap.sh            # venv + dbt install + identity/placeholder checks
./scripts/kc_import.sh setup      # one-time: APIs, service agent, entry group, bucket, bucket IAM
./scripts/kc_import.sh all        # dbt seed; source freshness; build; docs generate  ->  import
./scripts/kc_import.sh status     # metadata job status
./scripts/kc_import.sh search     # gcloud dataplex entries search 'system=DBT' --scope=projects/<KC_PROJECT_ID>
./scripts/kc_import.sh lineage    # BigQuery-native lineage of the demo tables (Data Lineage API)
./scripts/kc_import.sh links      # physical -> logical: which dbt entries claim each BigQuery table
```

`.env` is git-ignored: `bootstrap.sh` copies `.env.example` to `.env` on first run;
fill in the `YOUR_*` placeholders before `setup`. The demo was run with **two
projects** (a single project for both works just as well):

| Setting | Example | Holds |
|---|---|---|
| `DBT_GCP_PROJECT` | `<your-bigquery-project>` | BigQuery datasets `sources`, `landing`, `raw`, … |
| `KC_PROJECT_ID`   | `<your-catalog-project>`  | Knowledge Catalog entry group, metadata jobs, staging bucket |

With one account that is Owner on both projects no extra IAM is needed besides
the service-agent grant that `setup` performs. If you ever run as a less
privileged principal, `./scripts/kc_import.sh iam` grants the documented roles
to `KC_PRINCIPAL`.

> Cloud Shell sessions are ephemeral but `$HOME` persists, so the `.venv`
> created by `bootstrap.sh` survives; re-running it is a no-op.

## Quick start (local machine, dbt only)

```bash
cd dbt_bq_demo
./scripts/bootstrap.sh            # or: make bootstrap   (uses ../venv if it has dbt, else ./.venv)
cp .env.example .env              # fill in DBT_GCP_PROJECT, GCLOUD_ACCOUNT (and the KC_* values for the import)
set -a; source .env; set +a       # not needed when using make / scripts/kc_import.sh
gcloud auth application-default login

dbt parse                         # offline validation – no BigQuery connection
dbt seed                          # loads sources.customers / sources.sales
dbt build                         # landing + raw models and all tests
dbt source freshness              # metadata-based freshness of the source tables
dbt docs generate && dbt docs serve
```

`dbt` here means `<venv>/bin/dbt` (activate the venv or use the `make` targets).


### What the demo data exercises

* every source column is `STRING`; raw casts to `INT64 / NUMERIC / DATE / TIMESTAMP`
* mixed-case emails, country codes, statuses and channels are normalised in raw
* `customers` contains `customer_id = 1002` twice and `sales` contains
  `sale_id = 5009` twice (later `updated_at` wins) – raw keeps one row each
* tests: `not_null` on keys (seeds, landing, raw), `unique` + `accepted_values` in raw,
  and a `relationships` test `raw_sales.customer_id → raw_customers.customer_id`
  (Knowledge Catalog turns this into a *schema-join* entry link)
* raw models have **enforced contracts** (`dbt-model-contracts` aspect)

> Tests that could legitimately fail (`unique`) are placed on the raw layer only.
> In `dbt build` a failing test on a landing model would skip the downstream raw models.

### Why the landing models carry `-- depends_on: {{ ref('<seed>') }}`

In dbt's graph a seed and a source are unrelated nodes. During `dbt build` the
seeds are **reloaded** (dbt-bigquery drops and recreates the table) at the same
time as anything that reads the source table, because nothing orders them.
That race surfaces as `Not found: Table …sources.sales` on a source test or a
landing model, after which every downstream node is skipped.

The one-line hint in `lnd_customers.sql` / `lnd_sales.sql` gives dbt the edge
*seed → landing model*, so the seed always finishes first; the data is still
read through `source()`. For the same reason there are no tests declared on
the sources themselves (the seeds and landing models carry the same `not_null`
checks). In a real deployment, where an external pipeline loads the `sources`
dataset, delete the hint and put the tests back on the sources.

## Knowledge Catalog import

Implements <https://docs.cloud.google.com/knowledge-catalog/docs/dbt-transfer>.
All configuration lives in `.env` (placeholders in `.env.example`):

| Variable                | Purpose                                                                    |
|-------------------------|----------------------------------------------------------------------------|
| `GCLOUD_ACCOUNT`        | account every `gcloud`/dbt call must run as (pinned via `CLOUDSDK_CORE_ACCOUNT`; ADC identity is verified) |
| `KC_PROJECT_ID`         | project owning the entry group and metadata job                            |
| `KC_LOCATION`           | region of the entry group (e.g. `us-central1`); keep equal to `DBT_BQ_LOCATION` |
| `KC_ENTRY_GROUP`        | destination entry group (default `dbt-metadata-ingestion`)                 |
| `KC_STAGING_BUCKET`     | output/staging bucket; the transformed `dbt_metadata.jsonl` is uploaded here |
| `KC_STAGING_PREFIX`     | object prefix in that bucket (default `dbt-imports`)                       |
| `KC_SKIP_BIGQUERY_LINK` | `true` if the BigQuery tables are not cataloged (adds `--skip-bigquery-link`) |
| `ENABLE_DATA_LINEAGE`   | `true` (default): `setup` also enables the Data Lineage API so BigQuery records native lineage |
| `KC_PRINCIPAL`          | optional; `user:…` / `serviceAccount:…` for `kc_import.sh iam`             |

### Steps

```bash
scripts/kc_import.sh check          # tooling + placeholders
scripts/kc_import.sh setup          # one-time: API, service agent, entry group, bucket, bucket IAM
scripts/kc_import.sh iam            # optional: grant your principal the import roles
scripts/kc_import.sh generate       # dbt seed; dbt source freshness; dbt build; dbt docs generate --no-compile
scripts/kc_import.sh import         # gcloud alpha dataplex dbt metadata-jobs create … (full sync)
scripts/kc_import.sh status         # describe the job
scripts/kc_import.sh search         # gcloud dataplex entries search 'system=DBT'
```

`scripts/kc_import.sh all` runs `generate` + `import`. Add `--dry-run` to any
command to print the exact `dbt` / `gcloud` invocations without executing them
(`make dry-run` prints the whole flow).

### Seeing exactly what the script runs

Every `gcloud`, `dbt` and REST call the script makes is echoed live as a dimmed
`$ …` line (including read-only checks such as `gcloud auth list`,
`gcloud projects describe` and the `describe` existence checks) and appended with a
timestamp to `logs/kc_import.log`. Access tokens are shown as `***`.

```bash
./scripts/kc_import.sh history        # full command log of all runs, with timestamps
./scripts/kc_import.sh all --log-http # additionally print every HTTP request gcloud makes (verbose)
```

What is *not* visible this way: the calls `gcloud alpha dataplex dbt metadata-jobs create`
makes internally (BigQuery dataset lookups, the GCS upload, the metadata job). Use
`--log-http` to see those, or read the job's Cloud Logging link printed by `status`.

What `generate` does, and why, in that order:

1. `dbt seed` – demo-only, makes the `sources` tables exist (and recent) so
   metadata-based freshness has something to measure. Also the first command
   that opens a BigQuery connection, so auth problems surface early. Skip with `--no-seed`.
2. `dbt source freshness` → `target/sources.json`
3. `dbt build` → `target/run_results.json` (test verdicts). A non-zero exit from
   failing tests does **not** stop the flow – the verdicts are meant to be imported.
   *Runtime* errors (table not found, permissions, contract violations) do stop it
   before the import, because downstream nodes were skipped; `--force` overrides.
4. `dbt docs generate --no-compile` → `target/catalog.json` without clobbering
   `run_results.json`. On dbt Core 2.x / Fusion the script runs
   `dbt parse --write-catalog` instead.

The import command the script issues is:

```bash
gcloud alpha dataplex dbt metadata-jobs create dbt-bq-demo-<timestamp> \
  --project="$KC_PROJECT_ID" --location="$KC_LOCATION" \
  --artifacts-path=./target --entry-group="$KC_ENTRY_GROUP" \
  --storage-uri="gs://$KC_STAGING_BUCKET/$KC_STAGING_PREFIX/" \
  [--aspects-only] [--validate-only] [--async] [--skip-bigquery-link]
```

### Re-running

* **Full sync** (default) – first import, or whenever resources / descriptions /
  `ref()` / `source()` / tests change (entry links are only produced here).
* **Routine refresh** – `scripts/kc_import.sh import --aspects-only`
  (or `make import-aspects`) after regular `dbt build` runs: refreshes schema,
  test results and freshness without creating/deleting entries.

> [!NOTE]
> In this demo `dbt seed` (and therefore `dbt build`) reloads the `sources`
> tables by dropping and recreating them. Knowledge Catalog then deletes and
> recreates their BigQuery entries, which cascade-deletes the two
> `seed → BigQuery table` entry links. Only a **full** import recreates them
> (observed as `entry links: 2 created` on a re-run); `--aspects-only` does not.
> Externally loaded sources are not affected because their tables are never dropped.

### IAM summary (from the docs)

| Who                                                   | Role                                                                          |
|-------------------------------------------------------|-------------------------------------------------------------------------------|
| caller (you / CI service account)                     | `roles/dataplex.metadataJobOwner`, `roles/dataplex.entryGroupOwner` on `KC_PROJECT_ID` |
| caller                                                | `roles/storage.objectCreator` on the staging bucket                           |
| caller (for dbt → BigQuery links)                     | `roles/dataplex.entryOwner` on the project holding the BigQuery tables        |
| Knowledge Catalog service agent `service-<PROJECT_NUMBER>@gcp-sa-dataplex.iam.gserviceaccount.com` | `roles/storage.objectViewer` on the staging bucket |
| anyone browsing                                       | `roles/dataplex.catalogViewer`                                                |

`kc_import.sh setup` handles the service agent; `kc_import.sh iam` handles the caller.

### Viewing the result

* Console → Knowledge Catalog → **Search**, filter *System = Imported Context → dbt*,
  or query `system=DBT AND type=dbt-model`.
* Entry links: dbt `ref()`/`source()` dependencies, test → model, and
  model → physical BigQuery table (`reference`), plus the `schema-join` from the
  relationships test.

> In dbt's graph a **seed** and a **source** are distinct nodes, so lineage
> starts at `source.dbt_bq_demo.sources.customers`, not at the seed – exactly
> as it would in production where an external pipeline populates the `sources`
> dataset. The seeds are still imported as `dbt-seed` entries.

## Exploring the import (verified commands)

```bash
KC=<KC_PROJECT_ID>; DATA=<DBT_GCP_PROJECT>; LOC=us-central1; EG=dbt-metadata-ingestion
AUTH="Authorization: Bearer $(gcloud auth print-access-token)"

gcloud dataplex metadata-jobs list --location=$LOC --project=$KC
gcloud dataplex entries list --entry-group=$EG --location=$LOC --project=$KC --format='value(name.basename())'

# --view=ALL: FULL returns only *required* aspects with data (schema / contracts show as {})
gcloud dataplex entries lookup model_dbt_bq_demo_raw_customers --entry-group=$EG --location=$LOC --project=$KC --view=ALL

# search needs an explicit scope for projects outside an organization
gcloud dataplex entries search 'system=DBT AND type=dbt-model' --project=$KC   --scope=projects/$KC
gcloud dataplex entries search 'system=BIGQUERY'               --project=$DATA --scope=projects/$DATA

# ---- entry links -------------------------------------------------------------
# `reference` links are *dependency* arrows: SOURCE = the entry that depends on /
# uses / materializes-to something, TARGET = the thing referred to (same direction
# as dbt's depends_on, i.e. the opposite of data flow). Always attribute the lookup
# to the catalog project ($KC): the links are stored there and the project in the
# URL only sets billing/quota/IAM - the `entry` parameter decides what is returned.
REF=projects/dataplex-types/locations/global/entryLinkTypes/reference
JOIN=projects/dataplex-types/locations/global/entryLinkTypes/schema-join
BQ_ENTRY="projects/$DATA/locations/$LOC/entryGroups/@bigquery/entries/bigquery.googleapis.com/projects/$DATA/datasets/raw/tables/customers"
DBT_ENTRY="projects/$KC/locations/$LOC/entryGroups/$EG/entries/model_dbt_bq_demo_raw_customers"
L() { curl -s -G -H "$AUTH" "https://dataplex.googleapis.com/v1/projects/$KC/locations/$LOC:lookupEntryLinks" \
       --data-urlencode "entry=$1" --data-urlencode "entryMode=$2" --data-urlencode "entryLinkTypes=$3" \
       | jq -r '.entryLinks[]? | (.name|split("/")[-1]) + ":  " + ([.entryReferences[] | "\(.type // "UNDIRECTED") \(.name|split("/entries/")[-1]|sub("bigquery.googleapis.com/projects/[^/]+/datasets/";"bq:"))"] | join("   "))'; }

# 1. physical -> logical: which dbt entry materializes / references this table?
L "$BQ_ENTRY" TARGET "$REF"
#    reference-5f9aae14631a8624:  SOURCE model_dbt_bq_demo_raw_customers   TARGET bq:raw/tables/customers

# 2. what does this physical table reference? (nothing from dbt: tables are never the
#    referrer and dbt *sources* get no links - a hit here would come from another producer)
L "$BQ_ENTRY" SOURCE "$REF"
#    (empty)

# 3. logical -> physical + upstream: what does this model depend on / materialize to?
L "$DBT_ENTRY" SOURCE "$REF"
#    reference-6eb902998615c553:  SOURCE model_dbt_bq_demo_raw_customers   TARGET model_dbt_bq_demo_lnd_customers
#    reference-5f9aae14631a8624:  SOURCE model_dbt_bq_demo_raw_customers   TARGET bq:raw/tables/customers

# 4. who depends on this model? (downstream models and the tests that test it)
L "$DBT_ENTRY" TARGET "$REF"
#    4 links, SOURCE = test_dbt_bq_demo_{unique,not_null,accepted_values,relationships}_raw_customers...
#    (for lnd_customers the same query also returns raw_customers as a downstream model)

# 5. joins: `schema-join` links are undirected -> ENTRY_MODE_UNSPECIFIED; columns are in the link's aspect
L "$DBT_ENTRY" ENTRY_MODE_UNSPECIFIED "$JOIN"
#    schema-join-4bad85b383003a5c:  UNDIRECTED model_dbt_bq_demo_raw_customers   UNDIRECTED model_dbt_bq_demo_raw_sales
curl -s -G -H "$AUTH" "https://dataplex.googleapis.com/v1/projects/$KC/locations/$LOC:lookupEntryLinks" \
  --data-urlencode "entry=$DBT_ENTRY" --data-urlencode "entryMode=ENTRY_MODE_UNSPECIFIED" --data-urlencode "entryLinkTypes=$JOIN" \
  | jq '.entryLinks[].aspects[].data.joins'
#    raw.sales [customer_id] -> raw.customers [customer_id], type FOREIGN_KEY
```

Reading `reference` links as lineage: walk them backwards — `TARGET` mode lists downstream
consumers, `SOURCE` mode lists upstream inputs (plus the physical table, recognisable by its
`@bigquery` entry group). The BigQuery-native Data Lineage API arrows point the other way
(data flow, `landing.customers -> raw.customers`).

Stored aspect keys use project numbers (`655216118709.global.schema` = `dataplex-types`,
`772686358158.global.dbt-model` = `dataplex-connector-types`).

## Two kinds of lineage

| | Knowledge Catalog entry links (dbt import) | BigQuery-native lineage (Data Lineage API) |
|---|---|---|
| Produced by | `kc_import.sh import` from `manifest.json` | BigQuery itself, for every CTAS / INSERT / MERGE / load job, once `datalineage.googleapis.com` is enabled in the BigQuery project |
| Granularity | logical dbt nodes: source → model → model, test → model, model → physical table, FK schema-join | physical table → table per job run (process / run / lineage event) |
| Lives in | `KC_PROJECT_ID` entry group | `DBT_GCP_PROJECT`, location of the datasets |
| View | `kc_import.sh links` (table → dbt entries), `lookupEntryLinks`, catalog entry pages | BigQuery console → table → **Lineage** tab; `kc_import.sh lineage` |

`setup` enables the Data Lineage API (opt out with `ENABLE_DATA_LINEAGE=false`).
BigQuery only records lineage for jobs that run **after** the API is enabled, so
run `kc_import.sh generate` (or `dbt build`) again, wait a few minutes, then:

```bash
./scripts/kc_import.sh lineage                                   # six demo tables
./scripts/kc_import.sh lineage bigquery:<DBT_GCP_PROJECT>.raw.customers
```

Expected: `sources.* → landing.*` and `landing.* → raw.*` links (the seed load
jobs have no table source, so `sources.*` have no upstream). Links are searched once
(the API returns every link you may see, whichever project is in the URL); lineage
*processes* are per project, so the command lists them for both the BigQuery project
(BigQuery's own jobs) and the catalog project. In this setup the catalog project has
none: the dbt import creates **entry links only**, no Data Lineage events, so the
model ↔ table relationship is visible through `links` / `lookupEntryLinks`, not in
any lineage graph. Lineage is a
billable Dataplex feature; at this volume the cost is negligible.

## Adding the next layers

1. Add models under `models/curated/` (then `models/conformed/`).
2. Uncomment the matching `curated:` / `conformed:` block in `dbt_project.yml`
   so they land in their own datasets.
3. Run a **full** import afterwards (new entries).

## Troubleshooting

| Symptom                                                   | Fix                                                                                   |
|-----------------------------------------------------------|---------------------------------------------------------------------------------------|
| `Env var required but not provided: 'DBT_GCP_PROJECT'`    | `cp .env.example .env`, fill it in, `set -a; source .env; set +a` (or use `make`)     |
| `dbt seed` fails with 403 / 404                           | `gcloud auth application-default login`; check `DBT_GCP_PROJECT` and BigQuery access  |
| `Not found: Table …sources.<x>` inside `dbt build`, rest skipped | seeds and source readers ran concurrently – keep the `-- depends_on` hints in the landing models and no tests on the sources (see above) |
| `kc_import.sh lineage` shows no links                     | the API was enabled after the last build, or it is still indexing: re-run `generate`/`dbt build`, wait a few minutes |
| `kc_import.sh` stops with *dbt build had runtime errors*  | intended: a half-built DAG is not imported. Fix the cause (`logs/dbt.log`), re-run; `--force` overrides |
| contract error on a raw model                             | keep `data_type`s in `_raw__models.yml` in sync with the SQL, or set `contract.enforced: false` |
| `gcloud: command not found: alpha dataplex dbt`           | `gcloud components update` (needs ≥ 586) and `gcloud components install alpha`        |
| `gcloud has no credentials for …` / `ADC belong to …`     | you are logged in as a different user: open Cloud Shell as `GCLOUD_ACCOUNT`, or locally `gcloud auth login ACCOUNT` + `gcloud auth application-default login` |
| `entry group not found`                                   | run `scripts/kc_import.sh setup` in the same `KC_PROJECT_ID` / `KC_LOCATION`          |
| links to BigQuery tables missing                          | datasets must be in `KC_LOCATION`; caller needs `bigquery.datasets.get`; or set `KC_SKIP_BIGQUERY_LINK=true` |
| `gcloud dataplex entries search …` returns nothing but `entries list` shows entries | search defaults to *organization* scope; for projects outside an organization add `--scope=projects/<KC_PROJECT_ID>` (the script's `search` does this). Otherwise wait for the search index to catch up |
