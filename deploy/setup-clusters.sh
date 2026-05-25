#!/usr/bin/env bash
# Sets up KIND executor clusters for the Armada multi-pool demo (Slurm + plain K8s).
#
# Prerequisites:
#   - kind, kubectl, helm, docker installed and in PATH
#   - kind-armada-server cluster already running with Armada control plane
#     and gRPC exposed as NodePort 30051
#   - For slurm executor clusters: slurm-bridge images pre-built locally:
#       slurm-bridge-scheduler:dev
#       slurm-bridge-controllers:dev
#       slurm-bridge-admission:dev
#   - SLURM_BRIDGE_CHART: path to the slurm-bridge helm chart directory
#     (default: sibling repo at ../slurm-bridge/helm/slurm-bridge)
#
# Usage:
#   ./deploy/setup-clusters.sh                    # set up all four executor clusters
#   ./deploy/setup-clusters.sh slurm-executor     # one cluster
#   ./deploy/setup-clusters.sh slurm-executor slurm-executor-2  # two clusters
#
# Configurable env vars:
#   SCHEDULER_URL         — override auto-discovered armada-server gRPC address
#   K8S_IMAGE             — KIND node image (default: kindest/node:v1.35.1)
#   EXECUTOR_IMAGE_REPO   — Armada executor image repo (must have skipNodeBinding support)
#   EXECUTOR_IMAGE_TAG    — Armada executor image tag
#   SLURM_BRIDGE_CHART    — path to slurm-bridge helm chart directory

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── configurable defaults ──────────────────────────────────────────────────────
K8S_IMAGE="${K8S_IMAGE:-kindest/node:v1.35.1}"
EXECUTOR_IMAGE_REPO="${EXECUTOR_IMAGE_REPO:-stackedsax/armada-executor}"
EXECUTOR_IMAGE_TAG="${EXECUTOR_IMAGE_TAG:-slurm-dev}"
SLURM_BRIDGE_CHART="${SLURM_BRIDGE_CHART:-${SCRIPT_DIR}/../../slurm-bridge/helm/slurm-bridge}"

CERT_MANAGER_VERSION="v1.20.2"
JOBSET_VERSION="0.12.0"
LWS_VERSION="0.8.0"
SCHEDULER_PLUGINS_VERSION="0.34.7"
SLURM_OPERATOR_VERSION="1.1.0"
ARMADA_OPERATOR_VERSION="0.7.0"

