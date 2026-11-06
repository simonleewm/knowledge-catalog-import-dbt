# Convenience targets for dbt_bq_demo. All targets auto-load ./.env (if present).
#
#   make install        install pinned dbt into ../venv (creates it if missing)
#   make parse          offline validation (no BigQuery connection)
#   make seed|build|test|freshness|docs
#   make check|setup|iam|generate|import|all|status|search   -> scripts/kc_import.sh
#
# Override the interpreter location with VENV=/path/to/venv.

SHELL := bash
.ONESHELL:
.DEFAULT_GOAL := help

REPO_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
# Prefer the shared ../venv when it already has dbt, otherwise ./.venv
# (created by scripts/bootstrap.sh - the Cloud Shell default).
VENV      ?= $(if $(wildcard $(REPO_ROOT)/../venv/bin/dbt),$(abspath $(REPO_ROOT)/../venv),$(REPO_ROOT)/.venv)
PYTHON    := $(VENV)/bin/python
DBT       := $(VENV)/bin/dbt
KC        := $(REPO_ROOT)/scripts/kc_import.sh

# Load .env into the environment of every recipe (shell env still wins).
ifneq (,$(wildcard $(REPO_ROOT)/.env))
  include $(REPO_ROOT)/.env
  export
endif
export DBT_PROFILES_DIR ?= $(REPO_ROOT)
export DBT_BIN := $(DBT)

.PHONY: help bootstrap install parse compile ls seed build test freshness docs clean \
        check setup iam generate import import-aspects status search lineage links history all dry-run

help: ## show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(firstword $(MAKEFILE_LIST)) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

bootstrap: ## Cloud Shell / first run: create venv, install dbt, run checks
	VENV_DIR="$(VENV)" "$(REPO_ROOT)/scripts/bootstrap.sh"

install: ## create ../venv if needed and install pinned dbt packages
	@test -x "$(PYTHON)" || python3 -m venv "$(VENV)"
	"$(PYTHON)" -m pip install --quiet --upgrade pip
	"$(PYTHON)" -m pip install --quiet -r "$(REPO_ROOT)/requirements.txt"
	"$(DBT)" --version

parse: ## validate project offline (no warehouse connection)
	cd "$(REPO_ROOT)" && "$(DBT)" parse

compile: ## compile models to target/compiled
	cd "$(REPO_ROOT)" && "$(DBT)" compile

ls: ## list resources with their BigQuery relation names
	cd "$(REPO_ROOT)" && "$(DBT)" ls --resource-type model --resource-type seed --resource-type source --output json --output-keys name resource_type database schema alias

seed: ## load demo source tables into the `sources` dataset
	cd "$(REPO_ROOT)" && "$(DBT)" seed

build: ## dbt build (seeds + models + tests)
	cd "$(REPO_ROOT)" && "$(DBT)" build

test: ## dbt test
	cd "$(REPO_ROOT)" && "$(DBT)" test

freshness: ## dbt source freshness
	cd "$(REPO_ROOT)" && "$(DBT)" source freshness

docs: ## generate + serve dbt docs locally
	cd "$(REPO_ROOT)" && "$(DBT)" docs generate && "$(DBT)" docs serve

clean: ## remove target/, logs/, dbt_packages/
	cd "$(REPO_ROOT)" && "$(DBT)" clean

check: ## verify tooling and placeholders
	"$(KC)" check

setup: ## one-time Knowledge Catalog setup (API, entry group, bucket, IAM for service agent)
	"$(KC)" setup

iam: ## grant import roles to KC_PRINCIPAL
	"$(KC)" iam

generate: ## run dbt and produce the four artifact files
	"$(KC)" generate

import: ## full-sync import of ./target into Knowledge Catalog
	"$(KC)" import

import-aspects: ## routine refresh (aspects only)
	"$(KC)" import --aspects-only

status: ## describe the last metadata job (or JOB_ID=...)
	"$(KC)" status $(if $(JOB_ID),--job-id $(JOB_ID),)

search: ## search Knowledge Catalog for dbt entries
	"$(KC)" search

lineage: ## BigQuery-native lineage of the demo tables (Data Lineage API)
	"$(KC)" lineage

links: ## which dbt entries claim each physical table (Knowledge Catalog entry links)
	"$(KC)" links

history: ## every gcloud/dbt/REST command the script has executed (logs/kc_import.log)
	"$(KC)" history

all: ## generate + import
	"$(KC)" all

dry-run: ## print every command the full flow would run, without executing
	"$(KC)" setup --dry-run
	"$(KC)" all --dry-run
