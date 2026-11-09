#!/usr/bin/env bash
# Builds the SAP ASE trial image, smoke-tests it, and tags it with the
# version the server reports in `select @@version`.
#
#   ./scripts/build.sh            build, test, tag
#   ./scripts/build.sh --push     also push to GHCR (run `docker login ghcr.io` first)
#   ./scripts/build.sh --no-cache rerun the SAP installer (new SySAM grace period)
#
# Environment overrides: IMAGE (default ghcr.io/bill-ramos-rmoswi/sap-ase),
# SA_PASSWORD (default Password1).
set -euo pipefail

cd "$(dirname "$0")/.."

IMAGE="${IMAGE:-ghcr.io/bill-ramos-rmoswi/sap-ase}"
SA_PASSWORD="${SA_PASSWORD:-Password1}"
PUSH=false
BUILD_FLAGS=()
for arg in "$@"; do
    case "$arg" in
        --push) PUSH=true ;;
        # Reruns the SAP installer, which starts a new SySAM grace period
        --no-cache) BUILD_FLAGS+=(--no-cache) ;;
        *) echo "Unknown option: $arg (use --push and/or --no-cache)" >&2; exit 2 ;;
    esac
done

TGZ=Trial-Downloads/ASE_Suite.linuxamd64.tgz
if [[ ! -f "$TGZ" ]]; then
    echo "Missing $TGZ. Download the Linux trial from SAP first (see README.md)." >&2
    exit 1
fi

echo "==> Building $IMAGE:build"
docker build "${BUILD_FLAGS[@]}" --platform linux/amd64 --build-arg SA_PASSWORD="$SA_PASSWORD" -t "$IMAGE:build" .

echo "==> Starting a test container"
CID=$(docker run -d "$IMAGE:build")
trap 'docker rm -f "$CID" >/dev/null 2>&1 || true' EXIT

status=starting
for _ in $(seq 1 60); do
    [[ "$(docker inspect -f '{{.State.Running}}' "$CID")" == true ]] || break
    status=$(docker inspect -f '{{.State.Health.Status}}' "$CID")
    [[ "$status" == healthy ]] && break
    sleep 2
done
if [[ "$status" != healthy ]]; then
    docker logs "$CID" | tail -n 50
    echo "Container never became healthy" >&2
    exit 1
fi

query() {
    docker exec -i "$CID" bash -c 'source /opt/sap/SYBASE.sh >/dev/null; isql -Usa -P"$SA_PASSWORD" -S"$ASE_SERVER_NAME" -b -w 999' <<<"$1"$'\ngo'
}

VERSION_STRING=$(query "set nocount on select @@version" | sed -n 's/^ *//; s/ *$//; /Adaptive Server Enterprise/p' | head -n 1)
echo "==> @@version: $VERSION_STRING"
# "Adaptive Server Enterprise/16.1 SP00 PL02/EBF 31284 SMP/..." -> 16.1-SP00-PL02
TAG=$(echo "$VERSION_STRING" | cut -d/ -f2 | tr ' ' '-')
[[ -n "$TAG" ]] || { echo "Could not parse the version" >&2; exit 1; }

echo "==> Sort order and character set"
query "exec sp_helpsort" | grep -E 'Character Set =|Sort Order =' | sed 's/ *$//' || true

echo "==> Configuration"
query "set nocount on
select name, value from master..sysconfigures
 where name in ('max memory', 'number of user connections', 'number of locks',
                'number of open objects', 'max online engines', 'procedure cache size')
select 'engines online', count(*) from master..sysengines" | sed -E 's/ *$//; s/ {2,}/: /' | grep -vE '^\s*$|^ ?-+' || true
query "exec sp_cacheconfig 'default data cache'" | grep -E '^ default data cache' | awk '{print " default data cache:", $6, $7}' || true
query "exec sp_helpdb tempdb" | grep -E '^ tempdb ' | awk '{print " tempdb", $2, $3}' || true

echo "==> License status (grace period)"
query "exec sp_lmconfig" | grep -E 'ASE_CORE|edition|license type' | sed 's/ *$//' || true
docker exec "$CID" bash -c "grep -E 'SySAM: WARNING: ASE will shutdown' /opt/sap/ASE-16_1/install/ASE.log | tail -n 1" || true

docker tag "$IMAGE:build" "$IMAGE:$TAG"
docker tag "$IMAGE:build" "$IMAGE:latest"
docker rmi "$IMAGE:build" >/dev/null
echo "==> Tagged $IMAGE:$TAG and $IMAGE:latest"
docker images "$IMAGE" --format '    {{.Repository}}:{{.Tag}}  {{.Size}}'

if $PUSH; then
    docker push "$IMAGE:$TAG"
    docker push "$IMAGE:latest"
fi
