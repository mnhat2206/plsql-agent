# Features

[← README](../../README.md)

## Code in git
- Packages: `src/packages/<name>.pks` (spec) and `.pkb` (body). Functions: `src/functions/<name>.fnc`. Procedures: `src/procedures/<name>.prc`.
- Pull one, several or all objects with a single query. Thousands of objects take a few tens of seconds and land in one commit.
- Each file holds exactly one object named like the file. Files with any other statement are rejected, because deploy runs the whole file on prod.

## A local database with real data
- Rebuilds prod's whole schema structure: tables, views, sequences, types, functions, procedures, packages, triggers, indexes, foreign keys.
- Choose the data per table: all, none, n rows, a percentage, or a `WHERE` condition.
- `USED`: finds the tables your code actually uses, also through views and functions, so only those get data.
- **Parent rows follow**: when only part of a child table is copied (say 5000 `orders`), the referenced parent rows are copied too (their `customers`, then the parents of `customers`...). Foreign keys are created VALIDATED.
- `make sync-plan` previews how many rows will be copied.
- Two ways to copy data:
  - Oracle Data Pump (fast);
  - plain `INSERT ... SELECT`, used automatically when Data Pump cannot run (e.g. Oracle *lite* images).
- Identity columns continue after the highest copied value, so new inserts do not clash.
- The local database is limited to about 1.3 GB of memory.

## Safe deploys
- Deploys only what changed.
- Checks before deploying (outside changes) and verifies afterwards.
- A deploy that failed half way can be re-run safely. Cancelled or skipped deploys are picked up by the next one.
- Roll back by reverting the commit.

## Outside changes
- `make pull` commits the prod version when it differs from git.
- `make drift` compares prod with git at any time.

## CI/CD
- Every Pull Request: compile all the code on a throwaway Oracle, without prod credentials.
- Every merge: deploy through a self-hosted runner.

## Security
- Passwords live only in `.env` or GitHub Secrets. They reach SQLcl on stdin, never on a command line, and are masked as `***` in error output.
- The local database holds real data, so it listens on `127.0.0.1` only: other machines on your network cannot reach it.
- On prod the tool only runs `SELECT`, `CREATE OR REPLACE PACKAGE [BODY] / FUNCTION / PROCEDURE` and `ALTER ... COMPILE`. The database link used by sync is created in the local database and dropped right after. Prod database links and jobs are never copied.
- Schema drops only run against this repository's local database container, even if the settings point elsewhere by mistake.

## Oracle versions
11.2 to 23ai. See [Configuration → Oracle versions](configuration.md#oracle-versions).
