# Unified Observability for PostgreSQL on Kubernetes

Demo infrastructure for the talk _"Unified Observability for PostgreSQL on
Kubernetes: Logs, Traces, and Metrics under One Roof."_

The setup stores logs, traces and metrics in ClickHouse that are obtained from independent CloudNativePG-managed PostgreSQL clusters
and queries them from Grafana through a single
datasource. A load generator instrumented with OpenTelemetry starts each trace
in the application and continues it inside PostgreSQL.

## Architecture

```
KIND cluster
├── namespace per PostgreSQL cluster
│   ├── load generator (OpenTelemetry Go SDK)
│   └── CloudNativePG cluster
│       ├── pg_tracing     spans
│       ├── pg_stat_ch     query events
│       └── server log     container stdout
└── namespace o11y
    ├── OpenTelemetry Collector agent (per node)   reads server logs
    ├── OpenTelemetry Collector gateway            receives OTLP, scrapes metrics
    ├── ClickHouse                                 stores all signals
    └── Grafana                                    queries ClickHouse
```

| Signal  | Source                       | Collection                       |
| ------- | ---------------------------- | -------------------------------- |
| Traces  | Load generator, `pg_tracing` | OTLP to the gateway              |
| Logs    | `pg_stat_ch` query events    | OTLP to the gateway              |
| Logs    | PostgreSQL server log        | Agent file tail, then OTLP       |
| Metrics | CloudNativePG, cAdvisor      | Prometheus scrape by the gateway |

Only the gateway connects to ClickHouse.

## Correlation

Traces and both log streams carry the PostgreSQL `query_id`. Join them on it:

```sql
otel_traces.SpanAttributes['query.query_id']
otel_logs.LogAttributes['query_id']   -- ServiceName = 'pg_stat_ch'
otel_logs.LogAttributes['query_id']   -- ServiceName = 'postgres-server-log'
```

This requires `compute_query_id` and statement logging. Outside a demo, log
statements above a duration threshold.

The `query_id` derives from the parse tree, so it stays the same when the
execution plan changes.

Metrics describe whole instances. Correlate them with other signals by time
and `k8s.pod.name`.

### Trace propagation

The load generator prepends a W3C `traceparent` as a SQL comment. `pg_tracing`
uses it as the parent of its spans, so one trace covers the client and the
server. The comment is placed first so that it does not appear in the
normalized query text.

A session can override the server-side sampling rate to trace every statement:

```sql
SET pg_tracing.sample_rate = 1.0;
```

## Prerequisites

- Docker
- KIND
- kubectl
- Helm
- curl

```bash
make prereqs
```

## Usage

```bash
make setup-all   # provision the full environment
make smoke       # validate the pipeline end to end
make help        # list individual steps
```

Deploy components in dependency order when running steps individually. Each
component must exist before the one that writes to it.

Grafana and ClickHouse are reachable from localhost.

```bash
make teardown
```

## Scenarios

### Latency attribution

Compare client-observed latency with PostgreSQL execution time per query shape.
The difference is network and connection pool overhead. It is constant across
shapes, so it dominates fast queries and is negligible for slow ones. Open a
trace to see the client span as the parent of the PostgreSQL spans.

### Statement ranking

Rank statements by total database time (`calls × mean time`) rather than by
tail latency. A rarely executed unindexed scan can account for most of the
database time while remaining invisible in instance-level metrics. Selecting a
statement filters traces, query events and server log entries by its `query_id`.

### Plan regression

```bash
make chaos-degrade   # drop the index used by the lookup query
make chaos-restore   # recreate the index and refresh statistics
```

Both commands print the plan and `query_id` for each cluster. After the index
is dropped, disk reads and execution time of the lookup increase. The statement
keeps its `query_id`, so the regression appears as a change in one row and the
correlated traces, events and logs remain joinable.

## License

MIT. See [LICENSE](LICENSE).
