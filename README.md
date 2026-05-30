# k3d-homelab

Bare-minimum bootstrap for a local Kubernetes lab. Spins up a K3D cluster with Traefik ingress and ArgoCD, then gets out of the way — ArgoCD manages everything else via GitOps.

## Prerequisites

Docker, kubectl, k3d:

```bash
brew install kubectl k3d
```

## Quickstart

```bash
make create
```

That's it. The cluster is up, ArgoCD is running, and watching this repo's `apps/` directory. Access URLs and credentials are printed at the end.

Multi-node:

```bash
make create WORKERS=2
```

## Access

| Service | URL |
|---|---|
| Traefik Dashboard | http://traefik.localhost/dashboard/ |
| ArgoCD | http://argocd.localhost |

ArgoCD credentials are printed by `make create` and `make info`.

## Deploying apps

Register your app repo with ArgoCD, then point ArgoCD at it via an Application manifest in your own repo.

```bash
# Register a private repo
make argocd-add-repo REPO=https://github.com/you/myapp TOKEN=ghp_xxx

# List registered repos
make argocd-list-repos

# Check app sync status
make argocd-list-apps
```

## All targets

```
make create [WORKERS=N]                  Create cluster + bootstrap ArgoCD
make delete                              Destroy cluster
make recreate [WORKERS=N]                Delete and recreate
make status                              Cluster, node, and ArgoCD app health
make info                                Print access URLs and credentials
make argocd-password                     Print ArgoCD admin credentials
make argocd-set-password NEW_PASSWORD=x  Set ArgoCD admin password
make argocd-add-repo REPO=x [TOKEN=x]   Register an app repo
make argocd-list-repos                   List registered repos
make argocd-list-apps                    List apps and sync status
make check-tools                         Verify required tools are installed
```

## Stack

| Component | Version |
|---|---|
| K3S | v1.31.4-k3s1 |
| Traefik | v2.x (bundled with K3S) |
| ArgoCD | v2.12.7 |

## Planned

- **Secrets management** — Sealed Secrets (Bitnami): encrypt secrets locally with `kubeseal`, commit ciphertext to git, cluster decrypts at apply time. GitOps-native, no external dependencies.
- **TLS** — cert-manager: automatic certificate provisioning for `.localhost` and real domains. Pairs with Traefik for HTTPS ingress.

## Forking

Clone and run `make create`. The Makefile detects your git remote automatically for the bootstrap step.
