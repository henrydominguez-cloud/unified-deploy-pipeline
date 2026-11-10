# Local helpers. They call the same scripts/ci/*.sh as the pipeline, so
# what you render or deploy here is exactly what CI does.
export APP_DIR ?= examples/sample-app
export APP_NAME ?= sample-app
ENV     ?= develop
# ENV -> branch the scripts understand (main = production)
export REF_NAME := $(if $(filter production,$(ENV)),main,develop)
PLAN    := sh scripts/ci/setup.sh >/dev/null && set -a && . ./setup.env && set +a
# kind targets NEVER use your current kubectl context (could be a real cluster)
KIND_NAME ?= unified-pipeline
KIND_KCFG := .kind-kubeconfig
KIND    := KUBECONFIG=$(KIND_KCFG)

.PHONY: help doctor preflight hooks test test-scripts lint render sanitize e2e kind-up kind-deploy kind-check kind-down

help:  ## List targets
	@grep -E '^[a-z0-9-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

doctor:  ## Check the tools this repo needs are installed
	sh scripts/doctor.sh

preflight:  ## ALL checks before git push (SKIP_E2E=1 to skip the kind test)
	sh scripts/preflight.sh

hooks:  ## Install a git pre-push hook (sanitize + script tests)
	git config core.hooksPath scripts/hooks
	@echo "pre-push hook active (scripts/hooks/pre-push)"

test:  ## Run sample-app unit tests
	cd $(APP_DIR) && python3 -m pytest -q

test-scripts:  ## Test scripts/ci with fake helm/kubectl (no cluster)
	sh tests/ci-scripts.sh

lint:  ## yamllint + shellcheck
	yamllint -c .yamllint .
	shellcheck -s sh scripts/ci/*.sh scripts/doctor.sh scripts/preflight.sh scripts/hooks/pre-push tests/*.sh
	shellcheck scripts/check-sanitized.sh

render:  ## helm lint + render with the values chain (ENV=develop|production)
	$(PLAN) && NEW_TAG=local sh scripts/ci/render.sh && cat rendered.yaml

sanitize:  ## Check for secrets and private terms before pushing
	bash scripts/check-sanitized.sh .

e2e:  ## Real test of the 4 modes on kind (creates the cluster if missing)
	KIND_CLUSTER=$(KIND_NAME) sh tests/e2e-kind.sh

kind-up:  ## Create a local kind cluster
	kind get clusters | grep -qx $(KIND_NAME) || kind create cluster --name $(KIND_NAME)
	kind get kubeconfig --name $(KIND_NAME) > $(KIND_KCFG)

kind-deploy: kind-up  ## Build with docker, load into kind, deploy with deploy.sh
	$(PLAN) && export IMAGE_REPOSITORY=sample-app NEW_TAG=local DEPLOYMENT_MODE=full && \
	  BUILDER=docker PUSH=false sh scripts/ci/build.sh && \
	  kind load docker-image sample-app:local --name $(KIND_NAME) && \
	  $(KIND) sh scripts/ci/deploy.sh

kind-check:  ## Call the deployed app through a port-forward
	$(KIND) kubectl -n $(ENV) port-forward svc/$(APP_NAME) 8080:80 >/dev/null & \
	  PF=$$!; sleep 2; curl -fsS localhost:8080/; echo; kill $$PF

kind-down:  ## Delete the kind cluster (removes everything)
	kind delete cluster --name $(KIND_NAME)
	rm -f $(KIND_KCFG)
