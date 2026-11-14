# syntax=docker/dockerfile:1.7
ARG BASE
FROM ${BASE} AS builder
USER 0
# Release v0.1.3 predates PG 18 support.
ARG PG_TRACING_REF=c343277660011200212c4e0833eea0c6b1ee8fa2

RUN ldconfig -p | awk '{print $NF}' | grep '^/' | sort -u > /tmp/base-libs \
 && apt-get update && apt-get install -y --no-install-recommends \
      build-essential ca-certificates git libcurl4-openssl-dev postgresql-server-dev-18 \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /build
RUN git clone https://github.com/DataDog/pg_tracing.git . && git checkout "${PG_TRACING_REF}"
# Empty PG_CFLAGS drops upstream's -Werror.
RUN make PG_CFLAGS= && make PG_CFLAGS= install DESTDIR=/out

# libcurl and the libraries it pulls in that the minimal operand image lacks.
RUN mkdir /system \
 && ldd /out/usr/lib/postgresql/18/lib/pg_tracing.so | awk '{print $3}' | grep '^/' | sort -u > /tmp/deps \
 && comm -13 /tmp/base-libs /tmp/deps | while read -r lib; do \
      real=$(readlink -f "$lib"); cp -a "$real" /system/; \
      [ "$(basename "$lib")" = "$(basename "$real")" ] || ln -s "$(basename "$real")" "/system/$(basename "$lib")"; \
    done

FROM scratch
ARG BASE
LABEL io.cnpg.base="${BASE}"
COPY --from=builder /out/usr/lib/postgresql/18/lib/ /lib/
COPY --from=builder /out/usr/share/postgresql/18/extension/ /share/extension/
COPY --from=builder /system/ /system/
