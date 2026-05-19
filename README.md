# ArgoCD v2 Integration Demo

Demo repo for vCluster Platform 4.10 ArgoCD Integration v2.

Covers the three new platform-wide concepts: **Connector**, **ArgoApplicationTemplate**, and **ArgoApplication**.

## Repo structure

```
setup/                  # Bootstrap: Platform install, ArgoCD install, connector Secret
templates/              # ArgoApplicationTemplate CRDs (platform-wide, admin-created)
applications/           # ArgoApplication CRDs (per-project, user-created)
manifests/              # Source manifests that ArgoCD deploys (nginx, guestbook)
apps-in-apps/           # Apps-in-apps pattern (parent + children)
```

## Quick start

### 1. Install ArgoCD (local dev)

```bash
helm repo add argo https://argoproj.github.io/argo-helm && helm repo update argo
helm install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --set server.service.type=ClusterIP \
  --set 'configs.params.server\.insecure=true' \
  --wait --timeout 5m
kubectl port-forward service/argocd-server -n argocd 8081:80
```

### 2. Get admin token

```bash
ADMIN_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

# Enable apiKey capability on admin account
kubectl -n argocd patch configmap argocd-cm --type merge \
  -p '{"data":{"accounts.admin":"apiKey,login"}}'
kubectl -n argocd rollout restart deployment argocd-server
kubectl -n argocd rollout status deployment argocd-server --timeout=2m

# Get session, then mint API token
SESSION=$(curl -s -X POST http://localhost:8081/api/v1/session \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"admin\",\"password\":\"$ADMIN_PASS\"}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")

TOKEN=$(curl -s -X POST http://localhost:8081/api/v1/account/admin/token \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $SESSION" -d '{}' \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")

echo "ArgoCD API Token: $TOKEN"
```

### 3. Install vCluster Platform via ArgoCD (optional - GitOps bootstrap)

```bash
kubectl apply -f setup/platform-config.yaml
```

### 4. Create ArgoCD Connector

Via UI: Infra -> Connectors -> Argo CD -> Add ArgoCD Connector

Or apply the example Secret (edit token first):
```bash
# Edit setup/connector-standard.yaml with your token
kubectl apply -f setup/connector-standard.yaml
```

### 5. Create templates and applications

Templates (admin):
```bash
kubectl apply -f templates/
```

Applications (project user):
```bash
kubectl apply -f applications/
```

## v1 vs v2 at a glance

| | v1 (deprecated) | v2 (4.10+) |
|---|---|---|
| Scope | Project-level | Platform-wide connectors + per-cluster apps |
| Config | `spec.argoCD` in Project | Connector Secret + ArgoApplication CRD |
| Cluster registration | REST API only | REST API or Akuity agent (outbound) |
| App deployment | Per-project, shared config | Per-cluster, template or inline |
| Target | Tenant cluster only | Tenant cluster or control plane cluster (`target: host`) |

## Apps-in-apps

The `apps-in-apps/` directory demonstrates the parent-child Application pattern.
The parent app points to `apps-in-apps/children/` and ArgoCD auto-creates child apps.
This is a native ArgoCD feature confirmed working with v2 (both standard and Akuity connectors).
