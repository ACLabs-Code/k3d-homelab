# k3d-homelab

Bare-minimum bootstrap tool. Makefile creates the cluster and installs ArgoCD. ArgoCD manages everything else via GitOps.

## Key commands

```bash
make create              # create cluster + bootstrap ArgoCD
make delete              # destroy cluster
make recreate            # delete + create
make scale WORKERS=N     # add agents to running cluster (scale up only)
make add-worker          # add one agent to running cluster
make status              # nodes, pods, ArgoCD app status
make info                # access URLs + ArgoCD credentials
make argocd-password     # print ArgoCD credentials
make argocd-set-password NEW_PASSWORD=<pw>
make argocd-add-repo REPO=<url> [TOKEN=<tok>]
make argocd-add-source REPO=<url> [SOURCE_PATH=.] [REVISION=HEAD]
make argocd-list-repos
make argocd-list-apps
make update-manifests        # update k3d-config.yaml + re-fetch bootstrap manifests at current version pins
make seal NAME=<name> [NAMESPACE=<ns>]   # seal local/secrets/<name>.env → apps/<name>-sealed-secret.yaml
make sealed-secrets-backup              # back up controller keypair → local/sealed-secrets-key.json
make kubeseal-cert                      # fetch controller public cert → local/sealed-secrets-cert.pem
make ca-generate             # generate CA keypair → local/ca.crt + local/ca.key
make ca-trust                # trust local CA in macOS Keychain (sudo)
```

## Bootstrap sequence (what `make create` does)

1. Auto-generate CA if `local/ca.crt` missing (`make ca-generate`)
2. Auto-create `./local/data/volumes/` directory
3. `k3d cluster create` — mounts Traefik HelmChartConfig + `./local/data:/mnt/data` into all nodes
4. Wait for `helm-install-traefik` job + traefik rollout
5. Patch `local-path-config` ConfigMap → storage root becomes `/mnt/data/volumes`; restart provisioner
6. Restore Sealed Secrets keypair from `local/sealed-secrets-key.json` if present
7. Apply Sealed Secrets + cert-manager **in parallel** (background jobs); wait for both + webhook ready
8. Back up Sealed Secrets keypair → `local/sealed-secrets-key.json`; fetch cert → `local/sealed-secrets-cert.pem`
9. Load `local/ca.crt` + `local/ca.key` as Secret `localhost-ca-secret` in cert-manager namespace
10. `kubectl apply bootstrap/cert-manager-issuers.yaml` — creates `localhost-ca` ClusterIssuer
11. `kubectl apply bootstrap/argocd-install.yaml` — installs ArgoCD; patch `server.insecure: true`
12. Wait for argocd-server rollout
13. Restore ArgoCD repo credentials from `local/argocd-repos/` if present
14. Restore ArgoCD ConfigMap patches from `local/argocd-config/` if present
15. `kubectl apply bootstrap/argocd-ingress.yaml` — exposes ArgoCD at `https://argocd.localhost` with TLS
16. Set admin password from `ARGOCD_DESIRED_PASSWORD` in `local/.env` if set
17. `kubectl apply bootstrap/argocd-root-app.yaml` — hands off to ArgoCD

After step 17, ArgoCD owns everything. It watches `apps/` and creates child Applications from any `.yaml` committed there.

## Architecture

```
bootstrap/                    Makefile applies all of these directly (one-time)
  local-path-config.yaml      Reconfigures local-path-provisioner to use /mnt/data/volumes
  cert-manager-issuers.yaml   localhost-ca ClusterIssuer
  argocd-ingress.yaml         argocd.localhost ingress (TLS via localhost-ca)
  argocd-root-app.yaml        Root Application → watches apps/ in this repo
  sealed-secrets.yaml         Sealed Secrets controller manifest (regenerate: make update-manifests)
  cert-manager.yaml           cert-manager manifest (regenerate: make update-manifests)
  argocd-install.yaml         Official ArgoCD manifest (regenerate: make update-manifests)

docs/
  tls-acme.md                 Let's Encrypt DNS-01 setup (Cloudflare, Route53, generic)

apps/                         ArgoCD watches this dir; commit .yaml here to register apps
  headlamp.yaml               Headlamp dashboard (https://headlamp.localhost)

cluster/
  traefik/
    helmchartconfig.yaml      Traefik dashboard config (mounted via --volume at create)

k3d-config.yaml               Cluster definition (ports, node count, K3S image; regenerate: make update-manifests)

local/                        Gitignored runtime state (see local/README.md)
  .env                        Makefile variable overrides + ARGOCD_DESIRED_PASSWORD
  k3d-config.yaml             Merged on top of repo k3d-config.yaml at cluster create
  ca.crt + ca.key             TLS CA keypair (auto-generated; trust once with make ca-trust)
  sealed-secrets-key.json     Controller keypair backup (auto-saved; losing it = all SealedSecrets unreadable)
  sealed-secrets-cert.pem     Controller public cert for sealing (auto-saved on create)
  data/volumes/               Persistent volume data (bind-mounted as /mnt/data into nodes)
  secrets/                    Plain KEY=VALUE files → sealed via make seal
  argocd-repos/               Repo credential Secrets → auto-saved by argocd-add-repo; restored on bootstrap
  argocd-config/              ArgoCD ConfigMap patches → restored on bootstrap
```

## Adding an app repo

```bash
make argocd-add-repo REPO=https://github.com/you/myapp TOKEN=ghp_xxx
```

Then create an Application manifest in your app repo pointing ArgoCD at it.

## Gotchas

- Traefik dashboard URL requires trailing slash: `http://traefik.localhost/dashboard/`
- Do NOT install local-path-provisioner — K3S includes it
- If ports unreachable: `docker ps --filter name=k3d-homelab-serverlb`
- `make argocd-password` reads `argocd-initial-admin-secret` — kept in sync by `argocd-set-password`; pass `ARGOCD_PASSWORD=<pw>` to override
- `make argocd-set-password` auto-saves the new password to `local/.env` as `ARGOCD_DESIRED_PASSWORD`
- `make argocd-add-repo` auto-saves credentials to `local/argocd-repos/` — re-applied on next bootstrap
- `make scale` only scales up; to scale down use `make recreate WORKERS=N`
- `k3d node create` appends `-0` to node names (k3d behavior, cosmetic only)
- CA is auto-generated on first `make create` — run `make ca-trust` once to avoid browser warnings
- `local/ca.crt` + `local/ca.key` persist across `make recreate` — same CA, no re-trust needed
- `local/sealed-secrets-key.json` is like `local/ca.key` — losing it makes all SealedSecrets permanently unreadable
- cert-manager webhook has a known K3S timing issue — bootstrap waits explicitly for webhook pod ready
- `volumes/` directories (one per PV) are NOT cleaned up when a PVC is deleted — manage `./local/data/volumes/` manually
