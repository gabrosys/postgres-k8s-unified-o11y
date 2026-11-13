.PHONY: help prereqs lint kind operators images deploy smoke resilience chaos-degrade chaos-restore top-queries timeline drill setup-all teardown ch-client

SHELL := /bin/bash
SCRIPTS_DIR := scripts

help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

prereqs: ## Check all prerequisites are installed
	@$(SCRIPTS_DIR)/prereqs.sh

lint: ## Validate rendered manifests for every overlay
	@test/lint.sh

kind: ## Create KIND cluster
	@$(SCRIPTS_DIR)/kind-create.sh

operators: ## Install operators from pinned Helm charts
	@$(SCRIPTS_DIR)/install-operators.sh

images: ## Build the extension images, load them into KIND
	@$(SCRIPTS_DIR)/build-images.sh

deploy: ## Apply the Kustomize overlay (OVERLAY, default kind) and wait for it
	@$(SCRIPTS_DIR)/deploy.sh

smoke: ## Run every test suite except resilience
	@test/smoke.sh

resilience: ## Restart and stop pipeline components under load, check nothing is lost
	@test/resilience.sh

chaos-degrade: ## Apply a planner override to every cluster
	@$(SCRIPTS_DIR)/chaos-degrade.sh

chaos-restore: ## Remove the planner override
	@$(SCRIPTS_DIR)/chaos-restore.sh

top-queries: ## Rank statements by total time (PG_CLUSTER, WINDOW_MIN)
	@$(SCRIPTS_DIR)/correlate.sh top

timeline: ## Per-minute events + metrics + traces for QUERY_ID=<id>
	@$(SCRIPTS_DIR)/correlate.sh timeline

drill: ## Spans + server log of TRACE_ID=<id> (or slowest trace of QUERY_ID=<id>)
	@$(SCRIPTS_DIR)/correlate.sh drill

setup-all: ## Run full setup
	@$(SCRIPTS_DIR)/setup-all.sh

ch-client: ## Open an interactive clickhouse-client on the otel database
	@source $(SCRIPTS_DIR)/env.sh && kubectl exec -it -n "$$NAMESPACE" "$$(ch_pod)" -c clickhouse -- clickhouse-client --database otel

teardown: ## Tear down everything
	@$(SCRIPTS_DIR)/teardown.sh
