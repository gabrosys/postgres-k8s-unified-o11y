# Unified Observability for PostgreSQL on Kubernetes

A reference observability pipeline for PostgreSQL on Kubernetes, and the demo
platform behind the talk _"Unified Observability for PostgreSQL on Kubernetes:
Logs, Traces, and Metrics under One Roof."_

## The problem

When a service backed by PostgreSQL gets slow, the evidence is in three
places. Metrics in a time-series database show how the instances are doing.
Statements and errors sit in a log aggregator. Application traces end at the
database client span, so they say a query was slow but not which plan ran or
what PostgreSQL did with it. Getting from a slow request to the statement
behind it means jumping between tools and matching timestamps by hand.

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

HammerDB has no tracing of its own, so its traces start inside PostgreSQL. An
instrumented application would see the PostgreSQL spans under its own.

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
│                        │  (spans)        (events)       (stdout)               :9187          │  │
│                        │                                                                      │  │
│                        │ extensions mounted as image volumes                                  │  │
│                        └──────┬──────────────┬──────────────┬─────────────────────┬───────────┘  │
│                               │              │              │                     │              │
└───────────────────────────────┼──────────────┼──────────────┼─────────────────────┼──────────────┘
                                │              │              │                     │
                                │ OTLP/HTTP    │ OTLP/gRPC    │ log files           │ Prometheus
                                │              │              │ on node             │ scrape
                                │              │              │                     │
                                │              │              │                     │
 o11y                           │              │              │                     │
┌───────────────────────────────┼──────────────┼──────────────┼─────────────────────┼──────────────┐
│                               │              │              ▼                     ▼              │
│                               │              │      ┌───────────────┐   ┌───────────────────┐    │
│                               │              │      │  otel-agent   │   │   otel-scraper    │    │
│                               │              │      │   DaemonSet   │   │ target allocator  │    │
│                               │              │      └───────┬───────┘   └─────────┬─────────┘    │
│                               │              │              │                     │              │
│                               │              │              │ OTLP/gRPC,          │ + ClickHouse,│
│                               │              │              │ round robin         │ collectors,  │
│                               │              │              │                     │ cAdvisor     │
│                               ▼              ▼              ▼                     ▼              │
│                     ┌────────────────────────────────────────────────────────────────────┐       │
│                     │                      otel-gateway, 2 replicas                      │       │
│                     │      Kubernetes metadata, batching, export queue on a volume       │       │
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
│                                            │ Grafana, 3 dashboards │◀── browser, localhost:3000  │
│                                            └───────────────────────┘                             │
└──────────────────────────────────────────────────────────────────────────────────────────────────┘
```

kind runs one control plane and three workers. Each PostgreSQL cluster gets
its own namespace, and everything else runs in `o11y`.

CloudNativePG runs PostgreSQL 18 from the stock image. The two extensions are
built into small images of their own and mounted as image volumes, so there is
no custom PostgreSQL image to maintain. A HammerDB pod per cluster drives
TPROC-C with 4 warehouses and 25 virtual users.

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
and per-query limits, and ships three dashboards: `pg-unified` and
`pg-query-detail` for the workload, `pipeline-health` for the pipeline.

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
builds the two extension images and loads them into kind, and deploys the
overlay. Each step is also a target of its own (`make prereqs`, `make kind`,
`make operators`, `make images`, `make deploy`), and running `setup-all` again
on a working cluster changes nothing. `make help` lists every target.

### Look at the data

Grafana is on http://localhost:3000, user `admin`, password `admin`. The
`PostgreSQL Unified Observability` dashboard shows each cluster's load,
latency, cache and disk activity and its statements by total time.
`PostgreSQL Query Detail` follows a single `query_id`: its latency, its
slowest traces with the span waterfall, and the server-log lines of the
selected trace. `Pipeline Health` shows the collectors' queues and failures
and ClickHouse's inserts.

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
its extensions, the workload, the correlation queries, Grafana and the
dashboards. Some suites disturb the cluster on purpose: they fail over
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

## Repository

| Path                    | Contents                                             |
| ----------------------- | ---------------------------------------------------- |
| `deploy/base`           | PostgreSQL clusters, collectors, ClickHouse, Grafana |
| `deploy/overlays/kind`  | Sizing, retention and NodePorts for kind             |
| `deploy/charts`         | Operator chart versions and values                   |
| `hack/kind`             | kind cluster definition                              |
| `images`, `images.txt`  | Extension image builds, pinned image list            |
| `scripts`               | Setup, deploy, chaos and correlation queries         |
| `test`                  | Smoke and resilience tests                           |
| `slides`                | Talk slides                                          |

## License

MIT. See [LICENSE](LICENSE).
