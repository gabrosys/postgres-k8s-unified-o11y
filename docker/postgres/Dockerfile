# syntax=docker/dockerfile:1.7
FROM ghcr.io/cloudnative-pg/postgresql:18-standard-bookworm@sha256:4f787ef64a7fcacb53700cc5d24f9729a984d45eee30cba255459b669ba57dcf AS base

FROM base AS builder
USER root
ARG PG_MAJOR=18
# Release v0.1.3 predates PG 18 support.
ARG PG_TRACING_REF=c343277660011200212c4e0833eea0c6b1ee8fa2

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential ca-certificates git libcurl4-openssl-dev \
        postgresql-server-dev-${PG_MAJOR} \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
RUN git clone https://github.com/DataDog/pg_tracing.git . \
    && git checkout "${PG_TRACING_REF}"

# Empty PG_CFLAGS drops upstream's -Werror.
RUN make PG_CFLAGS= && make PG_CFLAGS= install DESTDIR=/out

FROM base AS pg_stat_ch
USER root
ARG PG_MAJOR=18
ARG PG_STAT_CH_VERSION=v0.4.0
ARG TARGETARCH

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    dist="pg_stat_ch-${PG_STAT_CH_VERSION}-pg${PG_MAJOR}-linux-${TARGETARCH}"; \
    curl -fsSL -o /tmp/pg_stat_ch.tar.gz \
      "https://github.com/ClickHouse/pg_stat_ch/releases/download/${PG_STAT_CH_VERSION}/${dist}.tar.gz"; \
    tar -xzf /tmp/pg_stat_ch.tar.gz -C /tmp --strip-components=1; \
    mkdir -p /out"$(pg_config --pkglibdir)" /out"$(pg_config --sharedir)/extension"; \
    cp /tmp/pg_stat_ch.so      /out"$(pg_config --pkglibdir)/"; \
    cp /tmp/pg_stat_ch.control /out"$(pg_config --sharedir)/extension/"; \
    cp /tmp/pg_stat_ch--*.sql  /out"$(pg_config --sharedir)/extension/"

FROM base
USER root
# pg_tracing links libcurl, which the base image lacks.
RUN apt-get update && apt-get install -y --no-install-recommends libcurl4 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder    /out/ /
COPY --from=pg_stat_ch /out/ /
USER 26
