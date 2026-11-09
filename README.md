# SAP ASE trial Docker image

A lean Docker image of **SAP Adaptive Server Enterprise (ASE)**, built from SAP's free trial download, for running database tests in GitHub Actions. It was made for [data-diff](https://github.com/bill-ramos-rmoswi/data-diff).

SAP doesn't publish an ASE container image, and its trial license doesn't allow redistribution. So this repo holds only the recipe: you download the installer yourself, build the image locally, and push it to a **private** registry that your own workflows can pull from.

| | |
| --- | --- |
| Version | 16.1 SP00 PL02 (EBF 31284), from `select @@version` |
| Base image | Rocky Linux 9 minimal, `linux/amd64` |
| Server | `ASE` on port `5000`, login `sa` / `Password1` |
| Database | `testdb` (250 MB data, 50 MB log, `trunc log on chkpt`, `select into/bulkcopy`) |
| Character set / sort order | `cp850` / `bin_cp850` (binary, sort order ID 50) |
| Page size | 4k (the installer default) |
| Installed features | ASE server and Open Client (`isql`) only |
| Image size | about 1.5 GB unpacked, about 210 MB compressed to pull; healthy about 6 s after start |
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

1. builds the image (about 10 minutes, mostly the SAP installer)
2. starts a test container and waits for its healthcheck
3. runs `select @@version`, `sp_helpsort` and `sp_lmconfig`, and prints the results
4. tags the image `ghcr.io/bill-ramos-rmoswi/sap-ase:<version>` and `:latest`

You can override `IMAGE=<registry/name>` and `SA_PASSWORD=<password>`. The password is baked into the image, which is fine for a private test image but not for anything else.

### What the build does

The `Dockerfile` has two stages:

- **installer** extracts the tgz and runs `setup.bin -i silent -f config/ase_response.txt -DAGREE_TO_SAP_LICENSE=true` as the `sybase` user. The installer configures the server at build time, so containers start in seconds instead of running setup. Then `scripts/post-install.sql` creates `testdb`, the `interfaces` file is set to listen on `0.0.0.0:5000`, the server is shut down cleanly, and everything a test server doesn't need is deleted.
- **runtime** copies only `/opt/sap` onto a clean base image, so the 2 GB installer never reaches the final image.

[config/ase_response.txt](config/ase_response.txt) is SAP's `sample_response.txt` (shipped in the tgz) trimmed down to keep the image lean:

