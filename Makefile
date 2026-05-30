CLUSTER_NAME          := homelab
ARGOCD_VERSION        := v2.12.7
SEALED_SECRETS_VERSION := v0.37.0
K3S_VERSION           := v1.31.4-k3s1
WORKERS        ?= 0
MAX_WORKERS    := 5
REPO_URL       := $(shell git remote get-url origin 2>/dev/null | sed 's|git@github.com:|https://github.com/|; s|\.git$$||')
ARGOCD_PASSWORD ?= $(shell kubectl get secret argocd-initial-admin-secret -n argocd \
	-o jsonpath="{.data.password}" 2>/dev/null | base64 -d)

-include local/.env

K3D_LOCAL_CONFIG := $(wildcard local/k3d-config.yaml)
K3D_CONFIG_FLAGS := --config k3d-config.yaml $(if $(K3D_LOCAL_CONFIG),--config $(K3D_LOCAL_CONFIG))

.DEFAULT_GOAL := help

.PHONY: help check-tools create delete recreate scale add-worker status info \
        argocd-password argocd-set-password argocd-add-repo argocd-list-repos argocd-list-apps \
        kubeseal-cert \
        check-docker check-kubectl check-k3d check-kubeseal

## Help

help:
	@echo "Usage: make <target> [OPTION=value]"
	@echo ""
	@echo "Cluster"
	@echo "  create [WORKERS=N]   Create cluster + bootstrap ArgoCD (max WORKERS=$(MAX_WORKERS))"
	@echo "  delete               Destroy cluster"
	@echo "  recreate [WORKERS=N] Delete and recreate cluster"
	@echo "  scale WORKERS=N      Set total agent (worker) count"
	@echo "  add-worker           Add one agent to running cluster"
	@echo ""
	@echo "Observability"
	@echo "  status               Cluster, node, and pod health"
	@echo "  info                 Print access URLs"
	@echo ""
	@echo "ArgoCD"
	@echo "  argocd-password                          Print admin credentials"
	@echo "  argocd-set-password NEW_PASSWORD=<pw>    Set admin password"
	@echo "  argocd-add-repo REPO=<url> [TOKEN=<tok>] Register an app repo"
	@echo "  argocd-list-repos                        List registered repos"
	@echo "  argocd-list-apps                         List apps and sync status"
	@echo ""
	@echo "Sealed Secrets"
	@echo "  kubeseal-cert        Fetch controller public cert to local/sealed-secrets-cert.pem"
	@echo ""
	@echo "Toolchain"
	@echo "  check-tools          Verify all required tools are installed"

## Toolchain

check-tools: check-docker check-kubectl check-k3d
	@echo "All tools OK."
	@echo "  docker   : $$(docker --version)"
	@kubectl version --client 2>/dev/null | sed 's/^/  kubectl  : /'
	@echo "  k3d      : $$(k3d version | head -1)"
	@if which kubeseal > /dev/null 2>&1; then \
		echo "  kubeseal : $$(kubeseal --version 2>&1)"; \
	else \
		echo "  kubeseal : not installed (optional — needed for make kubeseal-cert)"; \
	fi

## Cluster lifecycle

create: check-docker check-kubectl check-k3d
	@if [ "$(WORKERS)" -gt "$(MAX_WORKERS)" ]; then \
		echo "Error: WORKERS=$(WORKERS) exceeds max $(MAX_WORKERS)"; exit 1; \
	fi
	@if [ -z "$(REPO_URL)" ]; then \
		echo "Error: could not detect repo URL from git remote"; exit 1; \
	fi
	k3d cluster create $(K3D_CONFIG_FLAGS) --agents $(WORKERS) \
		--volume "$(CURDIR)/cluster/traefik/helmchartconfig.yaml:/var/lib/rancher/k3s/server/manifests/traefik-config.yaml@server:0"
	@echo "Waiting for Traefik..."
	kubectl wait --for=condition=complete job/helm-install-traefik -n kube-system --timeout=120s
	kubectl rollout status deployment/traefik -n kube-system --timeout=120s
	@echo "Installing Sealed Secrets..."
	kubectl apply -f bootstrap/sealed-secrets.yaml
	kubectl rollout status deployment/sealed-secrets-controller -n kube-system --timeout=120s
	@echo "Installing ArgoCD..."
	kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -n argocd -f bootstrap/argocd-install.yaml
	kubectl rollout status deployment/argocd-server -n argocd --timeout=180s
	@echo "Patching ArgoCD for insecure mode..."
	kubectl patch deployment argocd-server -n argocd --patch-file bootstrap/server-insecure-patch.yaml
	kubectl rollout status deployment/argocd-server -n argocd --timeout=60s
	kubectl apply -f bootstrap/argocd-ingress.yaml
	@echo "Applying root Application..."
	sed 's|REPO_URL_PLACEHOLDER|$(REPO_URL)|g' bootstrap/argocd-root-app.yaml | kubectl apply -f -
	@echo ""
	$(MAKE) info

