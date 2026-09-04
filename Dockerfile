# ---------------------------------------------------------------------------
# Dockerfile to build & run this Mendix app (SoccerSquad) as a container.
#
# It uses the official Mendix Docker Buildpack
# (https://github.com/mendix/docker-mendix-buildpack). The buildpack compiles
# the Mendix model (.mpr) into a deployable archive and bundles the Mendix
# runtime, a JDK and nginx into the final image.
#
# The image listens on the port provided by the `PORT` environment variable
# (Render sets this automatically). The buildpack's startup script honours
# `PORT`.
#
# Build:
#   docker build -t soccersquad .
#
# Run locally:
#   docker run -p 8080:8080 -e ADMIN_PASSWORD=YourSecret1 -e PORT=8080 soccersquad
# ---------------------------------------------------------------------------

# 1) Fetch the Mendix Docker Buildpack. We pin a version for reproducible
#    builds. Using the git image keeps the final image small (the buildpack
#    sources are only needed in this stage and to generate the runtime
#    Dockerfile).
FROM alpine/git:2.45.2 AS buildpack
# Pin the buildpack by commit for reproducible builds. This is the master
# (v2.1.0) generation of the buildpack, which pairs with CF buildpack v4.30.14
# and the mendix/rootfs base images used below.
ARG DOCKER_BUILDPACK_REF=749a77d63a10676df0f93f88e3113d751397755d
WORKDIR /buildpack
RUN git clone https://github.com/mendix/docker-mendix-buildpack.git . && \
    git checkout ${DOCKER_BUILDPACK_REF}

# 2) Final image is produced by the buildpack's own multi-stage Dockerfile.
#    We copy the buildpack sources together with this Mendix project into the
#    build context and then hand off to the buildpack's Dockerfile by
#    importing its stages. Docker does not support "include another
#    Dockerfile", so the heavy lifting is done by the buildpack Dockerfile
#    that is copied into the context; this file simply prepares the context.
#
#    To keep everything in ONE Dockerfile we reproduce the buildpack's
#    official image build here (based on mendix/docker-mendix-buildpack
#    v5.1.0), copying the project from the local context instead of from a
#    separate "project" directory.

FROM mendix/rootfs:bionic AS builder

# Build-time variables
ARG DD_API_KEY
# CF buildpack version
ARG CF_BUILDPACK=v4.30.14
# CF buildpack download URL
ARG CF_BUILDPACK_URL=https://github.com/mendix/cf-mendix-buildpack/releases/download/${CF_BUILDPACK}/cf-mendix-buildpack.zip

# Exclude the logfilter binary by default
ARG EXCLUDE_LOGFILTER=true

# Allow specification of alternative BLOBSTORE location and debugging
ARG BLOBSTORE
ARG BUILDPACK_XTRACE

# Set the user ID
ARG USER_UID=1001

# 1. Create all directories needed by scripts
# 2. Download CF buildpack
# 3. Extract CF buildpack
# 4. Delete CF buildpack zip archive
# 5. Update ownership of /opt/mendix so that the app can run as a non-root user
# 6. Update permissions of /opt/mendix so that the app can run as a non-root user
RUN mkdir -p /opt/mendix/buildpack /opt/mendix/build &&\
    ln -s /root /home/vcap &&\
    echo "Downloading CF Buildpack from ${CF_BUILDPACK_URL}" &&\
    curl -fsSL ${CF_BUILDPACK_URL} -o /tmp/cf-mendix-buildpack.zip && \
    python3 -m zipfile -e /tmp/cf-mendix-buildpack.zip /opt/mendix/buildpack/ &&\
    rm /tmp/cf-mendix-buildpack.zip &&\
    chown -R ${USER_UID}:0 /opt/mendix &&\
    chmod -R g=u /opt/mendix

# Copy python scripts which execute the buildpack (exporting the VCAP variables)
COPY --from=buildpack /buildpack/scripts/compilation /buildpack/scripts/git /opt/mendix/buildpack/

# Copy the whole Mendix project (this repository) into the build directory.
# The .dockerignore file keeps the build context (and image) lean.
COPY . /opt/mendix/build

# Install the buildpack Python dependencies
RUN chmod +rx /opt/mendix/buildpack/bin/bootstrap-python && /opt/mendix/buildpack/bin/bootstrap-python /opt/mendix/buildpack /tmp/buildcache

# Add the buildpack modules
ENV PYTHONPATH="/opt/mendix/buildpack/lib/:/opt/mendix/buildpack/:/opt/mendix/buildpack/lib/python3.6/site-packages/"

