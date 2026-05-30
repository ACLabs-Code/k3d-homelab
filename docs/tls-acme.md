# TLS with Let's Encrypt (DNS-01)

This cluster ships with a self-signed CA for `.localhost` domains. For real domains, use cert-manager's ACME issuer with DNS-01.

## Before you start

**Always test with staging first.** Let's Encrypt rate-limits production requests.

```yaml
# Staging ACME server
server: https://acme-staging-v02.api.letsencrypt.org/directory

# Production ACME server
server: https://acme-v02.api.letsencrypt.org/directory
```

## Store DNS provider credentials as a SealedSecret

Never commit plain Secrets to git. Encrypt with kubeseal first:

```bash
# 1. Write your plain secret
cat > /tmp/dns-secret.yaml << EOF
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-api-token-secret
  namespace: cert-manager
type: Opaque
stringData:
  api-token: YOUR_TOKEN_HERE
EOF

# 2. Seal it
kubeseal --cert local/sealed-secrets-cert.pem \
  -f /tmp/dns-secret.yaml \
  -w cluster/cert-manager/cloudflare-secret.yaml

# 3. Commit the sealed secret
git add cluster/cert-manager/cloudflare-secret.yaml && git commit -m "add cloudflare dns secret"

# 4. Clean up
rm /tmp/dns-secret.yaml
```

---

## Cloudflare

**Required API token permissions:** Zone → DNS → Edit, Zone → Zone → Read

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-cloudflare-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: you@example.com
    privateKeySecretRef:
      name: letsencrypt-cloudflare-prod-key
    solvers:
    - dns01:
        cloudflare:
          apiTokenSecretRef:
            name: cloudflare-api-token-secret
            key: api-token
```

---

## Route53 (AWS)

**Required IAM policy:**
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "route53:ChangeResourceRecordSets",
        "route53:ListResourceRecordSets"
      ],
      "Resource": "arn:aws:route53:::hostedzone/*"
    },
    {
      "Effect": "Allow",
      "Action": "route53:ListHostedZonesByName",
      "Resource": "*"
    }
  ]
}
```

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-route53-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: you@example.com
    privateKeySecretRef:
      name: letsencrypt-route53-prod-key
    solvers:
    - dns01:
        route53:
          region: us-east-1
          accessKeyIDSecretRef:
            name: route53-credentials-secret
            key: access-key-id
          secretAccessKeySecretRef:
            name: route53-credentials-secret
            key: secret-access-key
```

---

## Generic (any DNS-01 provider)

cert-manager supports many providers. See the full list at https://cert-manager.io/docs/configuration/acme/dns01/

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: you@example.com
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
    - dns01:
        <provider>:
          # provider-specific config
```

---

## Using an ACME issuer on an Ingress

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web,websecure
    cert-manager.io/cluster-issuer: letsencrypt-cloudflare-prod
spec:
  ingressClassName: traefik
  tls:
  - hosts:
    - myapp.example.com
    secretName: myapp-tls
  rules:
  - host: myapp.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: my-app
            port:
              number: 80
```

cert-manager detects the annotation and automatically provisions a certificate. The `secretName` is created and populated once the ACME challenge passes.
