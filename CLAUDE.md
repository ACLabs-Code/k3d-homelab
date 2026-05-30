# k3d-homelab

Local Kubernetes lab. K3D (K3S in Docker) + Traefik v2 (built-in) + ArgoCD.

## Key commands

```bash
make create           # create cluster + install ArgoCD
make delete           # destroy cluster
make recreate         # delete + create
make status           # nodes, pods, proxy container health
make info             # access URLs
make example-app      # deploy nginx demo app
make argocd-password  # print ArgoCD admin password
```

## Architecture

- `.localhost` domains resolve to 127.0.0.1 automatically on macOS/Linux — no /etc/hosts edits
- Traffic: browser → k3d load balancer container → Traefik pod → ClusterIP service → pod
- Traefik v2 is K3S built-in; configured via `cluster/traefik/helmchartconfig.yaml` (mounted at cluster create)
- ArgoCD runs in `--insecure` mode (HTTP only) behind Traefik

## File layout

```
cluster/traefik/helmchartconfig.yaml   Traefik dashboard config (mounted via --volume at create)
cluster/argocd/install.yaml            ArgoCD manifest (committed, v2.12.7)
cluster/argocd/server-insecure-patch.yaml
cluster/argocd/ingress.yaml
apps/example-app/                      nginx demo (deployment + service + ingress)
scripts/install-tools.sh               kubectl + k3d install (macOS arm64)
```

## Gotchas

- Traefik dashboard URL requires trailing slash: `http://traefik.localhost/dashboard/`
- Do NOT install local-path-provisioner — K3S includes it; double install conflicts
- If ports unreachable: `docker ps --filter name=k3d-homelab-serverlb` — proxy container must be running
