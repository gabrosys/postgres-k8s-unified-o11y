.PHONY: help prereqs kind cnpg build-image clickhouse otel pg-cluster workload grafana smoke chaos-degrade chaos-restore top-queries timeline drill setup-all teardown collector-logs agent-logs ch-logs ch-client

SHELL := /bin/bash
SCRIPTS_DIR := scripts

# Runs a command with the kubectl context and namespace pinned by _env.sh.
kctl = @source $(SCRIPTS_DIR)/_env.sh && $(1)

help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

prereqs: ## Check all prerequisites are installed
	@$(SCRIPTS_DIR)/00-prereqs-check.sh

kind: ## Create KIND cluster
	@$(SCRIPTS_DIR)/01-kind-create.sh

cnpg: ## Install CNPG operator
	@$(SCRIPTS_DIR)/02-install-cnpg.sh

build-image: ## Build PG 18 image with pg_tracing + pg_stat_ch, load into KIND
	@$(SCRIPTS_DIR)/03-build-load-image.sh

clickhouse: ## Deploy ClickHouse
	@$(SCRIPTS_DIR)/04-install-clickhouse.sh

otel: ## Deploy the OpenTelemetry gateway collector and log agent
	@$(SCRIPTS_DIR)/05-install-otel.sh

pg-cluster: ## Deploy CNPG PostgreSQL cluster
	@$(SCRIPTS_DIR)/06-deploy-pg-cluster.sh

workload: ## Build and deploy the instrumented workload client
	@$(SCRIPTS_DIR)/07-deploy-workload.sh

grafana: ## Install Grafana with the ClickHouse datasource
	@$(SCRIPTS_DIR)/08-install-grafana.sh

smoke: ## Validate the pipeline end to end
	@$(SCRIPTS_DIR)/09-smoke.sh

chaos-degrade: ## Drop the lookup index to force a plan regression
	@$(SCRIPTS_DIR)/chaos-degrade.sh

chaos-restore: ## Recreate the lookup index and re-analyze
	@$(SCRIPTS_DIR)/chaos-restore.sh

top-queries: ## Rank statements by total time (PG_CLUSTER, WINDOW_MIN)
	@$(SCRIPTS_DIR)/correlate.sh top

timeline: ## Per-minute events + metrics + traces for QUERY_ID=<id>
	@$(SCRIPTS_DIR)/correlate.sh timeline

drill: ## Spans + server log of TRACE_ID=<id> (or slowest trace of QUERY_ID=<id>)
	@$(SCRIPTS_DIR)/correlate.sh drill

setup-all: ## Run full setup
	@$(SCRIPTS_DIR)/setup-all.sh

collector-logs: ## Tail the gateway collector (blocking)
	$(call kctl,kubectl logs -n "$$NAMESPACE" -f deployment/otel-collector)

agent-logs: ## Tail the log-shipping agent (blocking)
	$(call kctl,kubectl logs -n "$$NAMESPACE" -f daemonset/otel-agent)

ch-logs: ## Tail ClickHouse (blocking)
	$(call kctl,kubectl logs -n "$$NAMESPACE" -f statefulset/clickhouse)

ch-client: ## Open an interactive clickhouse-client on the otel database
	$(call kctl,kubectl exec -it -n "$$NAMESPACE" statefulset/clickhouse -- clickhouse-client --database otel)

teardown: ## Tear down everything
	@$(SCRIPTS_DIR)/teardown.sh
