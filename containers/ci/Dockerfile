# syntax=docker/dockerfile:1
# raz currently targets x86-64 Linux only; build with --platform linux/amd64.
FROM debian:12-slim@sha256:a4672c0cb26fbdde88e38fa2dfb6c681942306680e41e4378b28770b6e79ee91 AS base

# Optional combined CA bundle for builds behind a TLS-inspecting proxy. It is
# mounted only for networked steps and never becomes part of the image.
RUN --mount=type=secret,id=proxy_ca \
    test "$(dpkg --print-architecture)" = amd64 && \
    if [ -f /run/secrets/proxy_ca ]; then \
        printf 'Acquire::https::CaInfo "/run/secrets/proxy_ca";\n' > /etc/apt/apt.conf.d/99-build-ca; \
    fi && \
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        bash ca-certificates curl git && \
    rm -rf /var/lib/apt/lists/* /etc/apt/apt.conf.d/99-build-ca

# Keep each compressed layer below Cloudflare's free-plan upload limit.
RUN --mount=type=secret,id=proxy_ca \
    if [ -f /run/secrets/proxy_ca ]; then \
        printf 'Acquire::https::CaInfo "/run/secrets/proxy_ca";\n' > /etc/apt/apt.conf.d/99-build-ca; \
    fi && \
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential pkg-config && \
    rm -rf /var/lib/apt/lists/* /etc/apt/apt.conf.d/99-build-ca

RUN --mount=type=secret,id=proxy_ca \
    if [ -f /run/secrets/proxy_ca ]; then \
        printf 'Acquire::https::CaInfo "/run/secrets/proxy_ca";\n' > /etc/apt/apt.conf.d/99-build-ca; \
    fi && \
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        bsdextrautils groff procps python3 tzdata && \
    rm -rf /var/lib/apt/lists/* /etc/apt/apt.conf.d/99-build-ca

FROM base AS build
COPY build-tools.sh /tmp/build-tools.sh
RUN --mount=type=secret,id=proxy_ca \
    if [ -f /run/secrets/proxy_ca ]; then \
        export CURL_CA_BUNDLE=/run/secrets/proxy_ca GIT_SSL_CAINFO=/run/secrets/proxy_ca; \
    fi; \
    sh /tmp/build-tools.sh

FROM base AS ci
LABEL org.opencontainers.image.title="raz CI" \
      org.opencontainers.image.description="raz 0.21.0 with concha, robbie and native build tools" \
      org.opencontainers.image.source="https://github.com/ldiaz94/raz" \
      org.opencontainers.image.version="0.21.0-debian12-r1"
COPY --from=build /opt/raz /opt/raz
COPY --from=build /usr/local/ /usr/local/
COPY --chmod=0644 smoke.sh /usr/local/share/raz-ci/smoke.sh
RUN ln -s /opt/raz/raz /usr/local/bin/raz && \
    sh /usr/local/share/raz-ci/smoke.sh
WORKDIR /workspace
CMD ["bash"]
