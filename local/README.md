# local/

Place your local configuration overrides here. All files in this directory
(except this README and .gitkeep) are gitignored — safe for machine-specific
paths, credentials, and personal preferences.

## .env

Override Makefile variables:

```bash
# local/.env
WORKERS=2
K3S_VERSION=v1.32.0-k3s1
ARGOCD_VERSION=v2.13.0
MAX_WORKERS=10
ARGOCD_DESIRED_PASSWORD=yourpassword   # auto-written by make argocd-set-password
```

## ArgoCD persistence

Settings here survive `make recreate`.

### Password

Set in `local/.env` (auto-written by `make argocd-set-password`):

```bash
ARGOCD_DESIRED_PASSWORD=yourpassword
```

### Repository credentials

`make argocd-add-repo` automatically saves credentials to `local/argocd-repos/<repo>.yaml`.
These are re-applied on bootstrap. To add one manually:

```yaml
# local/argocd-repos/github-com-you-myapp.yaml
apiVersion: v1
kind: Secret
metadata:
  name: repo-github-com-you-myapp
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: https://github.com/you/myapp
  username: git
  password: ghp_xxx
```

### ConfigMap patches

Place `kubectl apply`-compatible YAML files in `local/argocd-config/` to restore
`argocd-cm`, `argocd-rbac-cm`, or other ArgoCD config on bootstrap. Example:

```yaml
# local/argocd-config/argocd-cm-patch.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cm
  namespace: argocd
data:
  admin.enabled: "true"
  resource.customizations: |
    ...
```

## secrets/

Plain `KEY=VALUE` files, one per secret. Gitignored. Sealed via `make seal`.

```bash
# local/secrets/myapp.env
DB_PASSWORD=hunter2
API_KEY=abc123
```

```bash
make seal NAME=myapp NAMESPACE=myapp
# → apps/myapp-sealed-secret.yaml  (safe to commit)
```

ArgoCD picks up the committed SealedSecret and applies it. The controller decrypts it
into a real `Secret` using the persisted keypair.

## Sealed Secrets keypair

`local/sealed-secrets-key.json` — auto-saved during `make create` and via `make sealed-secrets-backup`.

Restored on bootstrap before the controller starts, so all existing SealedSecrets remain
decryptable across `make recreate`. Treat this file like a private key — it decrypts all
your sealed secrets. **Losing it makes all SealedSecrets permanently unreadable.**

`local/sealed-secrets-cert.pem` — the controller's public cert, auto-fetched during `make create`
(requires `kubeseal`). Used by `make seal` to encrypt secrets. Same cert across recreates as long
as the keypair is preserved.

## k3d-config.yaml

Override or extend cluster topology. Merged on top of the repo's
`k3d-config.yaml` at `make create` time — your values take precedence.

Common uses:

```yaml
# local/k3d-config.yaml

# Expose an extra port
ports:
  - port: 8080:8080
    nodeFilters: [loadbalancer]

# Bind-mount an additional host directory (note: /mnt/data is already reserved)
volumes:
  - volume: /Users/yourname/media:/mnt/media
    nodeFilters: [server:*, agent:*]
```
