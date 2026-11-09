#!/bin/bash
# Healthy once ASE accepts logins and testdb is online.
# shellcheck disable=SC1091
source /opt/sap/SYBASE.sh >/dev/null 2>&1
isql -Usa -P"$SA_PASSWORD" -S"$ASE_SERVER_NAME" -b <<'EOF' | grep -q ready
use testdb
go
select 'ready'
go
EOF
