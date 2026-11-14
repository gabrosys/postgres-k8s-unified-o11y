# Unified Observability for PostgreSQL on Kubernetes

A reference observability pipeline for PostgreSQL on Kubernetes.

## The problem

When a service backed by PostgreSQL gets slow, the evidence is in three
places. Metrics in a time-series database show how the instances are doing.
Statements and errors sit in a log aggregator. Application traces end at the
database client span, so they say a query was slow but not which plan ran or
what PostgreSQL did with it. Getting from a slow request to the statement
behind it means jumping between tools and matching timestamps by hand.

To reproduce that, each cluster here runs [HammerDB](https://www.hammerdb.com),
an open-source database load tool. Its TPROC-C workload is an OLTP workload
derived from TPC-C. Its virtual users run five transactions (New-Order,
Payment, Order-Status, Delivery and Stock-Level) against a schema of
warehouses, districts, customers, orders and stock.

## The approach

Here PostgreSQL reports on itself, and every signal lands in one ClickHouse
database where a single SQL query can join them.

Take a New-Order transaction from the HammerDB workload. While it runs:

- `pg_tracing` records spans for the planning and execution of each statement.
  It samples 5% of the statements in the `tpcc` database, and it always
  traces a statement that arrives with a sampled W3C `traceparent` comment,
  attaching the spans to the caller's trace.
- `pg_stat_ch` emits one event per statement with its text, duration, rows,
  CPU time and error code.
- The server log records the statement if it took longer than 20ms, along with
  errors and background work such as checkpoints.
- The CloudNativePG exporter publishes the instance's counters, and cAdvisor
  its CPU and memory.

The first three carry the PostgreSQL `query_id`. PostgreSQL computes it from
the parse tree, so it stays the same when the plan changes, and it is the key
that joins them:

```sql
otel_traces.SpanAttributes['query.query_id']
otel_logs.LogAttributes['query_id']   -- ServiceName = 'pg_stat_ch'
otel_logs.LogAttributes['query_id']   -- ServiceName = 'postgres-server-log'
```

Every row also carries its namespace and pod, so metrics join on time and
pod. Metrics from scraped targets have `k8s.pod.name`; cAdvisor series name
the pod in their `pod` and `namespace` labels. A server-log line belongs to a
trace when it contains the trace's `traceparent`, or when its pod, backend PID
and `query_id` match a span of the trace and it was written while the trace
ran.

HammerDB has no tracing of its own, so its traces start inside PostgreSQL.
The `checkout` service on pg-alpha is instrumented: each of its statements
runs in a client span and carries that span's `traceparent`, so its traces go
from the HTTP request down to the plan nodes.

## Architecture

```
 pg-alpha (3 instances), pg-beta (2 instances): one namespace per cluster
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                                  │
│  ┌────────────┐        ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  HammerDB  │──SQL──▶│                     PostgreSQL 18, CloudNativePG                     │  │
│  │  TPROC-C   │        │             primary and streaming replicas, one per node             │  │
│  │  25 users  │        │                                                                      │  │
│  └────────────┘        │ pg_tracing     pg_stat_ch     server log             exporter        │  │
│  ┌────────────┐        │  (spans)        (events)       (stdout)               :9187          │  │
│  │  checkout  │──SQL──▶│                                                                      │  │
│  │  pg-alpha  │        │ extensions mounted as image volumes                                  │  │
│  └─────┬──────┘        └──────┬──────────────┬──────────────┬─────────────────────┬───────────┘  │
│        │                      │              │              │                     │              │
└────────┼──────────────────────┼──────────────┼──────────────┼─────────────────────┼──────────────┘
         │ OTLP                 │              │              │                     │
         │                      │ OTLP/HTTP    │ OTLP/gRPC    │ log files           │ Prometheus
         │                      │              │              │ on node             │ scrape
         │                      │              │              │                     │
         │                      │              │              │                     │
 o11y    │                      │              │              │                     │
┌────────┼──────────────────────┼──────────────┼──────────────┼─────────────────────┼──────────────┐
│        │                      │              │              ▼                     ▼              │
│        │                      │              │      ┌───────────────┐   ┌───────────────────┐    │
│        │                      │              │      │  otel-agent   │   │   otel-scraper    │    │
│        │                      │              │      │   DaemonSet   │   │ target allocator  │    │
│        │                      │              │      └───────┬───────┘   └─────────┬─────────┘    │
│        │                      │              │              │                     │              │
│        │                      │              │              │ OTLP/gRPC,          │ + ClickHouse,│
│        │                      │              │              │ round robin         │ collectors,  │
│        │                      │              │              │                     │ cAdvisor     │
│        │                      ▼              ▼              ▼                     ▼              │
│        │            ┌────────────────────────────────────────────────────────────────────┐       │
│        │            │                      otel-gateway, 2 replicas                      │       │
│        └───────────▶│      Kubernetes metadata, batching, export queue on a volume       │       │
│                     └──────────────────────────────────┬─────────────────────────────────┘       │
│                                                        │ inserts, native protocol :9000          │
│                                                        ▼                                         │
│   ┌────────────────┐             ┌──────────────────────────────────────────┐   ┌──────────────┐ │
│   │     Keeper     │◀────────────│     ClickHouse, 1 shard, 2 replicas      │◀──│  schema Job  │ │
│   └────────────────┘             │  otel_traces, otel_logs, otel_metrics_*  │   │ migrate, TTL │ │
│                                  └─────────────────────┬────────────────────┘   └──────────────┘ │
│                                                        ▲ SQL, read-only user                     │
│                                                        │                                         │
│                                            ┌───────────┴───────────┐                             │
│                                            │ Grafana, 5 dashboards │◀── browser, localhost:3000  │
│                                            └───────────────────────┘                             │
└──────────────────────────────────────────────────────────────────────────────────────────────────┘
```

kind runs one control plane and three workers. Each PostgreSQL cluster gets
its own namespace, and everything else runs in `o11y`.

CloudNativePG runs PostgreSQL 18 from the stock image. The two extensions are
built into small images of their own and mounted as image volumes, so there is
no custom PostgreSQL image to maintain. A HammerDB pod per cluster drives
a TPROC-C (TPC-C-like) OLTP workload with 4 warehouses and 25 virtual users
(clients). On pg-alpha, a small Go
service, `checkout`, takes orders on the same schema, and a curl loop sends it
five requests a second. An init container applies its SQL migrations up to
the `APP_VERSION` of the rollout.

The OpenTelemetry Operator runs three collector tiers. `otel-agent` runs on
every node, tails the PostgreSQL server log from the node's log files and
keeps its read position and send queue on the node. `otel-scraper` scrapes
CloudNativePG, ClickHouse, the collectors and cAdvisor; its target allocator
finds them through PodMonitors and ServiceMonitors. Both send to the gateways
with client-side round robin over a headless Service, while the two
extensions send to the gateways directly.

`otel-gateway` is the only writer to ClickHouse. It adds Kubernetes metadata,
batches, and keeps its export queue on a persistent volume, so it goes on
accepting data while ClickHouse is down and writes it once ClickHouse is back.

The Altinity operator runs ClickHouse as one shard with two replicas and a
Keeper. The tables follow the OpenTelemetry ClickHouse exporter's schema, and
a golang-migrate Job creates them as replicated tables and sets the retention
per signal. Grafana reads them through one datasource with a read-only user
and per-query limits, and ships five dashboards, described below.

The operators come from pinned Helm charts: CloudNativePG, the Altinity
ClickHouse operator and the OpenTelemetry Operator, which generates its own
webhook certificate. The Prometheus Operator CRDs are installed without the
operator so the target allocator can read PodMonitors and ServiceMonitors.
The manifests are a Kustomize base with a `kind` overlay, and every image is
pinned in `images.txt`.

## Usage

### Bring it up

You need Docker, kind, kubectl, Helm, curl, jq, yq and kubeconform. Then:

```bash
make setup-all
```

It checks the prerequisites, creates the kind cluster, installs the operators,
builds the two extension images and the checkout service and loads them into
kind, and deploys the overlay. Each step is also a target of its own (`make prereqs`, `make kind`,
`make operators`, `make images`, `make deploy`), and running `setup-all` again
on a working cluster changes nothing. `make help` lists every target.

### Look at the data

Grafana is on http://localhost:3000, user `admin`, password `admin`. The
dashboards link to each other and carry their variables, so you follow an
incident by clicking:

- Service to database takes any service that sends spans: requests a
  second, p95, the share of time spent in the database, and its slowest
  requests.
- Postgres fleet shows every cluster's statement rate and p95, and ranks
  statements by total time.
- Query follows one `query_id`: its latency, the scan node of its sampled
  executions over time, so a plan change shows as a change of colour, and the
  executions themselves.
- Trace shows one request: the span waterfall from the application into
  the plan nodes, the server-log lines it wrote, and the CPU and disk reads of
  its pod two minutes either side.
- Observability pipeline shows what the gateways accepted against what
  reached ClickHouse, their queues and their memory.

Each keeps at most four panels in view; the rest sit in a collapsed `Details`
row. Nothing in them names a cluster or a service.

ClickHouse answers on ports 8123 (HTTP) and 9000 (native) of your machine, and
`make ch-client` opens a client on the `otel` database.

### Query from the terminal

Three targets run the cross-signal queries in `scripts/queries`. They read
`PG_CLUSTER` (default `pg-alpha`) and `WINDOW_MIN` (default 10).

```bash
make top-queries PG_CLUSTER=pg-beta
make timeline QUERY_ID=<query_id>
make drill QUERY_ID=<query_id>
make drill TRACE_ID=<trace_id>
```

`top-queries` ranks the cluster's statements by total time and prints their
`query_id`. `timeline` shows one query per minute: calls, p95 latency, the
slowest trace, and the cluster's disk reads and CPU. `drill` takes the slowest
trace of a `QUERY_ID`, or a given `TRACE_ID`, and prints its spans and the
server-log lines that belong to it in time order.

### The incident

```bash
make incident
make incident-fix
```

`incident` rolls out checkout `APP_VERSION=2`, whose migration drops the
index behind its order-history lookup as unused. The lookup goes from an
index-only scan of about 0.1ms to a parallel sequential scan of `order_line`,
with the same `query_id`. `incident-fix` rolls forward to version 3, whose
migration recreates the index. Both are `kubectl set env` on the Deployment,
so `make deploy` keeps whichever version is live.

### Break it and fix it

```bash
make chaos-degrade
make chaos-restore
```

`chaos-degrade` sets `enable_indexscan` and `enable_bitmapscan` to `off` in
every Cluster spec, the kind of override a debugging session leaves behind.
CloudNativePG reloads it without a restart. New-Order goes from under 10ms to
about 55ms with the same `query_id`, and the slow calls start appearing in the
server log. `chaos-restore` removes the override.

### Test it

```bash
make smoke
make resilience
```

`smoke` runs every test suite against the running cluster: manifests, images,
operators, ClickHouse and its schema, the pipeline end to end, PostgreSQL and
its extensions, the workload, the checkout service and its incident, the
correlation queries, Grafana and the dashboards. Some suites disturb the cluster on purpose: they fail over
pg-alpha, apply and remove the chaos override, take a ClickHouse replica down
and restart HammerDB. Leave the cluster a few minutes to settle before a demo.

`resilience` restarts a gateway and a ClickHouse replica under load, then
stops ClickHouse for three minutes. It checks that every span the gateways
accepted and every span pg_tracing sent ends up in ClickHouse, and that no
gateway runs out of memory. `make lint` validates the rendered manifests
without a cluster.

### Tear it down

```bash
make teardown
```

## Demo

This demo follows one incident on the `checkout` service, from the release
that causes it to the release that fixes it. Start from a healthy cluster and set
Grafana to the last 30 minutes.

Roll out the release:

```bash
kubectl -n pg-alpha set env deploy/checkout APP_VERSION=2
```

Its migration drops `checkout_ol_item`, the index behind the order-history
lookup. The lookup was an index-only scan of about 0.1ms; now it is a parallel
sequential scan of `order_line` that takes about 18ms.

Then follow it through the dashboards:

1. Service to database: checkout's p95 rises, and the extra time is in the
   database, not in the service.
2. Postgres fleet: only pg-alpha moves. The lookup climbs the statements
   ranked by total time; open its `query_id`.
3. Query: latency steps up at the rollout, and the plan panel switches from
   `IndexOnlyScan` to `SeqScan` with the same `query_id`.
4. Trace: send one request and open its trace.

   ```bash
   kubectl -n pg-alpha exec deploy/checkout-load -- \
     curl -si -X POST http://checkout:8080/checkout
   ```

   Paste the `X-Trace-Id` header into the Trace dashboard. The waterfall goes
   from `POST /checkout` through the client span into the PostgreSQL planner
   and the sequential scan, next to the request's server-log lines and the
   pod's CPU and disk reads. The server log keeps statements over 20ms, so a
   request just under the threshold has no log line; the slowest row of
   Sampled executions on the Query dashboard always has one.

Fix it by rolling forward:

```bash
kubectl -n pg-alpha set env deploy/checkout APP_VERSION=3
```

The version 3 migration recreates the index. New executions go back to the
index-only scan within seconds, and the Query dashboard shows the regression
and the fix on one `query_id`. `make incident` and `make incident-fix` run the
same two rollouts.

## References

| Tool | Used for | Website | Source |
| --- | --- | --- | --- |
| CloudNativePG | PostgreSQL operator | [cloudnative-pg.io](https://cloudnative-pg.io) | [cloudnative-pg/cloudnative-pg](https://github.com/cloudnative-pg/cloudnative-pg) |
| pg_tracing | PostgreSQL spans | | [DataDog/pg_tracing](https://github.com/DataDog/pg_tracing) |
| pg_stat_ch | Per-statement events | | [ClickHouse/pg_stat_ch](https://github.com/ClickHouse/pg_stat_ch) |
| OpenTelemetry Collector | Agent, scraper and gateway | [opentelemetry.io](https://opentelemetry.io) | [open-telemetry/opentelemetry-collector-contrib](https://github.com/open-telemetry/opentelemetry-collector-contrib) |
| OpenTelemetry Operator | Collectors and target allocator | [opentelemetry.io](https://opentelemetry.io) | [open-telemetry/opentelemetry-operator](https://github.com/open-telemetry/opentelemetry-operator) |
| ClickHouse | Storage for all signals | [clickhouse.com](https://clickhouse.com) | [ClickHouse/ClickHouse](https://github.com/ClickHouse/ClickHouse) |
| Altinity ClickHouse Operator | ClickHouse and Keeper on Kubernetes | [altinity.com](https://altinity.com) | [Altinity/clickhouse-operator](https://github.com/Altinity/clickhouse-operator) |
| golang-migrate | ClickHouse schema migrations | | [golang-migrate/migrate](https://github.com/golang-migrate/migrate) |
| Grafana | Dashboards | [grafana.com](https://grafana.com) | [grafana/grafana](https://github.com/grafana/grafana) |
| ClickHouse data source for Grafana | Grafana to ClickHouse | | [grafana/clickhouse-datasource](https://github.com/grafana/clickhouse-datasource) |
| HammerDB | TPROC-C workload | [hammerdb.com](https://www.hammerdb.com) | [TPC-Council/HammerDB](https://github.com/TPC-Council/HammerDB) |
| pgx | PostgreSQL driver of the checkout service | | [jackc/pgx](https://github.com/jackc/pgx) |
| OpenTelemetry Go | Tracing in the checkout service | [opentelemetry.io](https://opentelemetry.io) | [open-telemetry/opentelemetry-go](https://github.com/open-telemetry/opentelemetry-go) |
| kind | Local Kubernetes cluster | [kind.sigs.k8s.io](https://kind.sigs.k8s.io) | [kubernetes-sigs/kind](https://github.com/kubernetes-sigs/kind) |

## License

MIT. See [LICENSE](LICENSE).
