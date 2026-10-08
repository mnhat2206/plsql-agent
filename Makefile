# All day-to-day commands. Run `make` for the list.
SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

PKG  ?=
REF  ?= HEAD
BASE ?=
HEAD ?=
FILE ?=
TABLE ?=
WHERE ?=
ROWS ?= 10
ONLY ?=
# Passed to scripts through the environment, never pasted into the shell command.
export PKG REF BASE HEAD FILE TABLE WHERE ROWS ONLY

.PHONY: help check peek up down reset-local sync sync-plan schema-ddl ci-schema \
        pull pull-all compile info sql drift deploy test test-integration lint

help: ## Show this list
	@awk 'BEGIN {FS = ":.*## "} /^[a-z-]+:.*## / {printf "  make %-16s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

check: ## Check .env and the connections to prod and the local DB; explains what to fix
	@scripts/check.sh

up: ## Start the local Oracle DB (builds the SQLcl image on first run)
	@scripts/local.sh up

down: ## Stop containers (data is kept)
	@scripts/local.sh down

reset-local: ## Delete the local DB container and its data
	@scripts/local.sh reset

peek: ## Look at one prod table (read only): make peek TABLE=customers [WHERE="id < 10"] [ROWS=10]
	@scripts/peek.sh "$$TABLE" "$$WHERE" "$$ROWS"

sync: ## Copy prod structure + data into the local DB [ONLY="table1 table2" for just those tables]
	@scripts/sync.sh

sync-plan: ## Preview what make sync would copy (rule and expected rows per table)
	@scripts/sync_plan.sh

schema-ddl: ## Re-export the local schema DDL into ci/schema/
	@scripts/schema_ddl.sh

ci-schema: ## Recreate the local schema from ci/schema/ (structure only)
	@scripts/ci_schema.sh

pull: ## Pull a package from prod: make pull PKG=pkg_name
	@scripts/pull.sh $$PKG

pull-all: ## Pull every package of the schema from prod
	@scripts/pull.sh --all

compile: ## Compile into the local DB: make compile [PKG="pkg_a pkg_b"]
	@scripts/compile.sh $$PKG

info: ## How to connect DBeaver / PL/SQL Developer / SQL*Plus to the local DB
	@scripts/info.sh

sql: ## SQLcl on the local DB: make sql [FILE=script.sql]
	@if [ -n "$$FILE" ]; then scripts/sql.sh "$$FILE"; else scripts/sql.sh; fi

drift: ## Compare prod with git: make drift PKG=pkg_name [REF=HEAD]
	@scripts/drift.sh "$$PKG" "$$REF"

deploy: ## Compile changed packages to prod: make deploy BASE=<sha> [HEAD=<sha>]
	@scripts/deploy.sh "$$BASE" "$${HEAD:-$$(git rev-parse HEAD)}"

test: ## Unit tests (Docker)
	@tests/unit/run.sh

test-integration: ## End-to-end test against a throwaway fake prod (Docker, ~10 min)
	@tests/integration/run.sh

lint: ## shellcheck + actionlint (Docker)
	@tests/lint.sh
