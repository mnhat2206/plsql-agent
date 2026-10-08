#!/bin/bash
# Seed schema APP of the integration-test prod (runs once, on first start).
sqlplus -s -L "APP/app@//localhost:1521/${FAKEPROD_PDB}" @/container-entrypoint-initdb.d/seed/seed.sql
