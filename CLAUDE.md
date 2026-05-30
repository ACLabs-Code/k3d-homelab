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
```

## Bootstrap sequence (what `make create` does)

1. `k3d cluster create` — uses `k3d-config.yaml`; mounts `cluster/traefik/helmchartconfig.yaml` via `--volume` so Traefik dashboard is configured before first pod start
2. Wait for `helm-install-traefik` job + traefik rollout
3. `kubectl apply bootstrap/argocd-install.yaml` — installs ArgoCD
4. Wait for argocd-server rollout
5. `kubectl patch` — sets ArgoCD to insecure (HTTP) mode; waits for restart
6. `kubectl apply bootstrap/argocd-ingress.yaml` — exposes ArgoCD at `argocd.localhost`
7. `kubectl apply bootstrap/argocd-root-app.yaml` — hands off to ArgoCD

After step 7, ArgoCD owns everything. It watches `apps/` and creates child Applications from any `.yaml` committed there.

## Architecture

```
bootstrap/                    Makefile applies all of these directly (one-time)
  argocd-install.yaml         Official ArgoCD manifest
  argocd-ingress.yaml         argocd.localhost ingress
  argocd-root-app.yaml        Root Application → watches apps/ in this repo
  server-insecure-patch.yaml

apps/                         ArgoCD watches this dir; commit .yaml here to register apps

cluster/
  traefik/
    helmchartconfig.yaml      Traefik dashboard config (mounted via --volume at create)

k3d-config.yaml               Cluster definition (ports, image, node count)
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
