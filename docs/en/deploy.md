# Deploy and CI/CD

[← README](../../README.md)

## Deploy by hand

After merging into `main`:

```bash
make deploy BASE=<commit before the merge>
```

It:
1. Takes the packages, functions and procedures changed between `BASE` and the current commit.
2. Checks prod still matches git. If someone changed it outside git, it **stops without compiling anything** and prints the difference.
3. Compiles package specs, then functions and procedures, then package bodies.
4. Verifies prod now matches git, and fails if it does not.

A deploy that failed half way can be run again safely: what already reached prod is not seen as an outside change.

To roll back, revert the commit and deploy again.

## Automatic deploys with GitHub Actions

1. **Settings → Secrets and variables → Actions**
   - **Secrets**: `PROD_USER`, `PROD_PASSWORD`, `PROD_CONNECT`. With TNS, use `PROD_TNS` and `TNSNAMES_ORA` (the file content) instead of `PROD_CONNECT`.
   - **Variables**: `APP_SCHEMA`, `ORACLE_VERSION`, `PLSQL_DEPLOY_ENABLED` = `true`.
2. **Self-hosted runner** on a machine that can reach prod and has Docker, git and make (Settings → Actions → Runners → New self-hosted runner), with the label `plsql-deploy`.
3. **Protect `main`** and require the `pr-check` status.

Then:
- **Every Pull Request** (`pr-check`): GitHub starts a throwaway Oracle, builds the schema from `ci/schema/` and compiles all the code. No prod credentials are used.
- **Every merge** (`deploy`): the runner deploys what changed since the last successful deploy, then tags that commit `plsql-deployed`. Cancelled or failed deploys are picked up by the next one. Do not delete the tag by hand.

The `self-test` workflow only tests plsql-agent itself. In your repository it is always *skipped*; you can delete `.github/workflows/self-test.yml`.

> ⚠️ Your repository holds real code, so keep it **private**. Never attach a self-hosted runner to a public repository: strangers could open Pull Requests that run code on it.

## When someone changes prod directly

- `make pull PKG=<name>` commits the prod version as `sync(prod): <name> drift from prod`, so their change is never lost.
- Deploy stops with `prod was changed outside git`. Fix: `make pull PKG=<name>`, re-apply your change on top, open a new Pull Request.
