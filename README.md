# SAP ASE trial Docker image

A lean Docker image of **SAP Adaptive Server Enterprise (ASE)**, built from SAP's free trial download, for running database tests in GitHub Actions. It was made for [data-diff](https://github.com/bill-ramos-rmoswi/data-diff).

SAP doesn't publish an ASE container image, and its trial license doesn't allow redistribution. So this repo holds only the recipe: you download the installer yourself, build the image locally, and push it to a **private** registry that your own workflows can pull from.

| | |
| --- | --- |
| Version | 16.1 SP00 PL02 (EBF 31284), from `select @@version` |
| Base image | Rocky Linux 9 minimal, `linux/amd64` |
| Server | `ASE` on port `5000`, login `sa` / `Password1` |
| Database | `testdb` (250 MB data, 50 MB log, `trunc log on chkpt`, `select into/bulkcopy`) |
| Tuning | 4 engines, 1.5 GB max memory, 768 MB data cache, 100 connections, 200,000 locks, 1.1 GB tempdb; fits a 2 GB container ([details](#tuning)) |
| Character set / sort order | `cp850` / `bin_cp850` (binary, sort order ID 50) |
| Page size | 4k (the installer default) |
| Installed features | ASE server and Open Client (`isql`) only |
| Image size | about 2.5 GB unpacked (mostly zero-filled devices), about 205 MB compressed to pull; healthy about 6 s after start |
| Registry | `ghcr.io/bill-ramos-rmoswi/sap-ase` (private) |

## 1. Download the installer from SAP

1. Go to <https://www.sap.com/products/data-cloud/sybase-ase/trial.html> and click **Try Now**.
2. Fill in the form. SAP sends a verification email to your **company** email address; free mail domains are usually rejected.
3. Follow the link in the email to reach the download page, and download the **Linux** package (`ASE_Suite.linuxamd64.tgz`, about 2 GB). The Windows zip can't be used to build a Linux image.
4. Put it at `Trial-Downloads/ASE_Suite.linuxamd64.tgz` in this repo. `.gitignore` keeps it out of git, and `.dockerignore` sends only this file to Docker.

The download page doesn't show the exact version. The build reads it from the server with `select @@version` and tags the image with it, for example `16.1-SP00-PL02`. No service packs are applied; the image is exactly what the trial contains.

## 2. Build the image

You need Docker (Docker Desktop with WSL 2, or Docker Engine on Linux), Bash, and about 8 GB of free disk space during the build.

```shell
./scripts/build.sh
```

The script:

1. builds the image (about 10 minutes the first time, mostly the SAP installer; a few minutes when only the later layers change)
2. starts a test container and waits for its healthcheck
3. runs `select @@version`, `sp_helpsort`, the tuning values and `sp_lmconfig`, and prints the results
4. tags the image `ghcr.io/bill-ramos-rmoswi/sap-ase:<version>` and `:latest`

Pass `--no-cache` to rerun the SAP installer. A cached build reuses the installed server and keeps its SySAM grace-period date (see [below](#license-and-the-sysam-grace-period)).

You can override `IMAGE=<registry/name>` and `SA_PASSWORD=<password>`. The password is baked into the image, which is fine for a private test image but not for anything else.

### What the build does

The `Dockerfile` has two stages:

- **installer** extracts the tgz and runs `setup.bin -i silent -f config/ase_response.txt -DAGREE_TO_SAP_LICENSE=true` as the `sybase` user. The installer configures the server at build time, so containers start in seconds instead of running setup. Then `scripts/post-install.sql` creates `testdb`, and the `interfaces` file is set to listen on `0.0.0.0:5000`. `scripts/tune.sql` sizes the server and restarts it for the static `max online engines`, and `scripts/tune-after-restart.sql` raises the engine threads to 4. Finally the server is shut down cleanly, and everything a test server doesn't need is deleted.
- **runtime** copies only `/opt/sap` onto a clean base image, so the 2 GB installer never reaches the final image.

[config/ase_response.txt](config/ase_response.txt) is SAP's `sample_response.txt` (shipped in the tgz) trimmed down to keep the image lean:

- `CHOSEN_FEATURE_LIST=fase_srv,fopen_client`: no AMC, Cockpit, JDBC/ODBC/Python drivers, DBISQL or SySAM server
- no Backup Server, XP Server, Job Scheduler, Self Management or HADR
- `SY_CFG_ASE_CHARSET=cp850`, `SY_CFG_ASE_SORTORDER=bin_cp850`, page size left at the default
- small, "Tiny"-class sizing: master 52/26 MB, sybsystemprocs 196 MB, sybsystemdb 6 MB, tempdb 100 MB (the minimums from SAP's sample response file), and no memory or CPU tuning (`SY_CFG_ASE_OPT_ENABLE=false`). To match the [SAP sizing page](https://help.sap.com/docs/help/52f8de9cc8d44dc39ad7c49299dd9f1f/4090962cfc964c41954e3a3d3b86e6ba.html) exactly, edit the `*_SIZE` lines.

After install, the build also deletes the `diag*` debug servers (`diagserver` alone is about 420 MB), the Backup Server, Job Scheduler, upgrade and server-build tools, and the SAPMachine JRE, which only the installer and Java tools use.

> **Sort order:** in ASE a sort order belongs to a character set. `bin_iso_1` is the binary sort order for `iso_1`, and `bin_cp850` is the binary sort order for `cp850`. To change character sets, change both lines in the response file.

## 3. Push it to GitHub Container Registry

GHCR has no accounts of its own: you log in to `ghcr.io` (not Docker Hub) with your GitHub username and a GitHub token. A Docker Hub token doesn't work.

1. Get a token with `write:packages`. Either reuse the GitHub CLI's token, or create a classic personal access token with `write:packages` (and `read:packages`):

   ```shell
   gh auth refresh -h github.com -s write:packages   # once; approve in the browser
   export GHCR_TOKEN=$(gh auth token)
   ```

2. Log in and push:

   ```shell
   echo "$GHCR_TOKEN" | docker login ghcr.io -u bill-ramos-rmoswi --password-stdin
   ./scripts/build.sh --push
   ```

   The very first push to a new package can fail with `denied` after the layers upload, while GHCR finishes creating the package. Run `docker push` for both tags again; the layers are already there. Check the result with `docker manifest inspect ghcr.io/bill-ramos-rmoswi/sap-ase:<version>`.

3. In GitHub, open **Profile → Packages → sap-ase → Package settings**:
   - **Danger Zone → Change visibility**: make sure it's **Private**. A first push from a personal account is private by default.
   - **Manage Actions access → Add Repository**: add each repo whose workflows should pull the image (for example `bill-ramos-rmoswi/data-diff`) with the **Read** role.

## 4. Run it

```shell
docker run -d --name ase -p 5000:5000 ghcr.io/bill-ramos-rmoswi/sap-ase:latest
docker exec -it ase bash -c 'source /opt/sap/SYBASE.sh; isql -Usa -PPassword1 -SASE'
```

```sql
1> select @@version
2> go
```

- The healthcheck reports `healthy` once `sa` can log in and use `testdb`, about 6 seconds after start.
- `docker stop` sends SIGTERM, and the entrypoint runs `shutdown` through `isql`, so the devices stay consistent. The default 10-second stop timeout is enough.
- The server error log streams to `docker logs`. Two `SySAM: FlexNet Licensing error:-1,359` lines at each start are normal: there's no license file.
- Without a volume, data lives in the container, so every new container starts from the clean build-time state, which is what CI wants.
- To keep data across container recreation (for example a seeded benchmark database), mount a **named volume** on `/opt/sap/data`: `-v ase-data:/opt/sap/data`. Docker fills an empty named volume from the image, so `master` and `testdb` come along. Put any new devices in `/opt/sap/data` too. A volume on another path keeps the device files but not the `master` entries that point to them. Never bind-mount a host directory there, because that hides `master`. Delete the volume after rebuilding the image (`docker volume rm ase-data`, or `docker compose down -v`).

## Tuning

Set at build time by [scripts/tune.sql](scripts/tune.sql) and [scripts/tune-after-restart.sql](scripts/tune-after-restart.sql), for parallel test runs inside `mem_limit: 2g`. An idle server uses about 380 MB.

| Setting | Installer default | Image |
| --- | --- | --- |
| `max online engines` / `syb_default_pool` threads | 1 / 1 | 4 / 4 |
| `max memory` | 480 MB | 1.5 GB |
| default data cache | 8 MB | 768 MB |
| `procedure cache size` | 28 MB | 100 MB |
| `number of user connections` | 25 | 100 |
| `number of locks` | 10,000 | 200,000 |
| `number of open objects` / `open indexes` | 500 / 500 | 2,000 / 2,000 |
| tempdb | 106 MB | 1.1 GB (adds `tempdbdev2`) |

The server runs in threaded kernel mode, so `number of engines at startup` isn't supported. The engine count is the `syb_default_pool` thread count, capped by the static `max online engines`.

Memory and caches are dynamic, so a bigger local run can raise them without a restart, for example:

```sql
exec sp_configure 'max memory', 2097152   -- 4 GB, in 2k pages
go
exec sp_cacheconfig 'default data cache', '3G'
go
```

These changes are written to `ASE-16_1/ASE.cfg` in the container, so they're lost when the container is recreated. Rerun them from your setup script.

Clients connect with TDS on port 5000: `isql`, FreeTDS (`tsql -H localhost -p 5000 -U sa`), jConnect, or the SAP ASE ODBC driver.

## 5. Use it in a GitHub workflow

```yaml
jobs:
  ase:
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      packages: read            # needed to pull the private image
    # Workflows from forks get no access to the private package
    if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository
    services:
      ase:
        image: ghcr.io/bill-ramos-rmoswi/sap-ase:16.1-SP00-PL02
        credentials:
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
        ports:
          - 5000:5000
        options: >-
          --health-cmd /opt/sap/healthcheck.sh
          --health-interval 5s
          --health-retries 24
    steps:
      - uses: actions/checkout@v4
      - name: Check the server version
        run: docker exec ${{ job.services.ase.id }} bash -c 'source /opt/sap/SYBASE.sh >/dev/null; printf "select @@version\ngo\n" | isql -Usa -PPassword1 -SASE -b'
```

Pin the version tag rather than `latest` so a rebuild doesn't change CI unexpectedly. Rebuilding for the license grace period (below) keeps the same tag.

## Using this image in data-diff (not done yet)

data-diff has no ASE driver yet, so nothing in that repo uses this image. The work is planned in [docs/plan/SAP-ASE-One-Shot-Prompt.md](https://github.com/bill-ramos-rmoswi/data-diff/blob/master/docs/plan/SAP-ASE-One-Shot-Prompt.md). When the driver is added, it will need:

1. **`docker-compose.yml`**: an opt-in service, so `docker compose up` still works for anyone without access to the private image:

   ```yaml
       ase:
         container_name: dd-ase
         image: ghcr.io/bill-ramos-rmoswi/sap-ase:${ASE_TAG:-16.1-SP00-PL02}
         profiles: [ase]
         mem_limit: ${ASE_MEM:-2g}
         volumes:
           # Keeps seeded data (the 10M-row benchmark) across recreation; reset with `down -v`
           - ase-data:/opt/sap/data
         ports:
           - '5000:5000'
         tty: true
         networks:
           - local
   ```

   The image's own healthcheck works with `docker compose --profile ase up -d --wait ase`.

2. **`.github/workflows/pr-validate.yml`**: a job (or a step in `integration`) with `permissions: packages: read`, a GHCR login before `docker compose up`, and the fork-PR condition shown above. The `integration` job already runs Db2 6g, SQL Server 3g, PostgreSQL 2g and MySQL 2g on a 16 GB runner, so ASE at 2g brings it to 15g; a sibling job has more headroom.

   ```yaml
         - name: Log in to GHCR
           run: echo "${{ secrets.GITHUB_TOKEN }}" | docker login ghcr.io -u "${{ github.actor }}" --password-stdin
         - name: Start databases
           run: docker compose --profile ase up -d --wait --wait-timeout 300 postgres mysql ase
   ```

3. **Package access**: add `bill-ramos-rmoswi/data-diff` under the package's **Manage Actions access** with Read (step 3 above).

4. **Test settings**: a `TEST_SYBASE_CONN_STRING` in `tests/common.py` and a `DATADIFF_SYBASE_URI`, along the lines of `sybase://sa:Password1@localhost:5000/testdb` (host `ase` from inside the compose network, such as the devcontainer). The scheme depends on the driver. FreeTDS must use TDS version 5.0 for ASE.

5. **Checksums**: data-diff's cross-database hashing assumes UTF-8 strings. This server stores `cp850`, so the driver must convert to UTF-8 before hashing (or the client must connect with `charset=utf8` and ASE character-set conversion).

## License and the SySAM grace period

- The image runs the SAP trial software under the terms you accepted on download. **Keep the image private** and use it only for development and testing. Don't push it to a public registry or attach it to a public release.
- The install uses `SYSAM_LICENSE_SOURCE=proceed_without_license`, so ASE runs in SySAM's license **grace period**: **90 days**, counted from when the server was configured, which is image build time. `sp_lmconfig` shows `ASE_CORE ... graced` with the expiry date, and the error log says so at every start:

  ```text
  SySAM: WARNING: ASE will shutdown on Sat 06 Feb 2027 08:46:32 PM UTC, unless a suitable ASE_CORE license is obtained before that date.
  ```

  `build.sh` prints that line. **Rebuild and push the image with `./scripts/build.sh --no-cache --push` before the date**, for example every 60 days or so, or CI will start failing. A cached rebuild doesn't start a new grace period, because it reuses the installed server. The rebuild keeps the same version tag.

## Files

| File | Purpose |
| --- | --- |
| [Dockerfile](Dockerfile) | Two-stage build: silent install, then a lean runtime image |
| [config/ase_response.txt](config/ase_response.txt) | Silent-install response file |
| [scripts/post-install.sql](scripts/post-install.sql) | Creates `testdb` at build time |
| [scripts/tune.sql](scripts/tune.sql), [scripts/tune-after-restart.sql](scripts/tune-after-restart.sql) | Server sizing at build time |
| [scripts/build-server.sh](scripts/build-server.sh) | Start, stop and isql helpers for the build steps |
| [scripts/entrypoint.sh](scripts/entrypoint.sh) | Runs ASE in the foreground; clean `shutdown` on SIGTERM |
| [scripts/healthcheck.sh](scripts/healthcheck.sh) | Healthy once `sa` can use `testdb` |
| [scripts/build.sh](scripts/build.sh) | Build, smoke-test, tag by version, optionally push |