delete: check-k3d
	k3d cluster delete $(CLUSTER_NAME)

recreate: delete create

scale: check-k3d check-kubectl
	@if [ -z "$(WORKERS)" ]; then \
		echo "Usage: make scale WORKERS=N"; exit 1; \
	fi
	@if [ "$(WORKERS)" -gt "$(MAX_WORKERS)" ]; then \
		echo "Error: WORKERS=$(WORKERS) exceeds max $(MAX_WORKERS)"; exit 1; \
	fi
	@CURRENT=$$(kubectl get nodes --no-headers 2>/dev/null | grep -v "control-plane" | wc -l | tr -d ' '); \
	TARGET=$(WORKERS); \
	if [ "$$TARGET" -gt "$$CURRENT" ]; then \
		ADD=$$((TARGET - CURRENT)); \
		echo "Adding $$ADD agent(s) ($$CURRENT → $$TARGET)..."; \
		for i in $$(seq $$CURRENT $$((TARGET - 1))); do \
			k3d node create $(CLUSTER_NAME)-agent-$$i --cluster $(CLUSTER_NAME); \
		done; \
	elif [ "$$TARGET" -lt "$$CURRENT" ]; then \
		echo "Error: scaling down not supported — use 'make recreate WORKERS=$(WORKERS)'"; exit 1; \
	else \
		echo "Already at $$CURRENT agent(s), nothing to do."; \
	fi

add-worker: check-k3d check-kubectl
	@CURRENT=$$(kubectl get nodes --no-headers 2>/dev/null | grep -v "control-plane" | wc -l | tr -d ' '); \
	$(MAKE) scale WORKERS=$$((CURRENT + 1))

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
	@echo "=== ArgoCD apps ==="
	kubectl get applications -n argocd 2>/dev/null || echo "(no applications found)"

info:
	@echo ""
	@echo "=== Access URLs ==="
	@echo "  Traefik Dashboard : http://traefik.localhost/dashboard/"
	@echo "  ArgoCD UI         : http://argocd.localhost"
	@echo ""
	@echo "=== ArgoCD Credentials ==="
	@echo "  Username : admin"
	@printf "  Password : "; kubectl get secret argocd-initial-admin-secret -n argocd \
		-o jsonpath="{.data.password}" 2>/dev/null | base64 -d; echo ""

## ArgoCD

argocd-password: check-kubectl
	@echo "Username : admin"
	@printf "Password : "; kubectl get secret argocd-initial-admin-secret -n argocd \
		-o jsonpath="{.data.password}" | base64 -d; echo ""
	@echo "URL      : http://argocd.localhost"

argocd-set-password: check-kubectl
	@if [ -z "$(NEW_PASSWORD)" ]; then \
		echo "Usage: make argocd-set-password NEW_PASSWORD=<password>"; exit 1; \
	fi
	@TOKEN=$$(curl -sf http://argocd.localhost/api/v1/session \
		-H "Content-Type: application/json" \
		-d "{\"username\":\"admin\",\"password\":\"$(ARGOCD_PASSWORD)\"}" | \
		python3 -c "import sys,json; print(json.load(sys.stdin)['token'])"); \
	RESULT=$$(curl -sf -X PUT http://argocd.localhost/api/v1/account/password \
		-H "Authorization: Bearer $$TOKEN" \
		-H "Content-Type: application/json" \
		-d "{\"currentPassword\":\"$(ARGOCD_PASSWORD)\",\"newPassword\":\"$(NEW_PASSWORD)\"}"); \
	if [ "$$RESULT" = "{}" ]; then \
		echo "Password updated."; \
	else \
		echo "Error: $$RESULT"; exit 1; \
	fi

