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
```

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
