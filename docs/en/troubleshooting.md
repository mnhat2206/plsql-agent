# Troubleshooting

[← README](../../README.md)

Start with `make check`: it tests every step of the connection and says what to fix.

**DBeaver says `ORA-01017: invalid credential`**
Run `make info` for the exact details. The username is the value of `APP_SCHEMA`, the password is `LOCAL_SYS_PASSWORD`. That user exists only after the first successful `make sync`.

**`make sync` cannot reach prod (`cannot reach prod`)**
- The tool connects **from inside Docker**, so `localhost` in `PROD_CONNECT` is the container itself, not your machine.
- Prod on your machine, behind an SSH tunnel, or in another Docker container: use `host.docker.internal:<port>/<service>`.
- Prod inside a company network: connect the VPN first.

**`make sync` prints `Data Pump ... did not complete`**
That is fine: with `SYNC_MODE=auto` it falls back to plain copying. Set `SYNC_MODE=copy` to skip the Data Pump attempt.

**A table has rows on prod but is empty locally**
It is not part of `USED`, usually because the code uses it through dynamic SQL. Add it to `config/data-scope.conf`, e.g. `MY_TABLE LIMIT 5000`.

**A container stops (`exited`) or SQLcl is `Killed`**
Docker ran out of memory. Stop other databases (`make down`) or give Docker more memory (Docker Desktop → Settings → Resources).

**Deploy says `prod was changed outside git`**
Someone changed prod directly. See [Deploy → When someone changes prod directly](deploy.md#when-someone-changes-prod-directly).

**`make compile` says `only one unit allowed` or `must start with CREATE OR REPLACE`**
Each file must hold exactly one `CREATE OR REPLACE PACKAGE [BODY] / FUNCTION / PROCEDURE <file name>` and end with a single `/` line. Only `--` comments may come before it.

**`make up` says port 1530 is already in use**
Set `LOCAL_PORT` to another port in `.env`, e.g. `LOCAL_PORT=1531`.
