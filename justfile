set export
set shell := ["bash", "-uc"]

yaml          := justfile_directory()
tf_kind       := justfile_directory() + "/tf-kind"

browse        := if os() == "linux" { "xdg-open "} else { "open" }
copy          := if os() == "linux" { "xsel -ib"} else { "pbcopy" }

argocd_port   := "30950"
platform_ver  := "4.10.0-next.7"
kind_ctx      := "kind-demo-local"

# shorthand - all kubectl/helm against the host cluster, never the vcluster context
kc            := "kubectl --context " + kind_ctx

# this list of available targets
default:
  just --list --unsorted

# -------------------------------------------------------
# Full environment
# -------------------------------------------------------

# * full environment: kind + argocd + platform + connector + templates + open UIs
# requires LICENSE_TOKEN env var: LICENSE_TOKEN=xxx just up
up:
  #!/usr/bin/env bash
  set -euo pipefail

  if [ -z "${LICENSE_TOKEN:-}" ]; then
    echo "ERROR: LICENSE_TOKEN env var is required. Usage: LICENSE_TOKEN=xxx just up"
    exit 1
  fi

  echo "=== 1/7 Initializing terraform ==="
  just tf_init

  echo "=== 2/7 Creating KIND cluster ==="
  just setup_kind

  echo "=== 3/7 Installing ArgoCD ==="
  just setup_argo

  echo "=== 4/7 Installing vCluster Platform (with license) ==="
  just setup_platform

  echo "=== 5/7 Logging into platform ==="
  just platform_login

  echo "=== 6/7 Creating ArgoCD connector + templates ==="
  just setup_connector
  just setup_templates

  echo "=== 7/7 Opening UIs ==="
  just launch_argo
  just launch_platform

  echo ""
  echo "=== Done! ==="
  echo "Next steps:"
  echo "  - Create a tenant cluster: just create_vcluster"
  echo "  - Deploy apps: just deploy_apps"

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
  {{kc}} create namespace argocd --dry-run=client -o yaml | {{kc}} apply -f -
  {{kc}} apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
  {{kc}} wait --for condition=Available=True --timeout=300s deployment/argocd-server --namespace argocd

  echo "Patching server to NodePort {{argocd_port}}..."
  {{kc}} patch svc argocd-server -n argocd -p '{"spec": {"type": "NodePort"}}'
  {{kc}} patch svc argocd-server -n argocd --type='json' \
    -p='[{"op": "replace", "path": "/spec/ports/0/nodePort", "value": {{argocd_port}}}]'

  echo "Disabling TLS + enabling apiKey on admin account..."
  {{kc}} -n argocd patch configmap argocd-cmd-params-cm --type merge \
    -p '{"data":{"server.insecure":"true"}}'
  {{kc}} -n argocd patch configmap argocd-cm --type merge \
    -p '{"data":{"accounts.admin":"apiKey,login"}}'
  {{kc}} -n argocd rollout restart deployment argocd-server
  {{kc}} -n argocd rollout status deployment argocd-server --timeout=120s

  echo "ArgoCD ready on port {{argocd_port}}"

# install vCluster Platform via Helm
# requires LICENSE_TOKEN env var
setup_platform:
  #!/usr/bin/env bash
  set -euo pipefail
  if [ -z "${LICENSE_TOKEN:-}" ]; then
    echo "ERROR: LICENSE_TOKEN env var is required. Usage: LICENSE_TOKEN=xxx just setup_platform"
    exit 1
  fi
  echo "Installing vCluster Platform..."
  helm repo add loft-sh https://charts.loft.sh 2>/dev/null || true
  helm repo update loft-sh
  helm install vcluster-platform loft-sh/vcluster-platform \
    --kube-context {{kind_ctx}} \
    --namespace vcluster-platform --create-namespace \
    --version {{platform_ver}} --devel \
    --set admin.create=true \
    --set admin.username=admin \
    --set admin.password=password \
    --set audit.enableSideCar=false \
    --set config.audit.level=1 \
    --set env.LICENSE_TOKEN="${LICENSE_TOKEN}" \
    --wait --timeout 600s

  echo "Platform {{platform_ver}} installed with license"

