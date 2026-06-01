CLUSTER_NAME           := homelab
ARGOCD_VERSION         ?= v3.4.3
SEALED_SECRETS_VERSION ?= v0.37.0
CERT_MANAGER_VERSION   ?= v1.20.2
K3S_VERSION            ?= v1.36.1-k3s1
WORKERS                ?= 0
MAX_WORKERS            := 5
REPO_URL               := $(shell git remote get-url origin 2>/dev/null | sed 's|git@github.com:|https://github.com/|; s|\.git$$||')
ARGOCD_PASSWORD        ?= $(shell kubectl get secret argocd-initial-admin-secret -n argocd \
	-o jsonpath="{.data.password}" 2>/dev/null | base64 -d)
ARGOCD_DESIRED_PASSWORD ?=

-include local/.env

K3D_LOCAL_CONFIG := $(wildcard local/k3d-config.yaml)
K3D_CONFIG_FLAGS := --config k3d-config.yaml $(if $(K3D_LOCAL_CONFIG),--config $(K3D_LOCAL_CONFIG))

.DEFAULT_GOAL := help

.PHONY: help check-tools create delete recreate scale add-worker status info \
        argocd-password argocd-set-password argocd-add-repo argocd-list-repos argocd-list-apps \
        headlamp-token update-manifests \
        seal sealed-secrets-backup kubeseal-cert ca-generate ca-trust \
        check-docker check-kubectl check-k3d check-kubeseal

## Help

