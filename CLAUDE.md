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
make argocd-list-repos
make argocd-list-apps
make kubeseal-cert           # fetch controller public cert → local/sealed-secrets-cert.pem
make ca-generate             # generate CA keypair → local/ca.crt + local/ca.key
make ca-trust                # trust local CA in macOS Keychain (sudo)
```

## Bootstrap sequence (what `make create` does)

1. Auto-generate CA if `local/ca.crt` missing (`make ca-generate`)
2. `k3d cluster create` — uses `k3d-config.yaml`; mounts Traefik HelmChartConfig via `--volume`
3. Wait for `helm-install-traefik` job + traefik rollout
4. `kubectl apply bootstrap/sealed-secrets.yaml` — installs Sealed Secrets controller
5. Wait for sealed-secrets-controller rollout
6. `kubectl apply bootstrap/cert-manager.yaml` — installs cert-manager
7. Wait for cert-manager + webhook rollout + webhook pod ready
8. Load `local/ca.crt` + `local/ca.key` as Secret `localhost-ca-secret` in cert-manager namespace
9. `kubectl apply bootstrap/cert-manager-issuers.yaml` — creates `localhost-ca` ClusterIssuer
10. `kubectl apply bootstrap/argocd-install.yaml` — installs ArgoCD
11. Wait for argocd-server rollout
12. `kubectl patch` — sets ArgoCD to insecure (HTTP) mode; waits for restart
13. `kubectl apply bootstrap/argocd-ingress.yaml` — exposes ArgoCD at `https://argocd.localhost` with TLS
14. `kubectl apply bootstrap/argocd-root-app.yaml` — hands off to ArgoCD

After step 7, ArgoCD owns everything. It watches `apps/` and creates child Applications from any `.yaml` committed there.

## Architecture

```
bootstrap/                    Makefile applies all of these directly (one-time)
  sealed-secrets.yaml         Sealed Secrets controller manifest
  cert-manager.yaml           cert-manager manifest
  cert-manager-issuers.yaml   localhost-ca ClusterIssuer
  argocd-install.yaml         Official ArgoCD manifest
  argocd-ingress.yaml         argocd.localhost ingress (TLS via localhost-ca)
  argocd-root-app.yaml        Root Application → watches apps/ in this repo
  server-insecure-patch.yaml

docs/
  tls-acme.md                 Let's Encrypt DNS-01 setup (Cloudflare, Route53, generic)

apps/                         ArgoCD watches this dir; commit .yaml here to register apps

cluster/
  traefik/
    helmchartconfig.yaml      Traefik dashboard config (mounted via --volume at create)

k3d-config.yaml               Cluster definition (ports, image, node count)

local/                        Gitignored user overrides (see local/README.md)
  .env                        Makefile variable overrides (WORKERS, K3S_VERSION, etc.)
  k3d-config.yaml             Merged on top of repo k3d-config.yaml at cluster create
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
- `make argocd-password` reads the initial secret — stale if password was changed via `argocd-set-password`; pass `ARGOCD_PASSWORD=<pw>` to override
- `make scale` only scales up; to scale down use `make recreate WORKERS=N`
- `k3d node create` appends `-0` to node names (k3d behavior, cosmetic only)
- CA is auto-generated on first `make create` — run `make ca-trust` once to avoid browser warnings
- `local/ca.crt` + `local/ca.key` are gitignored and persist across `make recreate` — same CA, no re-trust needed
- cert-manager webhook has a known K3S timing issue — bootstrap waits explicitly for webhook pod ready
