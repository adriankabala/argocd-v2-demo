set export
set shell := ["bash", "-uc"]

yaml          := justfile_directory()
tf_kind       := justfile_directory() + "/tf-kind"

browse        := if os() == "linux" { "xdg-open "} else { "open" }
copy          := if os() == "linux" { "xsel -ib"} else { "pbcopy" }

argocd_port   := "30950"

# this list of available targets
default:
  just --list --unsorted

# -------------------------------------------------------
# Full environment
# -------------------------------------------------------

# * full environment: kind + argocd + platform + connector + templates + apps + open UIs
# requires LICENSE_TOKEN env var: LICENSE_TOKEN=xxx just up
up:
  #!/usr/bin/env bash
  set -euo pipefail

  if [ -z "${LICENSE_TOKEN:-}" ]; then
    echo "ERROR: LICENSE_TOKEN env var is required. Usage: LICENSE_TOKEN=xxx just up"
    exit 1
  fi

  echo "=== 1/8 Initializing terraform ==="
  just tf_init

  echo "=== 2/8 Creating KIND cluster ==="
  just setup_kind

  echo "=== 3/8 Installing ArgoCD ==="
  just setup_argo

  echo "=== 4/8 Installing vCluster Platform ==="
  just setup_platform

  echo "=== 5/8 Injecting license ==="
  just inject_license

  echo "=== 6/8 Logging into platform ==="
  just platform_login

  echo "=== 7/8 Creating ArgoCD connector + templates ==="
  just setup_connector
  just setup_templates

  echo "=== 8/8 Opening UIs ==="
  just launch_argo
  just launch_platform

  echo ""
  echo "=== Done! ==="
  echo "Next steps:"
  echo "  - Create a tenant cluster in the UI with ArgoCD enabled"
  echo "  - Or: just create_vcluster"
  echo "  - Then: just deploy_apps"

# -------------------------------------------------------
# Individual setup targets
# -------------------------------------------------------

# initialize terraform
tf_init:
  #!/usr/bin/env bash
  set -euo pipefail
  cd {{tf_kind}}
  rm -f .terraform/terraform.tfstate
  rm -f terraform.tfstate*
  terraform init

# setup KIND cluster with ingress
setup_kind:
  #!/usr/bin/env bash
  set -euo pipefail
  cd {{tf_kind}} && terraform apply -auto-approve

# install ArgoCD and patch server to nodePort
setup_argo:
  #!/usr/bin/env bash
  set -euo pipefail
  echo "Installing ArgoCD..."
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
  kubectl wait --for condition=Available=True --timeout=300s deployment/argocd-server --namespace argocd

  echo "Patching server to NodePort {{argocd_port}}..."
  kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "NodePort"}}'
  kubectl patch svc argocd-server -n argocd --type='json' \
    -p='[{"op": "replace", "path": "/spec/ports/0/nodePort", "value": {{argocd_port}}}]'

  echo "Enabling apiKey on admin account..."
  kubectl -n argocd patch configmap argocd-cm --type merge \
    -p '{"data":{"accounts.admin":"apiKey,login"}}'
  kubectl -n argocd rollout restart deployment argocd-server
  kubectl -n argocd rollout status deployment argocd-server --timeout=120s

  echo "ArgoCD ready on port {{argocd_port}}"

# install vCluster Platform via Helm (not via ArgoCD - simpler for dev)
setup_platform:
  #!/usr/bin/env bash
  set -euo pipefail
  echo "Installing vCluster Platform..."
  helm install vcluster-platform oci://ghcr.io/loft-sh/charts/vcluster-platform \
    --namespace vcluster-platform --create-namespace \
    --set admin.create=true \
    --set admin.username=admin \
    --set admin.password=password \
    --set audit.enableSideCar=false \
    --set config.audit.level=1 \
    --wait --timeout 600s

  echo "Platform installed"