help:
	@echo "Usage: make <target> [OPTION=value]"
	@echo ""
	@echo "Cluster"
	@echo "  create [WORKERS=N]   Create cluster + bootstrap all components (max WORKERS=$(MAX_WORKERS))"
	@echo "  delete               Destroy cluster"
	@echo "  recreate [WORKERS=N] Delete and recreate cluster"
	@echo "  scale WORKERS=N      Set total agent (worker) count"
	@echo "  add-worker           Add one agent to running cluster"
	@echo ""
	@echo "Observability"
	@echo "  status               Cluster, node, and pod health"
	@echo "  info                 Print access URLs and credentials"
	@echo ""
	@echo "TLS"
	@echo "  ca-generate          Generate CA keypair → local/ca.crt + local/ca.key"
	@echo "  ca-trust             Trust local CA in macOS Keychain (sudo)"
	@echo ""
	@echo "ArgoCD"
	@echo "  argocd-password                          Print admin credentials"
	@echo "  argocd-set-password NEW_PASSWORD=<pw>    Set admin password (saves to local/.env)"
	@echo "  argocd-add-repo REPO=<url> [TOKEN=<tok>] Register an app repo (saves to local/argocd-repos/)"
	@echo "  argocd-list-repos                        List registered repos"
	@echo "  argocd-list-apps                         List apps and sync status"
	@echo "  Tip: set ARGOCD_DESIRED_PASSWORD in local/.env to restore password on recreate"
	@echo "  Tip: place configmap patches in local/argocd-config/ to restore on recreate"
	@echo ""
	@echo "Sealed Secrets"
	@echo "  seal NAME=<name> [NAMESPACE=<ns>]  Seal local/secrets/<name>.env → apps/<name>-sealed-secret.yaml"
	@echo "  sealed-secrets-backup              Back up controller keypair → local/sealed-secrets-key.json"
	@echo "  kubeseal-cert                      Fetch controller public cert → local/sealed-secrets-cert.pem"
	@echo ""
	@echo "Headlamp"
	@echo "  headlamp-token       Print a Headlamp login token (valid 1 year)"
	@echo ""
	@echo "Manifests"
	@echo "  update-manifests     Re-fetch bootstrap manifests from GitHub at current version pins"
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
	@if [ ! -f local/ca.crt ] || [ ! -f local/ca.key ]; then \
		echo "No CA found in local/ — generating one..."; \
		$(MAKE) ca-generate; \
	fi
	@mkdir -p $(CURDIR)/local/data/volumes
	k3d cluster create $(K3D_CONFIG_FLAGS) --agents $(WORKERS) \
		--volume "$(CURDIR)/cluster/traefik/helmchartconfig.yaml:/var/lib/rancher/k3s/server/manifests/traefik-config.yaml@server:0" \
		--volume "$(CURDIR)/local/data:/mnt/data@server:*;agent:*"
	@echo "Waiting for Traefik..."
	until kubectl get job/helm-install-traefik-crd job/helm-install-traefik -n kube-system >/dev/null 2>&1; do sleep 2; done
	kubectl wait --for=condition=complete job/helm-install-traefik-crd job/helm-install-traefik -n kube-system --timeout=120s
	kubectl rollout status deployment/traefik -n kube-system --timeout=120s
	@echo "Configuring persistent storage..."
	kubectl apply -f bootstrap/local-path-config.yaml
	kubectl rollout restart deployment/local-path-provisioner -n kube-system
	kubectl rollout status deployment/local-path-provisioner -n kube-system --timeout=60s
	@if [ -f local/sealed-secrets-key.json ]; then \
		echo "Restoring Sealed Secrets key..."; \
		kubectl apply -f local/sealed-secrets-key.json; \
	fi
	@echo "Installing cert-manager..."
	kubectl apply -f bootstrap/cert-manager.yaml
	@echo "Waiting for cert-manager..."
	kubectl rollout status deployment/cert-manager -n cert-manager --timeout=120s
	kubectl rollout status deployment/cert-manager-webhook -n cert-manager --timeout=120s
	kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=webhook -n cert-manager --timeout=120s
	@echo "Loading CA..."
	kubectl create secret tls localhost-ca-secret \
		--cert=local/ca.crt --key=local/ca.key \
		-n cert-manager --dry-run=client -o yaml | kubectl apply -f -
	@echo "Installing ArgoCD..."
	kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply --server-side -n argocd -f bootstrap/argocd-install.yaml
	kubectl patch configmap argocd-cmd-params-cm -n argocd --patch '{"data":{"server.insecure":"true"}}'
	kubectl rollout status deployment/argocd-server -n argocd --timeout=180s
	@if ls local/argocd-repos/*.yaml >/dev/null 2>&1; then \
		echo "Restoring ArgoCD repository credentials..."; \
		kubectl apply -f local/argocd-repos/; \
	fi
	@if ls local/argocd-config/*.yaml >/dev/null 2>&1; then \
		echo "Restoring ArgoCD configuration..."; \
		kubectl apply -f local/argocd-config/; \
	fi
	@if [ -n "$(ARGOCD_DESIRED_PASSWORD)" ]; then \
		echo "Waiting for ArgoCD ingress..."; \
		until kubectl get ingress argocd-server-ingress -n argocd >/dev/null 2>&1; do sleep 5; done; \
		sleep 3; \
		echo "Setting ArgoCD admin password..."; \
		INITIAL_PW=$$(kubectl get secret argocd-initial-admin-secret -n argocd \
			-o jsonpath="{.data.password}" | base64 -d); \
		TOKEN=$$(curl -sf http://argocd.localhost/api/v1/session \
			-H "Content-Type: application/json" \
			-d "{\"username\":\"admin\",\"password\":\"$$INITIAL_PW\"}" | \
			python3 -c "import sys,json; print(json.load(sys.stdin)['token'])"); \
		RESULT=$$(curl -sf -X PUT http://argocd.localhost/api/v1/account/password \
			-H "Authorization: Bearer $$TOKEN" \
			-H "Content-Type: application/json" \
			-d "{\"currentPassword\":\"$$INITIAL_PW\",\"newPassword\":\"$(ARGOCD_DESIRED_PASSWORD)\"}"); \
		if [ "$$RESULT" = "{}" ]; then \
			echo "Password set."; \
			kubectl patch secret argocd-initial-admin-secret -n argocd \
				-p "{\"data\":{\"password\":\"$$(printf '%s' '$(ARGOCD_DESIRED_PASSWORD)' | base64)\"}}" > /dev/null; \
		else \
			echo "Warning: failed to set password: $$RESULT"; \
		fi; \
	fi
	@echo "Applying root Application..."
	sed 's|REPO_URL_PLACEHOLDER|$(REPO_URL)|g' bootstrap/argocd-root-app.yaml | kubectl apply -f -
	@echo "Waiting for Sealed Secrets controller (ArgoCD will install it)..."
	@until kubectl get deployment sealed-secrets-controller -n kube-system >/dev/null 2>&1; do sleep 5; done
	@kubectl rollout status deployment/sealed-secrets-controller -n kube-system --timeout=180s
	@echo "Backing up Sealed Secrets key..."
	@until kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key=active --no-headers 2>/dev/null | grep -q .; do sleep 2; done
	@kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key=active -o json | \
		python3 -c "import sys,json; obj=json.load(sys.stdin); strip=['resourceVersion','uid','creationTimestamp','managedFields','selfLink','generation','annotations']; [[m.pop(f,None) for f in strip] for item in obj.get('items',[]) for m in [item.get('metadata',{})]]; print(json.dumps(obj,indent=2))" \
		> local/sealed-secrets-key.json
	@echo "Key backed up to local/sealed-secrets-key.json"
	@if which kubeseal > /dev/null 2>&1; then \
		kubeseal --fetch-cert \
			--controller-name=sealed-secrets-controller \
			--controller-namespace=kube-system \
			> local/sealed-secrets-cert.pem; \
		echo "Cert saved to local/sealed-secrets-cert.pem"; \
	else \
		echo "kubeseal not installed — skipping cert fetch (run: brew install kubeseal && make kubeseal-cert)"; \
	fi
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
	@echo "  ArgoCD UI         : https://argocd.localhost"
	@echo "  Headlamp          : https://headlamp.localhost"
	@echo ""
	@echo "=== ArgoCD Credentials ==="
	@echo "  Username : admin"
	@printf "  Password : "; kubectl get secret argocd-initial-admin-secret -n argocd \
		-o jsonpath="{.data.password}" 2>/dev/null | base64 -d; echo ""
	@echo ""
	@echo "=== Headlamp Token ==="
	@kubectl create token headlamp -n headlamp --duration=8760h 2>/dev/null || echo "  (headlamp not yet deployed)"

## TLS

ca-generate:
	@mkdir -p local
	openssl genrsa -out local/ca.key 4096
	openssl req -new -x509 -key local/ca.key \
		-out local/ca.crt \
		-days 3650 \
		-subj "/CN=k3d-homelab-ca/O=k3d-homelab"
	@echo "CA generated at local/ca.crt and local/ca.key"
	@echo "Run 'make ca-trust' to trust it in macOS Keychain"

ca-trust:
	@if [ ! -f local/ca.crt ]; then \
		echo "Error: local/ca.crt not found. Run: make ca-generate"; exit 1; \
	fi
	sudo security add-trusted-cert -d -r trustRoot \
		-k /Library/Keychains/System.keychain \
		local/ca.crt
	@echo "CA trusted. Restart your browser for changes to take effect."

## ArgoCD

argocd-password: check-kubectl
	@echo "Username : admin"
	@printf "Password : "; kubectl get secret argocd-initial-admin-secret -n argocd \
		-o jsonpath="{.data.password}" | base64 -d; echo ""
	@echo "URL      : https://argocd.localhost"

argocd-set-password: check-kubectl
	@NEW_PASSWORD="$(NEW_PASSWORD)"; \
	if [ -z "$$NEW_PASSWORD" ]; then \
		printf "New password: "; \
		read -rs NEW_PASSWORD; echo; \
		printf "Confirm password: "; \
		read -rs CONFIRM; echo; \
		if [ "$$NEW_PASSWORD" != "$$CONFIRM" ]; then \
			echo "Passwords do not match."; exit 1; \
		fi; \
	fi; \
	TOKEN=$$(curl -sf http://argocd.localhost/api/v1/session \
		-H "Content-Type: application/json" \
		-d "{\"username\":\"admin\",\"password\":\"$(ARGOCD_PASSWORD)\"}" | \
		python3 -c "import sys,json; print(json.load(sys.stdin)['token'])"); \
	RESULT=$$(curl -sf -X PUT http://argocd.localhost/api/v1/account/password \
		-H "Authorization: Bearer $$TOKEN" \
		-H "Content-Type: application/json" \
		-d "{\"currentPassword\":\"$(ARGOCD_PASSWORD)\",\"newPassword\":\"$$NEW_PASSWORD\"}"); \
	if [ "$$RESULT" = "{}" ]; then \
		echo "Password updated."; \
		kubectl patch secret argocd-initial-admin-secret -n argocd \
			-p "{\"data\":{\"password\":\"$$(printf '%s' "$$NEW_PASSWORD" | base64)\"}}" > /dev/null; \
		if grep -q '^ARGOCD_DESIRED_PASSWORD=' local/.env 2>/dev/null; then \
			sed -i '' "s|^ARGOCD_DESIRED_PASSWORD=.*|ARGOCD_DESIRED_PASSWORD=$$NEW_PASSWORD|" local/.env; \
		else \
			printf '\nARGOCD_DESIRED_PASSWORD=%s\n' "$$NEW_PASSWORD" >> local/.env; \
		fi; \
		echo "Password saved to local/.env"; \
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
	echo "$$RESULT" | python3 -c "import sys,json; r=json.load(sys.stdin); print('Registered:', r.get('repo','?'))"; \
	mkdir -p local/argocd-repos; \
	SAFE_NAME=$$(echo "$(REPO)" | sed 's|https://||; s|http://||; s|[/.]|-|g'); \
	SECRET_FILE=local/argocd-repos/$$SAFE_NAME.yaml; \
	if [ -n "$(TOKEN)" ]; then \
		printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: repo-%s\n  namespace: argocd\n  labels:\n    argocd.argoproj.io/secret-type: repository\nstringData:\n  type: git\n  url: %s\n  username: git\n  password: %s\n' "$$SAFE_NAME" "$(REPO)" "$(TOKEN)" > $$SECRET_FILE; \
	else \
		printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: repo-%s\n  namespace: argocd\n  labels:\n    argocd.argoproj.io/secret-type: repository\nstringData:\n  type: git\n  url: %s\n' "$$SAFE_NAME" "$(REPO)" > $$SECRET_FILE; \
	fi; \
	echo "Credentials saved to $$SECRET_FILE"

argocd-list-repos: check-kubectl
	@TOKEN=$$(curl -sf http://argocd.localhost/api/v1/session \
		-H "Content-Type: application/json" \
		-d "{\"username\":\"admin\",\"password\":\"$(ARGOCD_PASSWORD)\"}" | \
		python3 -c "import sys,json; print(json.load(sys.stdin)['token'])"); \
	curl -sf http://argocd.localhost/api/v1/repositories \
		-H "Authorization: Bearer $$TOKEN" | \
		python3 -c "import sys,json; repos=json.load(sys.stdin).get('items') or []; [print('No repositories registered.') if not repos else None]; [print(f\"  {r.get('repo','?')}  [{'OK' if r.get('connectionState',{}).get('status')=='Successful' else r.get('connectionState',{}).get('status','?')}]\") for r in repos]"

argocd-add-source: check-kubectl
	@if [ -z "$(REPO)" ]; then \
		echo "Usage: make argocd-add-source REPO=<url> [SOURCE_PATH=.] [REVISION=HEAD]"; exit 1; \
	fi
	@REVISION="$(if $(REVISION),$(REVISION),HEAD)"; \
	SOURCE_PATH="$(if $(SOURCE_PATH),$(SOURCE_PATH),.)"; \
	HAS_SOURCES=$$(kubectl get application root -n argocd -o jsonpath='{.spec.sources}' 2>/dev/null); \
	if [ -n "$$HAS_SOURCES" ] && [ "$$HAS_SOURCES" != "null" ]; then \
		kubectl patch application root -n argocd --type=json \
			-p "[{\"op\":\"add\",\"path\":\"/spec/sources/-\",\"value\":{\"repoURL\":\"$(REPO)\",\"targetRevision\":\"$$REVISION\",\"path\":\"$$SOURCE_PATH\"}}]"; \
	else \
		EXISTING_REPO=$$(kubectl get application root -n argocd -o jsonpath='{.spec.source.repoURL}'); \
		EXISTING_PATH=$$(kubectl get application root -n argocd -o jsonpath='{.spec.source.path}'); \
		EXISTING_REV=$$(kubectl get application root -n argocd -o jsonpath='{.spec.source.targetRevision}'); \
		kubectl patch application root -n argocd --type=json \
			-p "[{\"op\":\"add\",\"path\":\"/spec/sources\",\"value\":[{\"repoURL\":\"$$EXISTING_REPO\",\"targetRevision\":\"$$EXISTING_REV\",\"path\":\"$$EXISTING_PATH\"},{\"repoURL\":\"$(REPO)\",\"targetRevision\":\"$$REVISION\",\"path\":\"$$SOURCE_PATH\"}]},{\"op\":\"remove\",\"path\":\"/spec/source\"}]"; \
	fi
	@echo "Source added: $(REPO)"

argocd-list-apps: check-kubectl
	@TOKEN=$$(curl -sf http://argocd.localhost/api/v1/session \
		-H "Content-Type: application/json" \
		-d "{\"username\":\"admin\",\"password\":\"$(ARGOCD_PASSWORD)\"}" | \
		python3 -c "import sys,json; print(json.load(sys.stdin)['token'])"); \
	curl -sf http://argocd.localhost/api/v1/applications \
		-H "Authorization: Bearer $$TOKEN" | \
		python3 -c "import sys,json; apps=json.load(sys.stdin).get('items') or []; [print('No applications found.') if not apps else (print(f\"  {'NAME':<25} {'SYNC':<12} HEALTH\"), print(f\"  {'-'*25} {'-'*12} {'-'*10}\"), [print(f\"  {a.get('metadata',{}).get('name','?'):<25} {a.get('status',{}).get('sync',{}).get('status','?'):<12} {a.get('status',{}).get('health',{}).get('status','?')}\") for a in apps])]"

## Headlamp

headlamp-token: check-kubectl
	@kubectl create token headlamp -n headlamp --duration=8760h

## Manifest management

update-manifests:
	@echo "Updating k3d-config.yaml K3S image to $(K3S_VERSION)..."
	sed -i '' 's|image: rancher/k3s:.*|image: rancher/k3s:$(K3S_VERSION)|' k3d-config.yaml
	@echo "Fetching sealed-secrets $(SEALED_SECRETS_VERSION)..."
	curl -sL https://github.com/bitnami-labs/sealed-secrets/releases/download/$(SEALED_SECRETS_VERSION)/controller.yaml \
		> bootstrap/sealed-secrets.yaml
	@echo "Fetching cert-manager $(CERT_MANAGER_VERSION)..."
	curl -sL https://github.com/cert-manager/cert-manager/releases/download/$(CERT_MANAGER_VERSION)/cert-manager.yaml \
		> bootstrap/cert-manager.yaml
	@echo "Fetching ArgoCD $(ARGOCD_VERSION)..."
	curl -sL https://raw.githubusercontent.com/argoproj/argo-cd/$(ARGOCD_VERSION)/manifests/install.yaml \
		> bootstrap/argocd-install.yaml
	@echo "Done. Review changes and commit."

## Sealed Secrets

seal: check-kubeseal
	@if [ -z "$(NAME)" ]; then \
		echo "Usage: make seal NAME=<name> [NAMESPACE=<ns>]"; exit 1; \
	fi
	@if [ ! -f local/secrets/$(NAME).env ]; then \
		echo "Error: local/secrets/$(NAME).env not found"; exit 1; \
	fi
	@if [ ! -f local/sealed-secrets-cert.pem ]; then \
		echo "Error: local/sealed-secrets-cert.pem not found — run: make kubeseal-cert"; exit 1; \
	fi
	@mkdir -p apps
	@NS="$(if $(NAMESPACE),$(NAMESPACE),default)"; \
	kubectl create secret generic $(NAME) \
		--namespace=$$NS \
		--from-env-file=local/secrets/$(NAME).env \
		--dry-run=client -o yaml | \
	kubeseal --cert local/sealed-secrets-cert.pem --format yaml \
		> apps/$(NAME)-sealed-secret.yaml; \
	echo "Sealed: apps/$(NAME)-sealed-secret.yaml (namespace: $$NS)"

sealed-secrets-backup: check-kubectl
	@until kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key=active --no-headers 2>/dev/null | grep -q .; do sleep 2; done
	@kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key=active -o json | \
		python3 -c "import sys,json; obj=json.load(sys.stdin); strip=['resourceVersion','uid','creationTimestamp','managedFields','selfLink','generation','annotations']; [[m.pop(f,None) for f in strip] for item in obj.get('items',[]) for m in [item.get('metadata',{})]]; print(json.dumps(obj,indent=2))" \
		> local/sealed-secrets-key.json
	@echo "Key backed up to local/sealed-secrets-key.json"

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