- `CHOSEN_FEATURE_LIST=fase_srv,fopen_client`: no AMC, Cockpit, JDBC/ODBC/Python drivers, DBISQL or SySAM server
- no Backup Server, XP Server, Job Scheduler, Self Management or HADR
- `SY_CFG_ASE_CHARSET=cp850`, `SY_CFG_ASE_SORTORDER=bin_cp850`, page size left at the default
- small, "Tiny"-class sizing: master 52/26 MB, sybsystemprocs 196 MB, sybsystemdb 6 MB, tempdb 100 MB (the minimums from SAP's sample response file), and no memory or CPU tuning (`SY_CFG_ASE_OPT_ENABLE=false`). To match the [SAP sizing page](https://help.sap.com/docs/help/52f8de9cc8d44dc39ad7c49299dd9f1f/4090962cfc964c41954e3a3d3b86e6ba.html) exactly, edit the `*_SIZE` lines.

After install, the build also deletes the `diag*` debug servers (`diagserver` alone is about 420 MB), the Backup Server, Job Scheduler, upgrade and server-build tools, and the SAPMachine JRE, which only the installer and Java tools use.

> **Sort order:** in ASE a sort order belongs to a character set. `bin_iso_1` is the binary sort order for `iso_1`, and `bin_cp850` is the binary sort order for `cp850`. To change character sets, change both lines in the response file.

## 3. Push it to GitHub Container Registry

1. Create a classic personal access token with `write:packages` (and `read:packages`).
2. Log in and push:

   ```shell
   echo "$GHCR_TOKEN" | docker login ghcr.io -u bill-ramos-rmoswi --password-stdin
   ./scripts/build.sh --push
   ```

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
- The server error log streams to `docker logs`.
- Data lives inside the container, so every new container starts from the clean build-time state, which is what tests want. Mount nothing over `/opt/sap/data`.

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
      - uses: actions/checkout@v7
      - name: Check the server version
        run: docker exec ${{ job.services.ase.id }} bash -c 'source /opt/sap/SYBASE.sh >/dev/null; printf "select @@version\ngo\n" | isql -Usa -PPassword1 -SASE -b'
```

Pin the version tag rather than `latest` so a rebuild doesn't change CI unexpectedly. Rebuilding for the license grace period (below) keeps the same tag.

## Using this image in data-diff (not done yet)

data-diff has no ASE driver yet, so nothing in that repo uses this image. When the driver is added, it will need:

1. **`docker-compose.yml`**: an opt-in service, so `docker compose up` still works for anyone without access to the private image:

   ```yaml
       ase:
         container_name: dd-ase
         image: ghcr.io/bill-ramos-rmoswi/sap-ase:${ASE_TAG:-16.1-SP00-PL02}
         profiles: [ase]
         mem_limit: ${ASE_MEM:-2g}
         ports:
           - '5000:5000'
         tty: true
         networks:
           - local
   ```

   The image's own healthcheck works with `docker compose --profile ase up -d --wait ase`.

2. **`.github/workflows/pr-validate.yml`**: a job (or a step in `integration`) with `permissions: packages: read`, a GHCR login before `docker compose up`, and the fork-PR condition shown above:

   ```yaml
         - name: Log in to GHCR
           run: echo "${{ secrets.GITHUB_TOKEN }}" | docker login ghcr.io -u "${{ github.actor }}" --password-stdin
         - name: Start databases
           run: docker compose --profile ase up -d --wait --wait-timeout 300 postgres mysql ase
   ```

3. **Package access**: add `bill-ramos-rmoswi/data-diff` under the package's **Manage Actions access** with Read (step 3 above).

4. **Test settings**: a `TEST_SYBASE_CONN_STRING` in `tests/common.py` and a `DATADIFF_SYBASE_URI`, along the lines of `sybase://sa:Password1@localhost:5000/testdb`. The scheme depends on the driver.

5. **Checksums**: data-diff's cross-database hashing assumes UTF-8 strings. This server stores `cp850`, so the driver must convert to UTF-8 before hashing (or the client must connect with `charset=utf8` and ASE character-set conversion).

## License and the SySAM grace period

- The image runs the SAP trial software under the terms you accepted on download. **Keep the image private** and use it only for development and testing. Don't push it to a public registry or attach it to a public release.
- The install uses `SYSAM_LICENSE_SOURCE=proceed_without_license`, so ASE runs in SySAM's license **grace period**: **90 days**, counted from when the server was configured, which is image build time. `sp_lmconfig` shows `ASE_CORE ... graced` with the expiry date, and the error log says so at every start:

  ```text
  SySAM: WARNING: ASE will shutdown on Sat 06 Feb 2027 08:46:32 PM UTC, unless a suitable ASE_CORE license is obtained before that date.
  ```

  `build.sh` prints that line. **Rebuild and push the image (`./scripts/build.sh --push`) before the date**, for example every 60 days or so, or CI will start failing. The rebuild keeps the same version tag.

## Files

| File | Purpose |
| --- | --- |
| [Dockerfile](Dockerfile) | Two-stage build: silent install, then a lean runtime image |
| [config/ase_response.txt](config/ase_response.txt) | Silent-install response file |
| [scripts/post-install.sql](scripts/post-install.sql) | Creates `testdb` at build time |
| [scripts/entrypoint.sh](scripts/entrypoint.sh) | Runs ASE in the foreground; clean `shutdown` on SIGTERM |
| [scripts/healthcheck.sh](scripts/healthcheck.sh) | Healthy once `sa` can use `testdb` |
| [scripts/build.sh](scripts/build.sh) | Build, smoke-test, tag by version, optionally push |