# login to platform via CLI
platform_login:
  #!/usr/bin/env bash
  set -euo pipefail
  export platform_url=$({{kc}} get secret -n vcluster-platform loft-router-domain \
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
  pw=$({{kc}} -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
  echo "username: admin"
  echo "password: ${pw}"

# mint a long-lived ArgoCD API token and print it
argo_token:
  #!/usr/bin/env bash
  set -euo pipefail
  ADMIN_PASS=$({{kc}} -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d)

  SESSION=$(curl -sk -X POST http://localhost:{{argocd_port}}/api/v1/session \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"admin\",\"password\":\"${ADMIN_PASS}\"}" \
    | jq -r '.token')
  if [ -z "${SESSION}" ] || [ "${SESSION}" = "null" ]; then
    echo "ERROR: failed to get ArgoCD session. Is ArgoCD running on port {{argocd_port}}?" >&2
    exit 1
  fi

  TOKEN=$(curl -sk -X POST http://localhost:{{argocd_port}}/api/v1/account/admin/token \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${SESSION}" -d '{}' \
    | jq -r '.token')
  if [ -z "${TOKEN}" ] || [ "${TOKEN}" = "null" ]; then
    echo "ERROR: failed to mint ArgoCD API token" >&2
    exit 1
  fi

  echo "${TOKEN}"

# create ArgoCD connector Secret (standard type, in-cluster)
setup_connector:
  #!/usr/bin/env bash
  set -euo pipefail
  echo "Minting ArgoCD API token..."
  TOKEN=$(just argo_token)

  echo "Creating connector Secret..."
  cat <<EOF | {{kc}} apply -f -
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
  {{kc}} patch cluster.management.loft.sh loft-cluster --type merge \
    -p '{"spec":{"argoCD":{"enabled":true,"connector":"local-argocd"}}}'
  echo "ArgoCD enabled on control plane cluster 'loft-cluster'"

# apply all ArgoApplicationTemplates
setup_templates:
  #!/usr/bin/env bash
  set -euo pipefail
  echo "Applying ArgoApplicationTemplates..."
  {{kc}} apply -f templates/
  echo "Templates created:"
  {{kc}} get argocdapplicationtemplates.management.loft.sh 2>/dev/null || echo "  (CRD not available)"

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
  echo ""
  echo "NOTE: kubectl context may have switched. All just targets use --context {{kind_ctx}} explicitly."

# deploy sample ArgoApplications on a tenant cluster
deploy_apps name="my-vcluster" project="default":
  #!/usr/bin/env bash
  set -euo pipefail
  NS="p-{{project}}"

  echo "Deploying nginx (from template) on {{name}}..."
  cat <<EOF | {{kc}} apply -f -
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
      repoURL: "https://github.com/adriankabala/argocd-v2-demo.git"
      targetRevision: "master"
      path: "manifests/nginx"
      targetNamespace: "nginx-demo"
  EOF

  echo "Deploying guestbook (inline) on {{name}}..."
  cat <<EOF | {{kc}} apply -f -
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
        project: default
        source:
          repoURL: "https://github.com/adriankabala/argocd-v2-demo.git"
          targetRevision: master
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
  NS="p-{{project}}"
  CLUSTER_NAME="vcluster-{{project}}-{{name}}"

  echo "Deploying apps-in-apps parent on {{name}}..."
  echo "Child apps will target cluster name: ${CLUSTER_NAME}"

  cat <<EOF | {{kc}} apply -f -
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
        project: default
        source:
          repoURL: "https://github.com/adriankabala/argocd-v2-demo.git"
          targetRevision: master
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
  NS="p-{{project}}"

  echo "WARNING: target:host crosses tenant isolation boundary."
  echo "Deploying on control plane cluster from tenant cluster '{{name}}'..."

  cat <<EOF | {{kc}} apply -f -
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
        project: default
        source:
          repoURL: "https://github.com/adriankabala/argocd-v2-demo.git"
          targetRevision: master
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
  {{kc}} get applications -n argocd -o wide 2>/dev/null || echo "  none"

  echo ""
  echo "=== ArgoCD Applications (Platform CRDs) ==="
  {{kc}} get argocdapplications.management.loft.sh --all-namespaces -o wide 2>/dev/null || echo "  none"

  echo ""
  echo "=== ArgoCD Connectors ==="
  {{kc}} get secrets -n vcluster-platform -l loft.sh/connector-type=argocd \
    -o custom-columns='NAME:.metadata.name,TYPE:.data.connectorType,SERVER:.data.server' 2>/dev/null || echo "  none"

  echo ""
  echo "=== ArgoCD Application Templates ==="
  {{kc}} get argocdapplicationtemplates.management.loft.sh 2>/dev/null || echo "  none"

  echo ""
  echo "=== Tenant Clusters ==="
  {{kc}} get virtualclusterinstances.management.loft.sh --all-namespaces \
    -o custom-columns='NAME:.metadata.name,NAMESPACE:.metadata.namespace,PHASE:.status.phase' 2>/dev/null || echo "  none"

# show reconciler logs (ArgoCD application controller in platform)
logs:
  {{kc}} logs -n vcluster-platform deployment/loft -f --tail=100 | grep -i "argocd\|argo-cd\|connector"

# check connector Secret contents (redacted token)
show_connector name="local-argocd":
  #!/usr/bin/env bash
  echo "Connector: {{name}}"
  {{kc}} get secret {{name}} -n vcluster-platform -o json | jq '{
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
  pw=$({{kc}} -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
  echo "ArgoCD UI: http://localhost:{{argocd_port}}"
  echo "username: admin"
  echo "password: ${pw}"
  nohup {{browse}} http://localhost:{{argocd_port}} >/dev/null 2>&1 &

# open Platform UI and print credentials
launch_platform:
  #!/usr/bin/env bash
  {{kc}} wait --for condition=Available=True --timeout=300s deployment/loft --namespace vcluster-platform
  platform_url=$({{kc}} get secret -n vcluster-platform loft-router-domain \
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
  for app in demo-nginx demo-guestbook demo-apps-in-apps demo-target-host; do
    {{kc}} delete argocdapplications.management.loft.sh "${app}" --all-namespaces --ignore-not-found 2>/dev/null || true
  done
  echo "Done"

# delete connector and templates
clean_integration:
  #!/usr/bin/env bash
  echo "Deleting connector..."
  {{kc}} delete secret local-argocd -n vcluster-platform --ignore-not-found
  echo "Deleting templates..."
  {{kc}} delete -f templates/ --ignore-not-found 2>/dev/null || true
  echo "Done"

# * tear down everything (KIND cluster)
teardown:
  #!/usr/bin/env bash
  set -euo pipefail
  cd {{tf_kind}} && terraform destroy -auto-approve
