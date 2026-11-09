#!/bin/bash
# Starts SAP ASE in the foreground and shuts it down cleanly on SIGTERM,
# so `docker stop` doesn't leave the devices needing recovery.
set -eo pipefail

# SYBASE.sh appends to variables that may be unset, so it can't run under `set -u`
# shellcheck disable=SC1091
source /opt/sap/SYBASE.sh >/dev/null
set -u

RUN_FILE="$SYBASE/$SYBASE_ASE/install/RUN_${ASE_SERVER_NAME}"
ERRORLOG="$SYBASE/$SYBASE_ASE/install/${ASE_SERVER_NAME}.log"

shutdown_ase() {
    echo "entrypoint: shutting down ${ASE_SERVER_NAME}"
    # isql always reports a lost connection when the server shuts down
    isql -Usa -P"$SA_PASSWORD" -S"$ASE_SERVER_NAME" -b >/dev/null 2>&1 <<'EOF' || true
shutdown
go
EOF
    wait "$ASE_PID" || true
    exit 0
}

trap shutdown_ase TERM INT

touch "$ERRORLOG"
tail -n 0 -F "$ERRORLOG" &

"$RUN_FILE" &
ASE_PID=$!
wait "$ASE_PID"
