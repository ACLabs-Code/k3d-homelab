# k3d-homelab

Local Kubernetes lab using K3D (K3S in Docker). Runs Traefik ingress and ArgoCD GitOps on a single machine with `.localhost` domain access.

## Prerequisites

Docker, kubectl, k3d. Install via Homebrew:

```bash
brew install kubectl k3d
```

Or run `scripts/install-tools.sh` for manual install.

## Usage

```bash
make create           # spin up cluster + ArgoCD
make status           # check cluster health
make info             # print access URLs
make example-app      # deploy nginx demo
make argocd-password  # print ArgoCD admin password
make delete           # tear down cluster
```

Multi-node:

```bash
make create WORKERS=2
```

## Access

| Service | URL |
|---|---|
| Traefik Dashboard | http://traefik.localhost/dashboard/ |
| ArgoCD | http://argocd.localhost |
| Example App | http://example.localhost |

ArgoCD credentials: `admin` / `make argocd-password`

## Stack

| Component | Version |
|---|---|
| K3S | v1.31.4-k3s1 |
| Traefik | v2.x (bundled with K3S) |
| ArgoCD | v2.12.7 |
