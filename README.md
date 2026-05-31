# k3d-homelab

Bare-minimum bootstrap for a local Kubernetes lab. Spins up a K3D cluster with Traefik ingress and ArgoCD, then gets out of the way — ArgoCD manages everything else via GitOps.

## Prerequisites

Docker, kubectl, k3d, kubeseal:

```bash
brew install kubectl k3d kubeseal
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
| ArgoCD | https://argocd.localhost |

ArgoCD credentials are printed by `make create` and `make info`.

## Persistent storage

`./data/` on your Mac is bind-mounted into all cluster nodes at `/mnt/data`. The default `local-path` StorageClass writes PV data there, so it survives `make recreate`.

Apps just use standard PVCs — no special configuration needed:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-app-data
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
```

Data directories appear in `./data/` as `pvc-<uid>_<namespace>_<pvc-name>/`. They are not automatically cleaned up when a PVC is deleted — manage `./data/` manually.

## TLS

ArgoCD is available at `https://argocd.localhost`. A self-signed CA is auto-generated at `local/ca.crt` on first `make create`.

Trust it in your browser (once):

```bash
make ca-trust   # adds CA to macOS Keychain; restart browser after
```

To replace the auto-generated CA with your own, place `ca.crt` and `ca.key` in `local/` before running `make create`.

For real domain certificates via Let's Encrypt DNS-01, see [docs/tls-acme.md](docs/tls-acme.md).

## Sealing secrets

Install `kubeseal` locally (`brew install kubeseal`), then:

```bash
# Fetch the controller's public cert (once per cluster)
make kubeseal-cert

# Encrypt a secret
kubeseal --cert local/sealed-secrets-cert.pem -f secret.yaml -w sealed-secret.yaml

# Commit the sealed secret — safe to push to git
git add sealed-secret.yaml && git commit -m "add sealed secret"
```

`local/sealed-secrets-cert.pem` is gitignored. Re-run `make kubeseal-cert` after `make recreate`.

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
make create [WORKERS=N]                  Create cluster + bootstrap all components
make delete                              Destroy cluster
make recreate [WORKERS=N]                Delete and recreate
make scale WORKERS=N                     Add agents to running cluster (scale up only)
make add-worker                          Add one agent to running cluster
make status                              Cluster, node, and ArgoCD app health
make info                                Print access URLs and credentials
make argocd-password                     Print ArgoCD admin credentials
make argocd-set-password NEW_PASSWORD=x  Set ArgoCD admin password
make argocd-add-repo REPO=x [TOKEN=x]   Register an app repo
make argocd-list-repos                   List registered repos
make argocd-list-apps                    List apps and sync status
make kubeseal-cert                       Fetch Sealed Secrets public cert
make ca-generate                         Generate CA keypair to local/
make ca-trust                            Trust local CA in macOS Keychain
make check-tools                         Verify required tools are installed
```

## Stack

| Component | Version |
|---|---|
| K3S | v1.36.1-k3s1 |
| Traefik | v3.x (bundled with K3S) |
| ArgoCD | v3.4.3 |
| Sealed Secrets | v0.37.0 |
| cert-manager | v1.20.2 |

## Planned

- ~~**Secrets management**~~ — Sealed Secrets v0.37.0 installed as part of bootstrap. Encrypt secrets with `kubeseal`, commit ciphertext to git, cluster decrypts at apply time.
- ~~**TLS**~~ — cert-manager v1.20.2 installed as part of bootstrap. Self-signed CA for `.localhost` (auto-generated, trust with `make ca-trust`). Real domain certs via Let's Encrypt DNS-01 — see [docs/tls-acme.md](docs/tls-acme.md).
- ~~**Persistence**~~ — `./data/` on your Mac is bind-mounted into all cluster nodes at `/mnt/data`. The `local-path` StorageClass (default) uses this path, so PVC data survives `make recreate` automatically.

## Forking

Clone and run `make create`. The Makefile detects your git remote automatically for the bootstrap step.
