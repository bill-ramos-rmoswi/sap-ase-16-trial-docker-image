# Helpers for Dockerfile RUN steps that need the server up at build time.
# Source it; expects SA_PASSWORD in the environment (a build arg).
# shellcheck shell=bash disable=SC1091
source /opt/sap/SYBASE.sh >/dev/null 2>&1

isql_sa() {
    isql -Usa -P"${SA_PASSWORD}" -SASE "$@"
}

start_ase() {
    ( /opt/sap/ASE-16_1/install/RUN_ASE >/dev/null 2>&1 & )
    for _ in $(seq 1 90); do
        echo 'select 1' | isql_sa -b >/dev/null 2>&1 && return 0
        sleep 2
    done
    echo "ASE didn't start" >&2
    tail -n 40 /opt/sap/ASE-16_1/install/ASE.log >&2
    return 1
}

run_sql() {
    isql_sa -b -e -w 200 -i "$1"
}

stop_ase() {
    printf 'shutdown\ngo\n' | isql_sa >/dev/null 2>&1 || true
    for _ in $(seq 1 60); do
        pgrep dataserver >/dev/null || return 0
        sleep 1
    done
    echo "ASE didn't shut down" >&2
    return 1
}
