.DEFAULT_GOAL := help

# Override on the command line if your interpreter has a different name,
# e.g. `make test PYTHON=python3.12`
PYTHON ?= python3
PIP    := $(PYTHON) -m pip
PYTEST := $(PYTHON) -m pytest
RUFF   := $(PYTHON) -m ruff
IMAGE  := careguide-devops-app
TAG    := $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)

.PHONY: help install lint format test test-cov build up down monitoring-up monitoring-down clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

install: ## Install development dependencies
	$(PIP) install -e ".[dev]"

lint: ## Run ruff linter
	$(RUFF) check app/ tests/

format: ## Auto-format with ruff
	$(RUFF) format app/ tests/

test: ## Run unit tests (no coverage)
	PYTHONPATH=. $(PYTEST) tests/ -v --no-cov

test-cov: ## Run unit tests with coverage report
	PYTHONPATH=. $(PYTEST) tests/ -v

build: ## Build Docker image
	docker build --tag $(IMAGE):$(TAG) .
	docker image inspect $(IMAGE):$(TAG) --format "Built: {{.Id}} Size: {{.Size}} bytes"

up: ## Start application via Docker Compose
	docker compose up --build --detach
	@echo "Application running at http://localhost:8080"

down: ## Stop application
	docker compose down

monitoring-up: ## Start observability stack
	docker compose --file docker-compose.monitoring.yml up --detach
	@echo "Grafana available at http://localhost:3000 (admin/change_me_before_deploy)"

monitoring-down: ## Stop observability stack
	docker compose --file docker-compose.monitoring.yml down

clean: ## Remove stopped containers and dangling images
	docker compose down --remove-orphans
	docker compose --file docker-compose.monitoring.yml down --remove-orphans
	docker image prune --force

