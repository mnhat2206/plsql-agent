# Configuration

[← README](../../README.md)

## `.env`

| Variable | Required | Default | Meaning |
|---|---|---|---|
| `PROD_CONNECT` | yes* | | prod `host:port/service` |
| `PROD_TNS`, `TNS_ADMIN` | yes* | | A TNS alias instead of `PROD_CONNECT`; `TNS_ADMIN` is the folder with `tnsnames.ora` (absolute path) |
| `PROD_USER`, `PROD_PASSWORD` | yes | | Prod account. Quote a password with spaces or `#` as `"..."`; it cannot contain `"` |
| `APP_SCHEMA` | yes | | Schema that owns the code (packages, functions, procedures) |
| `ORACLE_VERSION` | | `23` | Prod version: `11`, `12`, `18`, `19`, `21`, `23` |
| `LOCAL_SYS_PASSWORD` | yes | | Local database password (for `SYSTEM` and `APP_SCHEMA`) |
| `LOCAL_PORT` | | `1530` | Local database port |
| `LOCAL_DB_MEMORY_MB` | | `1024` | Memory for the local database (at least 768) |
| `DATA_SCOPE` | | `config/data-scope.conf` | Data rules file |
| `SYNC_MODE` | | `auto` | `auto`: Data Pump, falling back to plain copying. `datapump` or `copy`: one method only |
| `LOCAL_IMAGE`, `SQLCL_VERSION` | | | Another local database image, or a pinned SQLcl version |

\* One of: `PROD_CONNECT`, or `PROD_TNS` + `TNS_ADMIN`.

## Data rules (`config/data-scope.conf`)

The structure of every table is always created. This file only decides **how many rows** are copied. Each line is `<TABLE> <rule>`:

| Rule | Meaning |
|---|---|
| `FULL` | All rows |
| `NONE` | No rows |
| `LIMIT 5000` | At most 5000 rows |
| `SAMPLE 10` | About 10% of the rows |
| `WHERE created_at >= sysdate - 30` | Rows matching the condition (the rest of the line) |

Two special names:
- `USED <rule>`: tables your code uses, found through `ALL_DEPENDENCIES`, also through views and functions.
- `DEFAULT <rule>`: every other table.

A rule for a specific table always wins. With any rule, **referenced parent rows are copied too**, through every level, so foreign keys stay valid and joins work.

The default:

```
DEFAULT   NONE
USED      LIMIT 5000
```

Use `DEFAULT FULL` to copy everything. Tables used only through dynamic SQL (`EXECUTE IMMEDIATE`) are not found by `USED`: list them, e.g. `MY_TABLE LIMIT 5000`. Preview the result with `make sync-plan`.

The local database holds about 11 GB of data (an Oracle Free/XE limit).

## Oracle versions

`ORACLE_VERSION` picks the local database image:

| Prod | Local database | Notes |
|---|---|---|
| 19c, 23ai | Oracle Free 23 | Recommended; runs well on Apple Silicon |
| 12.2, 18c, 21c | Oracle XE 21 | Intel/AMD only; emulated (slow) on Apple Silicon |
| 11.2 | Oracle XE 18 | Best effort; you may need to pin an older `SQLCL_VERSION` |

## Prod user privileges

Logging in and owning `APP_SCHEMA` is enough. A user that does not own the schema also needs:
- `DATAPUMP_EXP_FULL_DATABASE` to sync;
- `CREATE ANY PROCEDURE` and `ALTER ANY PROCEDURE` to deploy.

Use a user with the least privileges you can.
