# ---------------------------------------------------------------------------
# Dockerfile to build & run this Mendix app (SoccerSquad) as a container.
#
# Uses the official Mendix Docker Buildpack.
# ---------------------------------------------------------------------------

FROM alpine/git:2.45.2 AS buildpack

ARG DOCKER_BUILDPACK_REF=v6.0.7

WORKDIR /buildpack

RUN git clone \
    --branch "${DOCKER_BUILDPACK_REF}" \
    --depth 1 \
    --config core.autocrlf=false \
    https://github.com/mendix/docker-mendix-buildpack.git .

# ---------------------------------------------------------------------------
# MxBuild stage
# ---------------------------------------------------------------------------

FROM registry.access.redhat.com/ubi9/ubi-minimal:latest AS mxbuild

ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

ARG USER_UID=1001
ARG MPR_FILE=SoccerSquad.mpr

RUN rpm -ivh https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm && \
    microdnf update -y && \
    microdnf install -y glibc-langpack-en openssl fontconfig tzdata-java libgdiplus libicu tar gzip jq python311 java-11-openjdk-devel java-17-openjdk-devel java-21-openjdk-devel && \
    microdnf clean all && rm -rf /var/cache/yum

RUN echo "mendix:x:${USER_UID}:${USER_UID}:mendix user:/workdir:/sbin/nologin" >> /etc/passwd

COPY ${MPR_FILE} /tmp/project.mpr

RUN MENDIX_VERSION="$(python3.11 -c 'import sqlite3; print(sqlite3.connect("/tmp/project.mpr").execute("SELECT _ProductVersion FROM _MetaData LIMIT 1").fetchone()[0])')" && \
    mkdir -p /opt/mendix && \
    curl -fsSL "https://download.mendix.com/runtimes/mxbuild-${MENDIX_VERSION}.tar.gz" | \
    tar -C /opt/mendix -xzf - --owner=root:0 --group=root:0 --mode='uga=rX' && \
    rm /tmp/project.mpr

COPY --from=buildpack --chown=0:0 --chmod=0755 /buildpack/mxbuild/build /opt/mendix/build

ENV HOME=/workdir

RUN mkdir -p /workdir/project /workdir/output /workdir/.local/share/Mendix && \
    chown -R ${USER_UID}:${USER_UID} /workdir && \
    chmod -R 755 /workdir

COPY --chown=${USER_UID}:${USER_UID} . /workdir/project

USER ${USER_UID}
WORKDIR /workdir

RUN /opt/mendix/build "${MPR_FILE}" unversioned

# ---------------------------------------------------------------------------
# Builder stage
# ---------------------------------------------------------------------------

FROM registry.access.redhat.com/ubi9/ubi-minimal:latest AS builder

LABEL Author="Mendix Digital Ecosystems"
LABEL maintainer="digitalecosystems@mendix.com"

ARG DD_API_KEY

ARG CF_BUILDPACK=v5.0.35
ARG CF_BUILDPACK_URL=https://github.com/mendix/cf-mendix-buildpack/releases/download/${CF_BUILDPACK}/cf-mendix-buildpack.zip

ARG EXCLUDE_LOGFILTER=true
ARG BLOBSTORE
ARG BUILDPACK_XTRACE
ARG JAVA_VERSION=21

ARG USER_UID=1001
ENV USER_UID=${USER_UID}
ENV JAVA_VERSION=${JAVA_VERSION}
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

RUN microdnf update -y && \
    microdnf module enable nginx:1.26 -y && \
    microdnf install -y wget glibc-langpack-en python311 openssl tar gzip unzip libpq nginx nginx-mod-stream binutils fontconfig findutils java-11-openjdk-headless java-17-openjdk-headless java-21-openjdk-headless java-25-openjdk-headless && \
    microdnf remove -y /usr/bin/python && \
    microdnf clean all && rm -rf /var/cache/yum

RUN touch /run/nginx.pid && \
    chown -R ${USER_UID}:0 /var/log/nginx /var/lib/nginx /run && \
    chmod -R g=u /var/log/nginx /var/lib/nginx /run

RUN if [ -f /usr/bin/python ]; then rm /usr/bin/python; fi && \
    if [ -f /usr/bin/python3 ]; then rm /usr/bin/python3; fi && \
    ln -s /usr/bin/python3.11 /usr/bin/python3 && \
    ln -s /usr/bin/python3.11 /usr/bin/python

RUN mkdir -p /opt/mendix/buildpack /opt/mendix/build && \
    ln -s /root /home/vcap && \
    echo "Downloading CF Buildpack from ${CF_BUILDPACK_URL}" && \
    curl -fsSL ${CF_BUILDPACK_URL} -o /tmp/cf-mendix-buildpack.zip && \
    python3 -m zipfile -e /tmp/cf-mendix-buildpack.zip /opt/mendix/buildpack/ && \
    rm /tmp/cf-mendix-buildpack.zip && \
    chown -R ${USER_UID}:0 /opt/mendix && \
    chmod -R g=u /opt/mendix

COPY --from=buildpack /buildpack/scripts/compilation.py /opt/mendix/buildpack/

