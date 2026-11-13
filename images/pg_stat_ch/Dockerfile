# syntax=docker/dockerfile:1.7
ARG BASE
FROM ${BASE} AS builder
USER 0
ARG PG_STAT_CH_VERSION=v0.4.0
ARG TARGETARCH

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /out/lib /out/share/extension && cd /tmp \
 && curl -fsSL -o pg_stat_ch.tar.gz \
      "https://github.com/ClickHouse/pg_stat_ch/releases/download/${PG_STAT_CH_VERSION}/pg_stat_ch-${PG_STAT_CH_VERSION}-pg18-linux-${TARGETARCH}.tar.gz" \
 && tar -xzf pg_stat_ch.tar.gz --strip-components=1 \
 && cp pg_stat_ch.so /out/lib/ \
 && cp pg_stat_ch.control pg_stat_ch--*.sql /out/share/extension/

FROM scratch
ARG BASE
LABEL io.cnpg.base="${BASE}"
COPY --from=builder /out/ /
