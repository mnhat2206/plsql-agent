# Commands

[← README](../../README.md)

Run `make` for a short list. Every command reads its settings from `.env`.

## Checking the setup

| Command | What it does |
|---|---|
| `make check` | Checks `.env`, Docker, the prod login, the schema, the Oracle version, and whether the local database can reach prod. Explains what to fix (wrong password, wrong service, `localhost`...). Read only. |
| `make peek TABLE=customers` | Shows a prod table, read only: row count and the first 10 rows, plus the local row count when the local database has the table. Add `WHERE="id < 100"` or `ROWS=20` if needed. |

## Local database

| Command | What it does |
|---|---|
| `make up` | Starts the local database. The first run downloads images and creates it (a few minutes), later runs take seconds. It is limited to about 1 GB of memory (`LOCAL_DB_MEMORY_MB`). |
| `make down` | Stops the local database. Data is kept. |
| `make reset-local` | **Deletes** the local database and its data. |
| `make info` | Prints how to connect: host, port, service, user, password, a JDBC URL (DBeaver, SQL Developer), an EZConnect string (PL/SQL Developer, Toad, SQL*Plus) and a `tnsnames.ora` entry. |
| `make sql` | Opens SQLcl on the local database as `APP_SCHEMA`. |
| `make sql FILE=try.sql` | Runs a SQL file on the local database. Also reads SQL from stdin: `scripts/sql.sh < try.sql`. |

## Copying from prod

| Command | What it does |
|---|---|
| `make sync-plan` | Reads prod and prints, per table, the rule that applies, the rows on prod and the rows that would be copied. Changes nothing. |
| `make sync ONLY="customers orders"` | Builds only these tables and their parent tables, with data per `data-scope.conf`. Skips views, code and triggers, and leaves `ci/schema/` alone. Good for a first try. |
| `make sync` | Drops the local schema and rebuilds it from prod: every object, data per `config/data-scope.conf`, the parent rows it needs, foreign keys. Then exports the structure to `ci/schema/` (commit it; the PR check uses it). |
| `make ci-schema` | Rebuilds the local schema from `ci/schema/` only: structure without data, no prod needed. The PR check uses it. |
| `make schema-ddl` | Exports the local schema structure to `ci/schema/` again. `make sync` already does this. |

## Packages, functions, procedures

| Command | What it does |
|---|---|
| `make pull PKG=pkg_a` | Fetches the latest source of a package, function or procedure from prod into `src/packages/`, `src/functions/` or `src/procedures/`. Commits it as `sync(prod): ...` when it differs from git. Refuses when the files have uncommitted changes. |
| `make pull PKG="pkg_a pkg_b"` | The same for several names, in one commit. |
| `make pull-all` | Fetches every package, function and procedure of the schema with one query, in one commit. |
| `make compile` | Compiles everything in `src/` into the local database: package specs, then functions and procedures, then package bodies. |
| `make compile PKG=pkg_a` | Compiles one name (or several: `PKG="a b"`). Errors look like `src/packages/pkg_a.pkb:35:5: PLS-00103 ...`. Each file must hold exactly one `CREATE OR REPLACE PACKAGE [BODY] / FUNCTION / PROCEDURE <file name>` and end with `/`. |
| `make drift PKG=pkg_a` | Compares the object on prod with git (`HEAD` by default, or `REF=<commit>`). |

## Deploy

| Command | What it does |
|---|---|
| `make deploy BASE=<sha>` | Compiles on prod the packages, functions and procedures changed between `BASE` and the current commit. See [Deploy](deploy.md). |

## Tests

| Command | What it does |
|---|---|
| `make test` | Unit tests (in Docker, about a minute). |
| `make lint` | shellcheck for the scripts, actionlint for the workflows. |
| `make test-integration` | Runs the whole workflow against a throwaway database acting as prod (about 12 minutes, needs about 4 GB of free memory). |