# inject LICENSE_TOKEN into the platform deployment
inject_license:
  #!/usr/bin/env bash
  set -euo pipefail
  if [ -z "${LICENSE_TOKEN:-}" ]; then
    echo "ERROR: LICENSE_TOKEN env var is required"
    exit 1
  fi
  kubectl set env deployment/loft -n vcluster-platform LICENSE_TOKEN="${LICENSE_TOKEN}"
  kubectl wait --for condition=Available=True --timeout=300s deployment/loft --namespace vcluster-platform
  echo "License injected"

# login to platform via CLI
platform_login:
  #!/usr/bin/env bash
  set -euo pipefail
  export platform_url=$(kubectl get secret -n vcluster-platform loft-router-domain \
    -o jsonpath="{.data.domain}" | base64 -d)
  echo "Platform URL: ${platform_url}"

  access_key=$(curl -s -k "https://${platform_url}/auth/password/login" \
    -H "Content-Type: application/json" \
    -d '{"username":"admin","password":"password"}' | jq -r '.accessKey')

  vcluster platform login "${platform_url}" --access-key "${access_key}" --insecure
  echo "Logged in"

# -------------------------------------------------------
# ArgoCD v2 integration setup
# -------------------------------------------------------

# get ArgoCD admin password
argo_password:
  #!/usr/bin/env bash
  pw=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
  echo "username: admin"
  echo "password: ${pw}"

