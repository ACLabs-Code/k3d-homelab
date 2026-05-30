# k3d-homelab

Bare-minimum bootstrap tool. Makefile creates the cluster and installs ArgoCD. ArgoCD manages everything else via GitOps.

## Key commands

```bash
make create              # create cluster + bootstrap ArgoCD
make delete              # destroy cluster
make recreate            # delete + create
make status              # nodes, pods, ArgoCD app status
make info                # access URLs
make argocd-password     # print ArgoCD credentials
make argocd-set-password NEW_PASSWORD=<pw>
make argocd-add-repo REPO=<url> [TOKEN=<tok>]
make argocd-list-repos
make argocd-list-apps
```

## Bootstrap sequence (what `make create` does)

1. `k3d cluster create` — mounts `cluster/traefik/helmchartconfig.yaml` via `--volume` so Traefik dashboard is configured before first pod start
2. Wait for `helm-install-traefik` job + traefik rollout
3. `kubectl apply bootstrap/argocd-install.yaml` — installs ArgoCD
4. Wait for argocd-server rollout
5. `kubectl patch` — sets ArgoCD to insecure (HTTP) mode
6. `kubectl apply bootstrap/argocd-root-app.yaml` — hands off to ArgoCD

After step 6, ArgoCD owns everything. It syncs `apps/` and creates child Applications.

## Architecture

```
bootstrap/               Makefile applies these directly (one-time)
  argocd-install.yaml    Official ArgoCD manifest
  argocd-root-app.yaml   Root Application → watches apps/ in this repo
  server-insecure-patch.yaml

apps/                    ArgoCD watches this dir; add .yaml here to register apps
  argocd.yaml            → manifests/argocd/

manifests/               Actual k8s manifests, applied by ArgoCD
  argocd/
    ingress.yaml         argocd.localhost ingress

cluster/
  traefik/
    helmchartconfig.yaml  Traefik dashboard config (bootstrap only via --volume)
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
- `apps/argocd.yaml` has a hardcoded repoURL — update it if you fork this repo
