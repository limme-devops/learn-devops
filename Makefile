# Author: Mengty LIM
.DEFAULT_GOAL := help
SHELL := /bin/bash
ENV ?= dev
TF_DIR := infra/terraform/environments/$(ENV)
ANSIBLE_DIR := infra/ansible

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | sort | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-24s\033[0m %s\n", $$1, $$2}'

## ---------- quality gates (same as CI) ----------

.PHONY: lint
lint: lint-tf lint-ansible lint-k8s ## Run all linters

.PHONY: lint-tf
lint-tf: ## terraform fmt + validate + tflint
	terraform -chdir=infra/terraform fmt -check -recursive
	cd $(TF_DIR) && terraform init -backend=false && terraform validate
	cd infra/terraform && tflint --recursive

.PHONY: lint-ansible
lint-ansible: ## ansible-lint + syntax check
	cd $(ANSIBLE_DIR) && ansible-lint
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventories/$(ENV)/hosts.yml playbooks/site.yml --syntax-check

.PHONY: lint-k8s
lint-k8s: ## Render kustomize overlays and lint them
	@for o in gitops/business/*/overlays/*; do \
	  echo "--> $$o"; kustomize build $$o | kube-linter lint - || exit 1; \
	done

.PHONY: scan
scan: ## Security scans: secrets, IaC, filesystem
	gitleaks detect --source=. --redact --verbose
	checkov -d infra/terraform --framework terraform --quiet --compact
	trivy config infra/ gitops/ --severity HIGH,CRITICAL --exit-code 1
	trivy fs apps/ --scanners vuln,secret --severity HIGH,CRITICAL --exit-code 1

## ---------- terraform ----------

.PHONY: tf-plan
tf-plan: ## Plan infra for ENV (default dev)
	cd $(TF_DIR) && terraform init -input=false && terraform plan -input=false -out=tfplan

.PHONY: tf-apply
tf-apply: ## Apply the previously reviewed plan for ENV
	@test -f $(TF_DIR)/tfplan || { echo "No tfplan — run 'make tf-plan ENV=$(ENV)' first"; exit 1; }
	cd $(TF_DIR) && terraform apply -input=false tfplan

## ---------- ansible ----------

.PHONY: ansible-check
ansible-check: ## Dry-run the full converge (always do this before apply)
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventories/$(ENV)/hosts.yml playbooks/site.yml --check --diff

.PHONY: ansible-apply
ansible-apply: ## Converge hosts for ENV
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventories/$(ENV)/hosts.yml playbooks/site.yml

.PHONY: ansible-idempotence
ansible-idempotence: ## Run twice; second run must report zero changes
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventories/$(ENV)/hosts.yml playbooks/site.yml
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventories/$(ENV)/hosts.yml playbooks/site.yml | tee /tmp/second.log
	@! grep -qE 'changed=[1-9]' /tmp/second.log || { echo "NOT IDEMPOTENT"; exit 1; }

## ---------- gitops ----------

.PHONY: render
render: ## Render a service's overlay (make render SVC=payment-service ENV=prod)
	kustomize build gitops/business/$(SVC)/overlays/$(ENV)

.PHONY: diff
diff: ## Diff an overlay against the live cluster
	kustomize build gitops/business/$(SVC)/overlays/$(ENV) | kubectl diff -f - || true

## ---------- local lab ----------

.PHONY: lab-up
lab-up: ## Create the local kind cluster + platform baseline
	kind create cluster --config local-lab/kind-cluster.yaml
	./local-lab/bootstrap.sh

.PHONY: lab-down
lab-down: ## Destroy the local lab
	kind delete cluster --name learn-devops