# Use nginx supplied by the base OS
ENV NGINX_CUSTOM_BIN_PATH=/usr/sbin/nginx

# 1. Create cache directory and directory for dependencies which can be shared
# 2. Set permissions for compilation scripts
# 3. Navigate to buildpack directory
# 4. Call compilation script (compiles the .mpr into an .mda and stages the app)
# 5. Remove temporary files
# 6. Create symlink for java prefs used by CF buildpack
# 7/8. Update ownership/permissions so the app can run as a non-root user
RUN mkdir -p /tmp/buildcache /tmp/cf-deps /var/mendix/build /var/mendix/build/.local &&\
    chmod +rx /opt/mendix/buildpack/compilation /opt/mendix/buildpack/git /opt/mendix/buildpack/buildpack/stage.py &&\
    cd /opt/mendix/buildpack &&\
    ./compilation /opt/mendix/build /tmp/buildcache /tmp/cf-deps 0 &&\
    rm -fr /tmp/buildcache /tmp/javasdk /tmp/opt /tmp/downloads /opt/mendix/buildpack/compilation /opt/mendix/buildpack/git &&\
    ln -s /opt/mendix/.java /opt/mendix/build &&\
    chown -R ${USER_UID}:0 /opt/mendix /var/mendix &&\
    chmod -R g=u /opt/mendix /var/mendix

# ---------------------------------------------------------------------------
# Final (runtime) stage
# ---------------------------------------------------------------------------
FROM mendix/rootfs:ubi8
LABEL Author="Mendix Digital Ecosystems"
LABEL maintainer="digitalecosystems@mendix.com"

# Uninstall build-time dependencies to remove potentially vulnerable libraries
ARG UNINSTALL_BUILD_DEPENDENCIES=true

# Set the user ID
ARG USER_UID=1001
# Set the home path
ENV HOME=/opt/mendix/build

# Allow the user group to modify /etc/passwd so that OpenShift 3 randomized UIDs are supported by CF Buildpack
RUN chmod g=u /etc/passwd &&\
    chown ${USER_UID}:0 /etc/passwd

# Uninstall Ubuntu packages which are only required during build time
RUN if [ "$UNINSTALL_BUILD_DEPENDENCIES" = "true" ] && grep -q ubuntu /etc/os-release ; then\
        DEBIAN_FRONTEND=noninteractive apt-mark manual libfontconfig1 && \
        DEBIAN_FRONTEND=noninteractive apt-get remove --purge --auto-remove -q -y wget curl libgdiplus ; \
    fi

# Add the buildpack modules
ENV PYTHONPATH="/opt/mendix/buildpack/lib/:/opt/mendix/buildpack/:/opt/mendix/buildpack/lib/python3.6/site-packages/"

# Copy start scripts
COPY --from=buildpack /buildpack/scripts/startup /buildpack/scripts/vcap_application.json /opt/mendix/build/

# Create vcap home directory for Datadog configuration
RUN mkdir -p /home/vcap /opt/datadog-agent/run &&\
    chown -R ${USER_UID}:0 /home/vcap /opt/datadog-agent/run &&\
    chmod -R g=u /home/vcap /opt/datadog-agent/run

# 1. Make the startup script executable
# 2/3. Update ownership/permissions so the app can run as a non-root user
# 4. Ensure that running Java 8 as root will still be able to load offline licenses
RUN chmod +rx /opt/mendix/build/startup &&\
    chown -R ${USER_UID}:0 /opt/mendix &&\
    chmod -R g=u /opt/mendix &&\
    ln -s /opt/mendix/.java /root

USER ${USER_UID}

# Copy jre from build container
COPY --from=builder /var/mendix/build/.local/usr /opt/mendix/build/.local/usr

# Copy Mendix Runtime from build container
COPY --from=builder /var/mendix/build/runtimes /opt/mendix/build/runtimes

# Copy build artifacts from build container
COPY --from=builder /opt/mendix /opt/mendix

# Use nginx supplied by the base OS
ENV NGINX_CUSTOM_BIN_PATH=/usr/sbin/nginx

WORKDIR /opt/mendix/build

# Mendix listens on the port from the PORT environment variable.
# Render injects PORT automatically; default to 8080 for local use.
ENV PORT=8080
EXPOSE ${PORT}

ENTRYPOINT ["/opt/mendix/build/startup","/opt/mendix/buildpack/buildpack/start.py"]
