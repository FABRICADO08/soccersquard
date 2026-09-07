# ---------------------------------------------------------------------------
# Dockerfile to build & run this Mendix app (SoccerSquad) as a container.
#
# Uses the official Mendix Docker Buildpack.
# ---------------------------------------------------------------------------

FROM alpine/git:2.45.2 AS buildpack

ARG DOCKER_BUILDPACK_REF=749a77d63a10676df0f93f88e3113d751397755d

WORKDIR /buildpack

RUN git clone https://github.com/mendix/docker-mendix-buildpack.git . && \
    git checkout ${DOCKER_BUILDPACK_REF}

# ---------------------------------------------------------------------------
# Builder stage
# ---------------------------------------------------------------------------

FROM mendix/rootfs:bionic AS builder

ARG DD_API_KEY

ARG CF_BUILDPACK=v4.30.14

ARG CF_BUILDPACK_URL=https://github.com/mendix/cf-mendix-buildpack/releases/download/${CF_BUILDPACK}/cf-mendix-buildpack.zip

ARG EXCLUDE_LOGFILTER=true
ARG BLOBSTORE
ARG BUILDPACK_XTRACE

ARG USER_UID=1001

RUN mkdir -p /opt/mendix/buildpack /opt/mendix/build && \
    ln -s /root /home/vcap && \
    echo "Downloading CF Buildpack from ${CF_BUILDPACK_URL}" && \
    curl -fsSL ${CF_BUILDPACK_URL} -o /tmp/cf-mendix-buildpack.zip && \
    python3 -m zipfile -e /tmp/cf-mendix-buildpack.zip /opt/mendix/buildpack/ && \
    rm /tmp/cf-mendix-buildpack.zip && \
    chown -R ${USER_UID}:0 /opt/mendix && \
    chmod -R g=u /opt/mendix

COPY --from=buildpack /buildpack/scripts/compilation /buildpack/scripts/git /opt/mendix/buildpack/

COPY . /opt/mendix/build

RUN chmod +rx /opt/mendix/buildpack/bin/bootstrap-python && \
    /opt/mendix/buildpack/bin/bootstrap-python /opt/mendix/buildpack /tmp/buildcache

ENV PYTHONPATH="/opt/mendix/buildpack/lib/:/opt/mendix/buildpack/:/opt/mendix/buildpack/lib/python3.6/site-packages/"

ENV NGINX_CUSTOM_BIN_PATH=/usr/sbin/nginx
ENV JAVA_VERSION=21

RUN mkdir -p /tmp/buildcache /tmp/cf-deps /var/mendix/build /var/mendix/build/.local && \
    chmod +rx /opt/mendix/buildpack/compilation && \
    chmod +rx /opt/mendix/buildpack/git && \
    chmod +rx /opt/mendix/buildpack/buildpack/stage.py && \
    cd /opt/mendix/buildpack && \
    ./compilation /opt/mendix/build /tmp/buildcache /tmp/cf-deps 0 && \
    rm -fr /tmp/buildcache /tmp/javasdk /tmp/opt /tmp/downloads && \
    rm -f /opt/mendix/buildpack/compilation && \
    rm -f /opt/mendix/buildpack/git && \
    ln -s /opt/mendix/.java /opt/mendix/build && \
    chown -R ${USER_UID}:0 /opt/mendix /var/mendix && \
    chmod -R g=u /opt/mendix /var/mendix

# ---------------------------------------------------------------------------
# Runtime stage
# ---------------------------------------------------------------------------

FROM mendix/rootfs:ubi8

LABEL Author="Mendix Digital Ecosystems"
LABEL maintainer="digitalecosystems@mendix.com"

ARG UNINSTALL_BUILD_DEPENDENCIES=true
ARG USER_UID=1001

ENV HOME=/opt/mendix/build

RUN chmod g=u /etc/passwd && \
    chown ${USER_UID}:0 /etc/passwd

RUN if [ "$UNINSTALL_BUILD_DEPENDENCIES" = "true" ] && grep -q ubuntu /etc/os-release ; then \
        DEBIAN_FRONTEND=noninteractive apt-mark manual libfontconfig1 && \
        DEBIAN_FRONTEND=noninteractive apt-get remove --purge --auto-remove -q -y wget curl libgdiplus ; \
    fi

ENV PYTHONPATH="/opt/mendix/buildpack/lib/:/opt/mendix/buildpack/:/opt/mendix/buildpack/lib/python3.6/site-packages/"

COPY --from=buildpack /buildpack/scripts/startup /buildpack/scripts/vcap_application.json /opt/mendix/build/

RUN mkdir -p /home/vcap /opt/datadog-agent/run && \
    chown -R ${USER_UID}:0 /home/vcap /opt/datadog-agent/run && \
    chmod -R g=u /home/vcap /opt/datadog-agent/run

RUN chmod +rx /opt/mendix/build/startup && \
    chown -R ${USER_UID}:0 /opt/mendix && \
    chmod -R g=u /opt/mendix && \
    ln -s /opt/mendix/.java /root

USER ${USER_UID}

COPY --from=builder /var/mendix/build/.local/usr /opt/mendix/build/.local/usr
COPY --from=builder /var/mendix/build/runtimes /opt/mendix/build/runtimes
COPY --from=builder /opt/mendix /opt/mendix

ENV NGINX_CUSTOM_BIN_PATH=/usr/sbin/nginx

WORKDIR /opt/mendix/build

ENV PORT=8080

EXPOSE 8080

ENTRYPOINT ["/opt/mendix/build/startup","/opt/mendix/buildpack/buildpack/start.py"]