ENV CF_STACK=cflinuxfs4

RUN PYTHON_BUILD_RPMS="python3.11-pip python3.11-devel libffi-devel gcc" && \
    microdnf install -y ${PYTHON_BUILD_RPMS} && \
    mkdir -p /home/vcap/.local/bin && \
    if [ ! -f /home/vcap/.local/bin/pip ]; then ln -s /usr/bin/pip3.11 /home/vcap/.local/bin/pip; fi && \
    if ! command -v pip3; then ln -s /usr/bin/pip3.11 /usr/bin/pip3; fi && \
    rm /opt/mendix/buildpack/vendor/wheels/* && \
    chmod +rx /opt/mendix/buildpack/bin/bootstrap-python && \
    /opt/mendix/buildpack/bin/bootstrap-python /opt/mendix/buildpack /tmp/buildcache && \
    microdnf remove -y ${PYTHON_BUILD_RPMS} && \
    microdnf clean all && rm -rf /var/cache/yum

ENV PYTHONPATH="/opt/mendix/buildpack/lib/:/opt/mendix/buildpack/:/opt/mendix/buildpack/lib/python3.11/site-packages/"

ENV NGINX_CUSTOM_BIN_PATH=/usr/sbin/nginx

COPY --from=mxbuild /workdir/output.mda /tmp/output.mda

RUN python3 -m zipfile -e /tmp/output.mda /opt/mendix/build && \
    rm /tmp/output.mda

COPY --from=buildpack /buildpack/scripts/startup.py /buildpack/scripts/vcap_application.json /opt/mendix/build/

RUN mkdir -p /tmp/buildcache/bust /tmp/cf-deps /var/mendix/build /var/mendix/build/.local && \
    chmod +rx /opt/mendix/buildpack/compilation.py && \
    chmod +rx /opt/mendix/buildpack/buildpack/stage.py && \
    chmod +rx /opt/mendix/build/startup.py && \
    cd /opt/mendix/buildpack && \
    ./compilation.py /opt/mendix/build /tmp/buildcache /tmp/cf-deps 0 && \
    rm -fr /tmp/buildcache /tmp/javasdk /tmp/opt /tmp/downloads /opt/mendix/buildpack/compilation.py /var/mendix && \
    ln -s /opt/mendix/.java /opt/mendix/build && \
    chown -R ${USER_UID}:0 /opt/mendix && \
    chmod -R g=u /opt/mendix

# ---------------------------------------------------------------------------
# Runtime stage
# ---------------------------------------------------------------------------

FROM registry.access.redhat.com/ubi9/ubi-minimal:latest

LABEL Author="Mendix Digital Ecosystems"
LABEL maintainer="digitalecosystems@mendix.com"

ARG USER_UID=1001
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

RUN microdnf update -y && \
    microdnf module enable nginx:1.26 -y && \
    microdnf install -y glibc-langpack-en python311 openssl nginx nginx-mod-stream java-11-openjdk-headless java-17-openjdk-headless java-21-openjdk-headless java-25-openjdk-headless tzdata-java fontconfig binutils && \
    microdnf clean all && rm -rf /var/cache/yum

RUN touch /run/nginx.pid && \
    chown -R ${USER_UID}:0 /var/log/nginx /var/lib/nginx /run && \
    chmod -R g=u /var/log/nginx /var/lib/nginx /run

RUN if [ -f /usr/bin/python ]; then rm /usr/bin/python; fi && \
    if [ -f /usr/bin/python3 ]; then rm /usr/bin/python3; fi && \
    ln -s /usr/bin/python3.11 /usr/bin/python3 && \
    ln -s /usr/bin/python3.11 /usr/bin/python

RUN mkdir -p /home /app/log /opt/mendix/build /opt/datadog-agent/run && \
    ln -s /opt/mendix/build /home/vcap && \
    chown -R ${USER_UID}:0 /home/vcap /opt/datadog-agent/run /app/log && \
    chmod -R g=u /home/vcap /opt/datadog-agent/run /app/log

COPY --from=buildpack --chmod=0755 --chown=0:0 /buildpack/scripts/host /usr/local/bin/

RUN mkdir -p /opt/mendix && \
    chown -R ${USER_UID}:0 /opt/mendix && \
    chmod -R g=u /opt/mendix && \
    ln -s /opt/mendix/.java /root && \
    echo "mendix:x:${USER_UID}:${USER_UID}:mendix user:/opt/mendix/build:/sbin/nologin" >> /etc/passwd

ENV HOME=/opt/mendix/build
ENV PYTHONPATH="/opt/mendix/buildpack/lib/:/opt/mendix/buildpack/:/opt/mendix/buildpack/lib/python3.11/site-packages/"

USER ${USER_UID}

COPY --from=builder /opt/mendix /opt/mendix

ENV NGINX_CUSTOM_BIN_PATH=/usr/sbin/nginx

WORKDIR /opt/mendix/build

ENV PORT=8080

EXPOSE 8080

ENTRYPOINT ["/opt/mendix/build/startup.py"]