argocd-add-repo: check-kubectl
	@if [ -z "$(REPO)" ]; then \
		echo "Usage: make argocd-add-repo REPO=<url> [TOKEN=<token>]"; exit 1; \
	fi
	@TOKEN=$$(curl -sf http://argocd.localhost/api/v1/session \
		-H "Content-Type: application/json" \
		-d "{\"username\":\"admin\",\"password\":\"$(ARGOCD_PASSWORD)\"}" | \
		python3 -c "import sys,json; print(json.load(sys.stdin)['token'])"); \
	if [ -n "$(TOKEN)" ]; then \
		PAYLOAD="{\"repo\":\"$(REPO)\",\"username\":\"git\",\"password\":\"$(TOKEN)\"}"; \
	else \
		PAYLOAD="{\"repo\":\"$(REPO)\"}"; \
	fi; \
	RESULT=$$(curl -sf -X POST http://argocd.localhost/api/v1/repositories \
		-H "Authorization: Bearer $$TOKEN" \
		-H "Content-Type: application/json" \
		-d "$$PAYLOAD"); \
	echo "$$RESULT" | python3 -c "import sys,json; r=json.load(sys.stdin); print('Registered:', r.get('repo','?'))"

argocd-list-repos: check-kubectl
	@TOKEN=$$(curl -sf http://argocd.localhost/api/v1/session \
		-H "Content-Type: application/json" \
		-d "{\"username\":\"admin\",\"password\":\"$(ARGOCD_PASSWORD)\"}" | \
		python3 -c "import sys,json; print(json.load(sys.stdin)['token'])"); \
	curl -sf http://argocd.localhost/api/v1/repositories \
		-H "Authorization: Bearer $$TOKEN" | \
		python3 -c "import sys,json; repos=json.load(sys.stdin).get('items') or []; [print('No repositories registered.') if not repos else None]; [print(f\"  {r.get('repo','?')}  [{'OK' if r.get('connectionState',{}).get('status')=='Successful' else r.get('connectionState',{}).get('status','?')}]\") for r in repos]"

argocd-list-apps: check-kubectl
	@TOKEN=$$(curl -sf http://argocd.localhost/api/v1/session \
		-H "Content-Type: application/json" \
		-d "{\"username\":\"admin\",\"password\":\"$(ARGOCD_PASSWORD)\"}" | \
		python3 -c "import sys,json; print(json.load(sys.stdin)['token'])"); \
	curl -sf http://argocd.localhost/api/v1/applications \
		-H "Authorization: Bearer $$TOKEN" | \
		python3 -c "import sys,json; apps=json.load(sys.stdin).get('items') or []; [print('No applications found.') if not apps else (print(f\"  {'NAME':<25} {'SYNC':<12} HEALTH\"), print(f\"  {'-'*25} {'-'*12} {'-'*10}\"), [print(f\"  {a.get('metadata',{}).get('name','?'):<25} {a.get('status',{}).get('sync',{}).get('status','?'):<12} {a.get('status',{}).get('health',{}).get('status','?')}\") for a in apps])]"

## Sealed Secrets

kubeseal-cert: check-kubectl
	@which kubeseal > /dev/null 2>&1 || (echo "Error: kubeseal not found. Run: brew install kubeseal"; exit 1)
	kubeseal --fetch-cert \
		--controller-name=sealed-secrets-controller \
		--controller-namespace=kube-system \
		> local/sealed-secrets-cert.pem
	@echo "Cert saved to local/sealed-secrets-cert.pem"
	@echo "Encrypt a secret: kubeseal --cert local/sealed-secrets-cert.pem -f secret.yaml -w sealed-secret.yaml"

## Pre-flight checks

check-docker:
	@docker info > /dev/null 2>&1 || (echo "Error: Docker is not running"; exit 1)

check-kubectl:
	@which kubectl > /dev/null 2>&1 || (echo "Error: kubectl not found. Run: brew install kubectl"; exit 1)

check-k3d:
	@which k3d > /dev/null 2>&1 || (echo "Error: k3d not found. Run: brew install k3d"; exit 1)

check-kubeseal:
	@which kubeseal > /dev/null 2>&1 || (echo "Error: kubeseal not found. Run: brew install kubeseal"; exit 1)
