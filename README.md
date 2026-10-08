<div align="center">
  <h1>plsql-agent</h1>
  <p>Let an AI agent change Oracle PL/SQL safely: code in git, tests on real data, guarded deploys.</p>

  <a href="https://github.com/mnhat2206/plsql-agent/actions/workflows/self-test.yml"><img src="https://github.com/mnhat2206/plsql-agent/actions/workflows/self-test.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT"></a>
  <img src="https://img.shields.io/badge/Oracle-11g%20%E2%80%93%2023ai-F80000" alt="Oracle 11g – 23ai">
  <img src="https://img.shields.io/badge/works%20with-Claude%20Code-D97757" alt="Claude Code">

  <p>
    <a href="docs/en/commands.md">Docs</a> •
    <a href="README.vi.md">Tiếng Việt</a> •
    <a href="https://github.com/mnhat2206/plsql-agent/issues">Issues</a>
  </p>
</div>

## What is plsql-agent?

A workspace where an AI agent such as [Claude Code](https://claude.com/claude-code) changes PL/SQL packages, functions and procedures **without ever writing to prod**.

You describe the change. The agent pulls the latest code from prod, edits it, compiles it and tests it on an Oracle database on your machine that holds a copy of prod data, then opens a Pull Request. Prod changes only when you merge, and the deploy stops if anyone changed prod outside git.

> **You:** In `pkg_customer`, make `get_customer_name` return 'N/A' when the customer does not exist. Show me a test run.
>
> **Claude:** Pulled `pkg_customer`, changed the `NO_DATA_FOUND` branch, compile OK. On the local DB: `get_customer_name(42)` → `Customer 42`, `get_customer_name(-1)` → `N/A`. Opened PR #12.

No AI needed either: everything the agent does is a `make` command you can run yourself.

## Features

- Packages, functions and procedures as files in git
- A local database with prod's structure and a chosen slice of its data
- Parent rows follow automatically, so foreign keys stay valid
- The agent only reads prod through the provided commands, never writes to it
- Detects changes made directly on prod
- Deploys only what changed, checked before and after
- CI/CD with GitHub Actions
- Oracle 11g to 23ai

## Install

You need [Docker Desktop](https://www.docker.com/products/docker-desktop/), [git](https://git-scm.com/downloads), make, and [Claude Code](https://claude.com/claude-code) to work with an AI agent.

Click **Use this template** at the top of this page to create your own **private** repository (your real PL/SQL code will live there), then clone it:

```bash
git clone https://github.com/<you>/<your-repo>.git
cd <your-repo>
cp .env.example .env
```

Fill in your prod in `.env`:

```bash
PROD_CONNECT=10.0.0.5:1521/ORCLPDB1   # host:port/service
PROD_USER=ecom_dev
PROD_PASSWORD="my-password"
APP_SCHEMA=ECOM_DEV                   # schema that owns the code
ORACLE_VERSION=19
```

Check `.env` and the connections. Whatever is wrong, it tells you what to fix:

```bash
make check
```

## Get started

```bash
make up          # start the local database
make sync        # copy structure and data from prod
make pull-all    # put packages, functions and procedures in git
```

By default only the tables your code uses get data. Preview with `make sync-plan`, change it in [`config/data-scope.conf`](docs/en/configuration.md#data-rules-configdata-scopeconf).

Then open the agent in the repository:

```bash
claude
```

[`CLAUDE.md`](CLAUDE.md) gives the agent the workflow and its limits: no SQL on prod, tests only on the local database, always compile before finishing, open a Pull Request instead of changing `main`.

## Without AI

```bash
make pull PKG=pkg_customer      # latest code from prod
# edit src/packages/pkg_customer.pkb
make compile PKG=pkg_customer   # errors as file:line:col
make sql                        # try it on the local database
```

`make info` prints connection details for DBeaver or PL/SQL Developer. `make peek TABLE=customers` shows a prod table (read only).

## Deploy

```bash
make deploy BASE=<commit before the merge>
```

Or let GitHub Actions deploy after every merge. See [setting up CI/CD](docs/en/deploy.md).

## Docs

- [Commands](docs/en/commands.md)
- [Configuration](docs/en/configuration.md)
- [Deploy and CI/CD](docs/en/deploy.md)
- [Features in detail](docs/en/features.md)
- [Troubleshooting](docs/en/troubleshooting.md)

## License

[MIT](LICENSE)
