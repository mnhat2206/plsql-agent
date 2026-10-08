# Working on PL/SQL code in this repo

Packages live in `src/packages/<name>.pks` (spec) and `<name>.pkb` (body), standalone
functions in `src/functions/<name>.fnc`, procedures in `src/procedures/<name>.prc`. Prod is
changed ONLY by the deploy workflow after a PR is merged into `main`.

## Rules

- Never connect to prod yourself and never run SQL against it. Only these commands
  read prod: `make check`, `make peek`, `make pull`, `make pull-all`, `make sync`,
  `make sync-plan`, `make drift`. Never run `make deploy`: deploying is the human's
  (or CI's) decision after review.
- Before editing a package, function or procedure, run `make pull PKG=<name>` so you start from prod's
  current source. If it creates a `sync(prod): ...` commit, someone hotfixed prod:
  keep their change.
- After editing, run `make compile PKG=<name>` and fix every `file:line:col` error.
- Try the change on the local DB (real prod data, safe to modify):
  `scripts/sql.sh <<'SQL'` ... `SQL` with queries or anonymous blocks. Show the user
  the output. Roll back data you changed unless they asked to keep it.
- Keep each file starting with `CREATE OR REPLACE` and ending with a single `/` line.
- Work on a branch, commit with a clear message, open the PR with `gh pr create`.
  Do not push to `main`.
- Never commit `.env` or print its values.

## Useful commands

| Command | Purpose |
|---------|---------|
| `make pull PKG=x` | prod source into git |
| `make compile [PKG=x]` | compile into the local DB |
| `scripts/sql.sh < file.sql` | run SQL on the local DB as the schema owner |
| `make drift PKG=x` | does prod still match git? |
| `make check` | is `.env` right and is everything reachable? |
| `make peek TABLE=x` | look at a prod table (read only) |
| `make sync ONLY="a b"` | rebuild just these tables (and their parents) locally |
| `make info` | connection details for the user's SQL client |
| `make sync` | refresh local data from prod (drops local changes) |