# ── discover scheduler URL from kind-armada-server ────────────────────────────
discover_scheduler_url() {
  if ! kind get clusters 2>/dev/null | grep -q "^armada-server$"; then
    echo "ERROR: kind-armada-server cluster not found. Set up the Armada control plane first." >&2
    exit 1
  fi
  local ip
  ip=$(kubectl --context kind-armada-server get nodes \
    -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
  if [[ -z "$ip" ]]; then
    echo "ERROR: could not determine IP of kind-armada-server control-plane node." >&2
    exit 1
  fi
  echo "${ip}:30051"
}

SCHEDULER_URL="${SCHEDULER_URL:-$(discover_scheduler_url)}"
echo "Using scheduler URL: ${SCHEDULER_URL}"

# ── helpers ────────────────────────────────────────────────────────────────────
write_kind_config() {
  local name="$1" workers="$2"
  local f="/tmp/kind-${name}.yaml"
  {
    echo "kind: Cluster"
    echo "apiVersion: kind.x-k8s.io/v1alpha4"
    echo "nodes:"
    echo "- role: control-plane"
    echo "  image: ${K8S_IMAGE}"
    for _ in $(seq 1 "$workers"); do
      echo "- role: worker"
      echo "  image: ${K8S_IMAGE}"
    done
  } > "$f"
}

create_cluster_if_missing() {
  local name="$1" workers="$2"
  if kind get clusters 2>/dev/null | grep -q "^${name}$"; then
    echo "Cluster ${name} already exists, skipping create"
  else
    write_kind_config "$name" "$workers"
    kind create cluster --name "$name" --config "/tmp/kind-${name}.yaml"
  fi
}

install_cert_manager() {
  local cluster="$1"
  helm upgrade --install cert-manager cert-manager \
    --kube-context "kind-${cluster}" \
    --repo https://charts.jetstack.io \
    -n cert-manager --create-namespace \
    --set crds.enabled=true \
    --version "${CERT_MANAGER_VERSION}" \
    --wait --timeout 120s
}

# ── slurm executor setup ───────────────────────────────────────────────────────
setup_slurm_executor() {
  local cluster="$1" cluster_id="$2"
  echo ""
  echo "======================================================"
  echo " Setting up slurm executor: ${cluster} (${cluster_id})"
  echo "======================================================"

  if [[ ! -d "${SLURM_BRIDGE_CHART}" ]]; then
    echo "ERROR: slurm-bridge helm chart not found at: ${SLURM_BRIDGE_CHART}" >&2
    echo "Build the slurm-bridge images and set SLURM_BRIDGE_CHART to the chart path." >&2
    exit 1
  fi

  install_cert_manager "${cluster}"

  helm upgrade --install jobset \
    oci://registry.k8s.io/jobset/charts/jobset \
    --kube-context "kind-${cluster}" \
    --version "${JOBSET_VERSION}" \
    -n jobset-system --create-namespace \
    --wait --timeout 120s

  helm upgrade --install lws \
    oci://registry.k8s.io/lws/charts/lws \
    --kube-context "kind-${cluster}" \
    --version "${LWS_VERSION}" \
    -n lws-system --create-namespace \
    --wait --timeout 120s

  helm upgrade --install scheduler-plugins scheduler-plugins \
    --repo https://scheduler-plugins.sigs.k8s.io \
    --kube-context "kind-${cluster}" \
    --version "${SCHEDULER_PLUGINS_VERSION}" \
    -n scheduler-plugins --create-namespace \
    --wait --timeout 120s

  helm upgrade --install slurm-operator-crds \
    oci://ghcr.io/slinkyproject/charts/slurm-operator-crds \
    --kube-context "kind-${cluster}" \
    --version "${SLURM_OPERATOR_VERSION}" \
    -n slurm --create-namespace \
    --wait --timeout 120s

  helm upgrade --install slurm-operator \
    oci://ghcr.io/slinkyproject/charts/slurm-operator \
    --kube-context "kind-${cluster}" \
    --version "${SLURM_OPERATOR_VERSION}" \
    --set crds.enabled=false \
    -n slurm \
    --wait --timeout 120s

  # Label worker nodes before installing slurm so slurmd DaemonSet can schedule immediately.
  for node in $(kubectl --context "kind-${cluster}" get nodes -o name | grep worker); do
    kubectl --context "kind-${cluster}" label "$node" \
      scheduler.slinky.slurm.net/slurm-bridge=worker \
      --overwrite
    kubectl --context "kind-${cluster}" taint "$node" \
      slinky.slurm.net/managed-node=slurm-bridge-scheduler:NoExecute \
      --overwrite 2>/dev/null || true
  done

  helm upgrade --install slurm \
    oci://ghcr.io/slinkyproject/charts/slurm \
    --kube-context "kind-${cluster}" \
    --version "${SLURM_OPERATOR_VERSION}" \
    -n slurm \
    --wait --timeout 300s \
    --values - <<'HELMEOF'
nodesets:
  slinky:
    enabled: false
  slurm-bridge:
    enabled: true
    logfile:
      image:
        repository: docker.io/library/alpine
        tag: latest
    partition:
      enabled: true
    podSpec:
      nodeSelector:
        kubernetes.io/os: linux
        scheduler.slinky.slurm.net/slurm-bridge: worker
      tolerations:
      - effect: NoExecute
        key: slinky.slurm.net/managed-node
        operator: Equal
        value: slurm-bridge-scheduler
    scalingMode: DaemonSet
    slurmd:
      image:
        repository: ghcr.io/slinkyproject/slurmd
        tag: 25.11-ubuntu24.04
      resources: {}
HELMEOF

  kind load docker-image slurm-bridge-scheduler:dev   --name "${cluster}"
  kind load docker-image slurm-bridge-controllers:dev --name "${cluster}"
  kind load docker-image slurm-bridge-admission:dev   --name "${cluster}"

  # Create slinky namespace and Token CR before slurm-bridge install.
  # slurm-operator (already running) watches Token CRs and creates the slurm-bridge-token
  # secret. The slurm-bridge pods won't start without it, so we must create it first.
  kubectl --context "kind-${cluster}" create namespace slinky \
    --dry-run=client -o yaml | kubectl --context "kind-${cluster}" apply -f -

  kubectl --context "kind-${cluster}" apply -f - <<'EOF'
apiVersion: slinky.slurm.net/v1beta1
kind: Token
metadata:
  name: slurm-bridge-token
  namespace: slinky
spec:
  jwtKeyRef:
    key: jwt.key
    name: slurm-auth-jwt
    namespace: slurm
  lifetime: 8760h
  refresh: true
  secretRef:
    key: auth-token
    name: slurm-bridge-token
  username: slurm
EOF

  echo "Waiting for slurm-bridge-token secret to be created by slurm-operator..."
  until kubectl --context "kind-${cluster}" get secret slurm-bridge-token -n slinky &>/dev/null; do
    sleep 3
  done
  echo "slurm-bridge-token secret ready"

  helm upgrade --install slurm-bridge "${SLURM_BRIDGE_CHART}" \
    --kube-context "kind-${cluster}" \
    -n slinky \
    --wait --timeout 120s \
    --values - <<'HELMEOF'
admission:
  image:
    pullPolicy: Never
    repository: slurm-bridge-admission
    tag: dev
controllers:
  image:
    pullPolicy: Never
    repository: slurm-bridge-controllers
    tag: dev
scheduler:
  image:
    pullPolicy: Never
    repository: slurm-bridge-scheduler
    tag: dev
schedulerConfig:
  partition: slurm-bridge
HELMEOF

  kubectl --context "kind-${cluster}" create namespace armada \
    --dry-run=client -o yaml | kubectl --context "kind-${cluster}" apply -f -

  kubectl --context "kind-${cluster}" apply -f - <<'EOF'
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: armada-default
value: 1000
globalDefault: false
EOF

  helm upgrade --install armada-operator armada-operator \
    --repo https://g-research.github.io/charts \
    --kube-context "kind-${cluster}" \
    --version "${ARMADA_OPERATOR_VERSION}" \
    -n armada --create-namespace \
    --set image.repository=gresearch/armada-operator \
    --set image.tag=latest \
    --wait --timeout 120s

  kubectl --context "kind-${cluster}" apply -f - <<EOF
apiVersion: install.armadaproject.io/v1alpha1
kind: Executor
metadata:
  name: armada-executor
  namespace: armada
spec:
  image:
    repository: ${EXECUTOR_IMAGE_REPO}
    tag: ${EXECUTOR_IMAGE_TAG}
  replicas: 1
  applicationConfig:
    application:
      clusterId: ${cluster_id}
      pool: slurm
      skipNodeBinding: true
    executorApiConnection:
      armadaUrl: ${SCHEDULER_URL}
      forceNoTls: true
    kubernetes:
      minimumPodAge: 0s
      failedPodExpiry: 10m
      podDefaults:
        schedulerName: slurm-bridge-scheduler
      trackedNodeLabels:
      - armadaproject.io/pool
    metric:
      port: 9001
  podSecurityContext:
    runAsUser: 1000
    runAsGroup: 2000
EOF

  for node in $(kubectl --context "kind-${cluster}" get nodes -o name | grep worker); do
    kubectl --context "kind-${cluster}" label "$node" armadaproject.io/pool=slurm --overwrite
  done

  echo "✓ ${cluster} ready"
}

# ── armada executor setup ──────────────────────────────────────────────────────
setup_armada_executor() {
  local cluster="$1" cluster_id="$2"
  echo ""
  echo "======================================================"
  echo " Setting up armada executor: ${cluster} (${cluster_id})"
  echo "======================================================"

  install_cert_manager "${cluster}"

  kubectl --context "kind-${cluster}" create namespace armada \
    --dry-run=client -o yaml | kubectl --context "kind-${cluster}" apply -f -

  kubectl --context "kind-${cluster}" apply -f - <<'EOF'
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: armada-default
value: 1000
globalDefault: false
EOF

  helm upgrade --install armada-operator armada-operator \
    --repo https://g-research.github.io/charts \
    --kube-context "kind-${cluster}" \
    --version "${ARMADA_OPERATOR_VERSION}" \
    -n armada --create-namespace \
    --set image.repository=gresearch/armada-operator \
    --set image.tag=latest \
    --wait --timeout 120s

  kubectl --context "kind-${cluster}" apply -f - <<EOF
apiVersion: install.armadaproject.io/v1alpha1
kind: Executor
metadata:
  name: armada-executor
  namespace: armada
spec:
  image:
    repository: ${EXECUTOR_IMAGE_REPO}
    tag: ${EXECUTOR_IMAGE_TAG}
  replicas: 1
  applicationConfig:
    application:
      clusterId: ${cluster_id}
      pool: armada
    executorApiConnection:
      armadaUrl: ${SCHEDULER_URL}
      forceNoTls: true
    kubernetes:
      minimumPodAge: 0s
      failedPodExpiry: 10m
      podDefaults:
        schedulerName: default-scheduler
      trackedNodeLabels:
      - armadaproject.io/pool
    metric:
      port: 9001
  podSecurityContext:
    runAsUser: 1000
    runAsGroup: 2000
EOF

  for node in $(kubectl --context "kind-${cluster}" get nodes -o name | grep worker); do
    kubectl --context "kind-${cluster}" label "$node" armadaproject.io/pool=armada --overwrite
  done

  echo "✓ ${cluster} ready"
}

# ── cluster dispatch ───────────────────────────────────────────────────────────
run_cluster() {
  local name="$1"
  case "$name" in
    slurm-executor)
      create_cluster_if_missing slurm-executor 4
      setup_slurm_executor slurm-executor slurm-executor
      ;;
    slurm-executor-2)
      create_cluster_if_missing slurm-executor-2 4
      setup_slurm_executor slurm-executor-2 slurm-executor-2
      ;;
    armada-executor)
      create_cluster_if_missing armada-executor 3
      setup_armada_executor armada-executor armada-executor
      ;;
    armada-executor-2)
      create_cluster_if_missing armada-executor-2 3
      setup_armada_executor armada-executor-2 armada-executor-2
      ;;
    *)
      echo "Unknown cluster: ${name}" >&2
      echo "Valid targets: slurm-executor  slurm-executor-2  armada-executor  armada-executor-2" >&2
      exit 1
      ;;
  esac
}

# ── entrypoint ─────────────────────────────────────────────────────────────────
TARGETS=("$@")
if [[ ${#TARGETS[@]} -eq 0 ]]; then
  TARGETS=(slurm-executor slurm-executor-2 armada-executor armada-executor-2)
fi

for target in "${TARGETS[@]}"; do
  run_cluster "$target"
done

echo ""
echo "=== Done ==="
kind get clusters