# mint a long-lived ArgoCD API token and print it
argo_token:
  #!/usr/bin/env bash
  set -euo pipefail
  ADMIN_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d)

  SESSION=$(curl -s -X POST http://localhost:{{argocd_port}}/api/v1/session \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"admin\",\"password\":\"${ADMIN_PASS}\"}" \
    | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")

  TOKEN=$(curl -s -X POST http://localhost:{{argocd_port}}/api/v1/account/admin/token \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${SESSION}" -d '{}' \
    | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")

  echo "${TOKEN}"

# create ArgoCD connector Secret (standard type, in-cluster)
setup_connector:
  #!/usr/bin/env bash
  set -euo pipefail
  echo "Minting ArgoCD API token..."
  TOKEN=$(just argo_token)

  echo "Creating connector Secret..."
  cat <<EOF | kubectl apply -f -
  apiVersion: v1
  kind: Secret
  metadata:
    name: local-argocd
    namespace: vcluster-platform
    labels:
      loft.sh/connector-type: argocd
  stringData:
    connectorType: argocd
    server: http://argocd-server.argocd.svc.cluster.local
    namespace: argocd
    authType: token
    token: "${TOKEN}"
    insecure: "true"
  EOF

  echo "Connector 'local-argocd' created"

# enable ArgoCD on the control plane cluster (required for cluster-destination apps)
enable_cluster_argocd:
  #!/usr/bin/env bash
  set -euo pipefail
  kubectl patch cluster.management.loft.sh loft-cluster --type merge \
    -p '{"spec":{"argoCD":{"enabled":true,"connector":"local-argocd"}}}'
  echo "ArgoCD enabled on control plane cluster 'loft-cluster'"

# apply all ArgoApplicationTemplates
setup_templates:
  #!/usr/bin/env bash
  set -euo pipefail
  echo "Applying ArgoApplicationTemplates..."
  kubectl apply -f templates/
  echo "Templates created:"
  kubectl get argocdapplicationtemplates.management.loft.sh 2>/dev/null || echo "  (CRD not available - templates will be created when platform registers them)"

# -------------------------------------------------------
# Tenant cluster + apps
# -------------------------------------------------------

# create a tenant cluster with ArgoCD integration enabled
create_vcluster name="my-vcluster" project="default":
  #!/usr/bin/env bash
  set -euo pipefail
  echo "Creating tenant cluster '{{name}}' in project '{{project}}'..."
  vcluster platform create vcluster "{{name}}" --project "{{project}}" \
    --values setup/vcluster-values-with-argocd.yaml \
    --skip-wait
  echo "Tenant cluster '{{name}}' created. ArgoCD integration enabled with connector 'local-argocd'."
  echo "Reconciler will register it in ArgoCD within ~2 min."

# deploy sample ArgoApplications on a tenant cluster
deploy_apps name="my-vcluster" project="default":
  #!/usr/bin/env bash
  set -euo pipefail
  NS="loft-p-{{project}}"

  echo "Deploying nginx (from template) on {{name}}..."
  cat <<EOF | kubectl apply -f -
  apiVersion: management.loft.sh/v1
  kind: ArgoCDApplication
  metadata:
    name: demo-nginx
    namespace: ${NS}
  spec:
    displayName: "Demo Nginx"
    destination:
      virtualCluster:
        name: {{name}}
        namespace: ${NS}
        target: vCluster
    templateRef:
      name: nginx-from-git
    parameters:
      - name: repoURL
        value: "https://github.com/adriankabala/argocd-v2-demo.git"
      - name: targetNamespace
        value: "nginx-demo"
  EOF

  echo "Deploying guestbook (inline) on {{name}}..."
  cat <<EOF | kubectl apply -f -
  apiVersion: management.loft.sh/v1
  kind: ArgoCDApplication
  metadata:
    name: demo-guestbook
    namespace: ${NS}
  spec:
    displayName: "Demo Guestbook"
    destination:
      virtualCluster:
        name: {{name}}
        namespace: ${NS}
        target: vCluster
    template:
      spec:
        source:
          repoURL: "https://github.com/adriankabala/argocd-v2-demo.git"
          targetRevision: main
          path: manifests/guestbook
        destination:
          namespace: guestbook-demo
        syncPolicy:
          automated:
            prune: true
            selfHeal: true
          syncOptions:
            - CreateNamespace=true
  EOF

  echo "Apps deployed. Reconciler will sync within ~2 min."

# deploy apps-in-apps parent application
deploy_apps_in_apps name="my-vcluster" project="default":
  #!/usr/bin/env bash
  set -euo pipefail
  NS="loft-p-{{project}}"
  CLUSTER_NAME="vcluster-{{project}}-{{name}}"

  echo "Deploying apps-in-apps parent on {{name}}..."
  echo "Child apps will target cluster name: ${CLUSTER_NAME}"

  cat <<EOF | kubectl apply -f -
  apiVersion: management.loft.sh/v1
  kind: ArgoCDApplication
  metadata:
    name: demo-apps-in-apps
    namespace: ${NS}
  spec:
    displayName: "Apps-in-Apps Demo"
    destination:
      virtualCluster:
        name: {{name}}
        namespace: ${NS}
        target: vCluster
    template:
      spec:
        source:
          repoURL: "https://github.com/adriankabala/argocd-v2-demo.git"
          targetRevision: main
          path: apps-in-apps/children
        destination:
          namespace: argocd
        syncPolicy:
          automated:
            prune: true
            selfHeal: true
  EOF

  echo "Parent app deployed. Children will auto-create targeting '${CLUSTER_NAME}'."

# deploy target:host example (deploys on control plane cluster from tenant cluster context)
deploy_target_host name="my-vcluster" project="default":
  #!/usr/bin/env bash
  set -euo pipefail
  NS="loft-p-{{project}}"

  echo "WARNING: target:host crosses tenant isolation boundary."
  echo "Deploying on control plane cluster from tenant cluster '{{name}}'..."

  cat <<EOF | kubectl apply -f -
  apiVersion: management.loft.sh/v1
  kind: ArgoCDApplication
  metadata:
    name: demo-target-host
    namespace: ${NS}
  spec:
    displayName: "Target Host Demo"
    destination:
      virtualCluster:
        name: {{name}}
        namespace: ${NS}
        target: host
    template:
      spec:
        source:
          repoURL: "https://github.com/adriankabala/argocd-v2-demo.git"
          targetRevision: main
          path: manifests/nginx
        destination:
          namespace: host-nginx-demo
        syncPolicy:
          automated:
            prune: true
            selfHeal: true
          syncOptions:
            - CreateNamespace=true
  EOF

  echo "App deployed with target:host."

# -------------------------------------------------------
# Status and debugging
# -------------------------------------------------------

# show ArgoCD app status for all platform-managed apps
status:
  #!/usr/bin/env bash
  echo "=== ArgoCD Applications (in ArgoCD) ==="
  kubectl get applications -n argocd -o wide 2>/dev/null || echo "  none"

  echo ""
  echo "=== ArgoCD Applications (Platform CRDs) ==="
  kubectl get argocdapplications.management.loft.sh --all-namespaces -o wide 2>/dev/null || echo "  none"

  echo ""
  echo "=== ArgoCD Connectors ==="
  kubectl get secrets -n vcluster-platform -l loft.sh/connector-type=argocd \
    -o custom-columns='NAME:.metadata.name,TYPE:.data.connectorType,SERVER:.data.server' 2>/dev/null || echo "  none"

  echo ""
  echo "=== ArgoCD Application Templates ==="
  kubectl get argocdapplicationtemplates.management.loft.sh 2>/dev/null || echo "  none"

  echo ""
  echo "=== Tenant Clusters ==="
  kubectl get virtualclusterinstances.management.loft.sh --all-namespaces \
    -o custom-columns='NAME:.metadata.name,NAMESPACE:.metadata.namespace,PHASE:.status.phase' 2>/dev/null || echo "  none"

# show reconciler logs (ArgoCD application controller in platform)
logs:
  kubectl logs -n vcluster-platform deployment/loft -f --tail=100 | grep -i "argocd\|argo-cd\|connector"

# check connector Secret contents (redacted token)
show_connector name="local-argocd":
  #!/usr/bin/env bash
  echo "Connector: {{name}}"
  kubectl get secret {{name}} -n vcluster-platform -o json | jq '{
    name: .metadata.name,
    connectorType: (.data.connectorType | @base64d),
    server: (.data.server | @base64d),
    namespace: (.data.namespace | @base64d),
    authType: (.data.authType | @base64d),
    insecure: (.data.insecure | @base64d),
    token: "***REDACTED***"
  }'

# -------------------------------------------------------
# UI launchers
# -------------------------------------------------------

# open ArgoCD UI and print credentials
launch_argo:
  #!/usr/bin/env bash
  pw=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
  echo "ArgoCD UI: http://localhost:{{argocd_port}}"
  echo "username: admin"
  echo "password: ${pw}"
  nohup {{browse}} http://localhost:{{argocd_port}} >/dev/null 2>&1 &

# open Platform UI and print credentials
launch_platform:
  #!/usr/bin/env bash
  kubectl wait --for condition=Available=True --timeout=300s deployment/loft --namespace vcluster-platform
  platform_url=$(kubectl get secret -n vcluster-platform loft-router-domain \
    -o jsonpath="{.data.domain}" | base64 -d)
  echo "Platform UI: https://${platform_url}"
  echo "username: admin"
  echo "password: password"
  nohup {{browse}} "https://${platform_url}" >/dev/null 2>&1 &

# -------------------------------------------------------
# Cleanup
# -------------------------------------------------------

# delete all demo ArgoApplications
clean_apps:
  #!/usr/bin/env bash
  echo "Deleting demo ArgoApplications..."
  kubectl delete argocdapplications.management.loft.sh --all-namespaces -l app.kubernetes.io/part-of=argocd-v2-demo 2>/dev/null || true
  for app in demo-nginx demo-guestbook demo-apps-in-apps demo-target-host; do
    kubectl delete argocdapplications.management.loft.sh "${app}" --all-namespaces --ignore-not-found 2>/dev/null || true
  done
  echo "Done"

# delete connector and templates
clean_integration:
  #!/usr/bin/env bash
  echo "Deleting connector..."
  kubectl delete secret local-argocd -n vcluster-platform --ignore-not-found
  echo "Deleting templates..."
  kubectl delete -f templates/ --ignore-not-found 2>/dev/null || true
  echo "Done"

# * tear down everything (KIND cluster)
teardown:
  #!/usr/bin/env bash
  set -euo pipefail
  cd {{tf_kind}} && terraform destroy -auto-approve
