CLUSTER_NAME   := homelab
ARGOCD_VERSION := v2.12.7
K3S_VERSION    := v1.31.4-k3s1
WORKERS        ?= 0
MAX_WORKERS    := 5

.DEFAULT_GOAL := help

.PHONY: help check-tools create delete recreate status info install-argocd example-app \
        argocd-password argocd-set-password check-docker check-kubectl check-k3d

## Help

help:
	@echo "Usage: make <target> [WORKERS=N]"
	@echo ""
	@echo "Cluster"
	@echo "  create [WORKERS=N]  Create cluster + install ArgoCD (max WORKERS=$(MAX_WORKERS))"
	@echo "  delete              Destroy cluster"
	@echo "  recreate [WORKERS=N] Delete and recreate cluster"
	@echo ""
	@echo "Components"
	@echo "  install-argocd      Install ArgoCD into running cluster"
	@echo ""
	@echo "Apps"
	@echo "  example-app         Deploy nginx demo app"
	@echo ""
	@echo "Observability"
	@echo "  status              Cluster, node, and pod health"
	@echo "  info                Print access URLs and credentials"
	@echo "  argocd-password     Print ArgoCD admin password"
	@echo "  argocd-set-password NEW_PASSWORD=<pw>  Set ArgoCD admin password"
	@echo ""
	@echo "Toolchain"
	@echo "  check-tools         Verify all required tools are installed"

## Toolchain

check-tools: check-docker check-kubectl check-k3d
	@echo "All tools OK."
	@echo "  docker   : $$(docker --version)"
	@kubectl version --client 2>/dev/null | sed 's/^/  kubectl  : /'
	@echo "  k3d      : $$(k3d version | head -1)"

## Cluster lifecycle

create: check-docker check-kubectl check-k3d
	@if [ "$(WORKERS)" -gt "$(MAX_WORKERS)" ]; then \
		echo "Error: WORKERS=$(WORKERS) exceeds max $(MAX_WORKERS)"; exit 1; \
	fi
	k3d cluster create $(CLUSTER_NAME) \
		--port "80:80@loadbalancer" \
		--port "443:443@loadbalancer" \
		--agents $(WORKERS) \
		--image rancher/k3s:$(K3S_VERSION) \
		--volume "$(CURDIR)/cluster/traefik/helmchartconfig.yaml:/var/lib/rancher/k3s/server/manifests/traefik-config.yaml@server:0"
	@echo "Waiting for Traefik helm install..."
	kubectl wait --for=condition=complete job/helm-install-traefik -n kube-system --timeout=120s
	kubectl rollout status deployment/traefik -n kube-system --timeout=120s
	$(MAKE) install-argocd
	@echo ""
	$(MAKE) info

delete: check-k3d
	k3d cluster delete $(CLUSTER_NAME)

recreate: delete create

## Components

install-argocd: check-kubectl
	kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -n argocd -f cluster/argocd/install.yaml
	@echo "Waiting for ArgoCD server..."
	kubectl rollout status deployment/argocd-server -n argocd --timeout=180s
	kubectl patch deployment argocd-server -n argocd --patch-file cluster/argocd/server-insecure-patch.yaml
	kubectl apply -f cluster/argocd/ingress.yaml
	kubectl rollout status deployment/argocd-server -n argocd --timeout=60s

## Apps

example-app: check-kubectl
	kubectl apply -f apps/example-app/
	kubectl rollout status deployment/example-app -n default --timeout=60s
	@echo "Available at: http://example.localhost"

## Observability

status: check-kubectl
	@echo "=== Cluster ==="
	k3d cluster list
	@echo ""
	@echo "=== k3d proxy container ==="
	docker ps --filter name=k3d-$(CLUSTER_NAME)-serverlb --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
	@echo ""
	@echo "=== Nodes ==="
	kubectl get nodes -o wide
	@echo ""
	@echo "=== System pods ==="
	kubectl get pods -n kube-system
	@echo ""
	@echo "=== ArgoCD pods ==="
	kubectl get pods -n argocd 2>/dev/null || echo "(argocd not installed)"

info:
	@echo ""
	@echo "=== Access URLs ==="
	@echo "  Traefik Dashboard : http://traefik.localhost/dashboard/"
	@echo "  ArgoCD UI         : http://argocd.localhost"
	@echo "  Example App       : http://example.localhost  (run: make example-app)"
	@echo ""
	@echo "=== Credentials ==="
	@echo "  ArgoCD admin password: make argocd-password"

argocd-password: check-kubectl
	@echo "Username : admin"
	@printf "Password : "; kubectl get secret argocd-initial-admin-secret -n argocd \
		-o jsonpath="{.data.password}" | base64 -d; echo ""
	@echo "URL      : http://argocd.localhost"

argocd-set-password: check-kubectl
	@if [ -z "$(NEW_PASSWORD)" ]; then \
		echo "Usage: make argocd-set-password NEW_PASSWORD=<password>"; exit 1; \
	fi
	@CURRENT=$$(kubectl get secret argocd-initial-admin-secret -n argocd \
		-o jsonpath="{.data.password}" | base64 -d); \
	TOKEN=$$(curl -sf http://argocd.localhost/api/v1/session \
		-H "Content-Type: application/json" \
		-d "{\"username\":\"admin\",\"password\":\"$$CURRENT\"}" | \
		python3 -c "import sys,json; print(json.load(sys.stdin)['token'])"); \
	RESULT=$$(curl -sf http://argocd.localhost/api/v1/account/password \
		-H "Authorization: Bearer $$TOKEN" \
		-H "Content-Type: application/json" \
		-d "{\"currentPassword\":\"$$CURRENT\",\"newPassword\":\"$(NEW_PASSWORD)\"}"); \
	if [ "$$RESULT" = "{}" ]; then \
		echo "Password updated. Note: make argocd-password still shows the initial secret value."; \
	else \
		echo "Error: $$RESULT"; exit 1; \
	fi

## Pre-flight checks

check-docker:
	@docker info > /dev/null 2>&1 || (echo "Error: Docker is not running"; exit 1)

check-kubectl:
	@which kubectl > /dev/null 2>&1 || (echo "Error: kubectl not found. Run: brew install kubectl"; exit 1)

check-k3d:
	@which k3d > /dev/null 2>&1 || (echo "Error: k3d not found. Run: brew install k3d"; exit 1)
