# syntax=docker/dockerfile:1
#
# SAP ASE (trial) for CI testing. Built locally from the SAP trial download;
# see README.md. Do not push the result to a public registry.

ARG BASE_IMAGE=rockylinux/rockylinux:9.6-minimal

############################################################################
# Stage 1: run the SAP installer and configure the server
############################################################################
FROM ${BASE_IMAGE} AS installer

ARG SA_PASSWORD=Password1

RUN microdnf install -y libaio glibc-langpack-en procps-ng hostname which findutils tar gzip shadow-utils \
 && microdnf clean all \
 && groupadd -g 1000 sybase \
 && useradd -u 1000 -g sybase -m -d /home/sybase -s /bin/bash sybase \
 && mkdir -p /opt/sap/data /tmp/ase-installer \
 && chown -R sybase:sybase /opt/sap /tmp/ase-installer

# ADD extracts the local tarball into its own (cached) layer
ADD --chown=sybase:sybase Trial-Downloads/ASE_Suite.linuxamd64.tgz /tmp/ase-installer/
COPY --chown=sybase:sybase config/ase_response.txt /tmp/ase_response.txt

USER sybase
WORKDIR /tmp/ase-installer

# Silent install and server configuration
RUN sed -i 's/\r$//' /tmp/ase_response.txt \
 && sed -i "s|@SA_PASSWORD@|${SA_PASSWORD}|" /tmp/ase_response.txt \
 && ./setup.bin -i silent -f /tmp/ase_response.txt \
      -DAGREE_TO_SAP_LICENSE=true -DRUN_SILENT=true \
 ; status=$?; \
   cat /opt/sap/log/ASE_Suite.log 2>/dev/null | tail -n 60 || true; \
   ls /opt/sap/log /opt/sap/ASE-16_1/init/logs 2>/dev/null || true; \
   tail -n 80 /opt/sap/ASE-16_1/init/logs/* 2>/dev/null || true; \
   test -f /opt/sap/ASE-16_1/install/RUN_ASE || { echo "install failed (setup.bin exit $status)"; exit 1; }

COPY --chown=sybase:sybase scripts/post-install.sql /tmp/post-install.sql

# Create testdb, listen on all interfaces, then shut down cleanly
RUN sed -i 's/\r$//' /tmp/post-install.sql \
 && source /opt/sap/SYBASE.sh \
 && sed -i -E 's/^(\s+(master|query) tcp ether )\S+( 5000)$/\10.0.0.0\3/' "$SYBASE/interfaces" \
 && cat "$SYBASE/interfaces" \
 && ( /opt/sap/ASE-16_1/install/RUN_ASE > /dev/null 2>&1 & ) \
 && for i in $(seq 1 60); do \
      echo 'select 1' | isql -Usa -P"${SA_PASSWORD}" -SASE -b >/dev/null 2>&1 && break; sleep 2; \
    done \
 && isql -Usa -P"${SA_PASSWORD}" -SASE -b -e -i /tmp/post-install.sql \
 && printf 'select @@version\ngo\nexec sp_helpsort\ngo\nshutdown\ngo\n' \
      | isql -Usa -P"${SA_PASSWORD}" -SASE -w 999 || true \
 ; for i in $(seq 1 30); do pgrep dataserver >/dev/null || break; sleep 1; done \
 ; ! pgrep dataserver

COPY --chown=sybase:sybase scripts/tune.sql scripts/tune-after-restart.sql scripts/build-server.sh /tmp/

# Size the server for tests: apply the configuration, restart for the static
# 'max online engines', raise the engine threads, check the result, shut down
RUN sed -i 's/\r$//' /tmp/tune.sql /tmp/tune-after-restart.sql /tmp/build-server.sh \
 && source /tmp/build-server.sh \
 && start_ase && run_sql /tmp/tune.sql && stop_ase \
 && start_ase && run_sql /tmp/tune-after-restart.sql \
 && printf "select count(*) from master..sysengines\ngo\n" | isql_sa -h-1 | tr -d ' \t' | grep -qx 4 \
 && printf "exec sp_helpdb tempdb\ngo\nexec sp_cacheconfig 'default data cache'\ngo\n" | isql_sa -w 200 \
 && stop_ase

USER root
# Drop what a test server doesn't need at runtime
#  - diag* are debug builds of each server (diagserver alone is ~420 MB)
#  - Backup Server, Job Scheduler, upgrade and server-build tools aren't used
#  - the SAPMachine JRE only serves the installer and Java-based tools
RUN cd /opt/sap \
 && rm -rf sybuninstall jre* shared/SAPJRE* shared/SAPMACHINE* shared/ase shared/lib/*.jar \
      log/* ASE-16_1/init/logs/* ASE-16_1/install/*.log.* ASE-16_1/ASE.0* ASE-16_1/ASE.bak \
      ASE-16_1/sample ASE-16_1/jobscheduler ASE-16_1/ThirdPartyLegal \
      COCKPIT* DBISQL jConnect* WS-* jutils* WLA SYBDIAG interf.old \
 && cd ASE-16_1/bin \
 && rm -f diag* *.sym backupserver sybmultbuf jsagent srvbuild* sqlupgrade* upgrade preupgrade \
      updatease extractjava auditinit sqlloc* \
 && cd /opt/sap \
 && : > ASE-16_1/install/ASE.log \
 && chown -R sybase:sybase /opt/sap

############################################################################
# Stage 2: runtime image without the 2 GB installer
############################################################################
FROM ${BASE_IMAGE}

ARG SA_PASSWORD=Password1

LABEL org.opencontainers.image.title="SAP ASE trial (test only)" \
      org.opencontainers.image.description="SAP Adaptive Server Enterprise from the SAP trial download, for CI tests. Not for redistribution." \
      org.opencontainers.image.source="https://github.com/bill-ramos-rmoswi/sap-ase-16-trial-docker-image"

RUN microdnf install -y libaio glibc-langpack-en procps-ng hostname shadow-utils \
 && microdnf clean all \
 && groupadd -g 1000 sybase \
 && useradd -u 1000 -g sybase -m -d /home/sybase -s /bin/bash sybase

COPY --from=installer --chown=sybase:sybase /opt/sap /opt/sap
COPY --chown=sybase:sybase --chmod=0755 scripts/entrypoint.sh scripts/healthcheck.sh /opt/sap/
RUN sed -i 's/\r$//' /opt/sap/entrypoint.sh /opt/sap/healthcheck.sh

ENV SA_PASSWORD=${SA_PASSWORD} \
    ASE_SERVER_NAME=ASE \
    LANG=en_US.UTF-8

USER sybase
WORKDIR /opt/sap
EXPOSE 5000
STOPSIGNAL SIGTERM

HEALTHCHECK --interval=5s --timeout=10s --start-period=20s --retries=24 \
  CMD ["/opt/sap/healthcheck.sh"]

ENTRYPOINT ["/opt/sap/entrypoint.sh"]
