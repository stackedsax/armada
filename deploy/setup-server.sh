#!/usr/bin/env bash
# Sets up the kind-armada-server KIND cluster (Armada control plane + Lookout UI).
#
# Prerequisites:
#   - kind, kubectl, helm, docker installed and in PATH
#   - Helm repos: apache, bitnami, dandydev, gresearch, ingress-nginx (added automatically)
#
# Usage:
#   ./deploy/setup-server.sh
#
# Configurable env vars:
#   PUBLIC_IP            — public IP of this host, used for Lookout UI and CORS (required)
#   K8S_IMAGE            — KIND node image (default: kindest/node:v1.35.1)
#   SCHEDULER_IMAGE_REPO — Armada scheduler image repo (must have skipNodeBinding support)
#   SCHEDULER_IMAGE_TAG  — Armada scheduler image tag

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── configurable defaults ──────────────────────────────────────────────────────
K8S_IMAGE="${K8S_IMAGE:-kindest/node:v1.35.1}"
SCHEDULER_IMAGE_REPO="${SCHEDULER_IMAGE_REPO:-stackedsax/armada-scheduler}"
SCHEDULER_IMAGE_TAG="${SCHEDULER_IMAGE_TAG:-slurm-dev}"

if [[ -z "${PUBLIC_IP:-}" ]]; then
  echo "ERROR: PUBLIC_IP must be set to the public IP of this host." >&2
  echo "  e.g. PUBLIC_IP=1.2.3.4 ./deploy/setup-server.sh" >&2
  exit 1
fi

POSTGRESQL_VERSION="18.6.7"
REDIS_HA_VERSION="4.35.10"
PULSAR_VERSION="4.6.0"
INGRESS_NGINX_VERSION="4.15.1"
ARMADA_OPERATOR_VERSION="0.7.0"

# ── helm repos ────────────────────────────────────────────────────────────────
helm repo add apache          https://pulsar.apache.org/charts              --force-update >/dev/null 2>&1
helm repo add bitnami         https://charts.bitnami.com/bitnami            --force-update >/dev/null 2>&1
helm repo add dandydev        https://dandydeveloper.github.io/charts       --force-update >/dev/null 2>&1
helm repo add gresearch        https://g-research.github.io/charts          --force-update >/dev/null 2>&1
helm repo add ingress-nginx   https://kubernetes.github.io/ingress-nginx    --force-update >/dev/null 2>&1
helm repo update >/dev/null 2>&1

# ── create cluster ────────────────────────────────────────────────────────────
if kind get clusters 2>/dev/null | grep -q "^armada-server$"; then
  echo "Cluster armada-server already exists, skipping create"
else
  cat > /tmp/kind-armada-server.yaml <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  image: ${K8S_IMAGE}
EOF
  kind create cluster --name armada-server --config /tmp/kind-armada-server.yaml
fi

# ── ingress-nginx ─────────────────────────────────────────────────────────────
helm upgrade --install nginx ingress-nginx/ingress-nginx \
  --kube-context kind-armada-server \
  -n kube-system \
  --version "${INGRESS_NGINX_VERSION}" \
  --wait --timeout 120s

# ── data namespace: postgresql ────────────────────────────────────────────────
kubectl --context kind-armada-server create namespace data \
  --dry-run=client -o yaml | kubectl --context kind-armada-server apply -f -

PG_INIT_SQL="-- Create databases for Armada components
CREATE DATABASE scheduler;
CREATE DATABASE lookout;"

helm upgrade --install postgresql bitnami/postgresql \
  --kube-context kind-armada-server \
  -n data \
  --version "${POSTGRESQL_VERSION}" \
  --set "settings.superuserPassword.value=psw" \
  --set-string "customScripts.init-databases\\.sql=${PG_INIT_SQL}" \
  --wait --timeout 120s

# ── data namespace: redis HA ──────────────────────────────────────────────────
# Release name is "redis" → service is redis-redis-ha (not redis-ha).
# --no-hooks avoids the test hook that causes a "failed" release status in KIND.
helm upgrade --install redis dandydev/redis-ha \
  --kube-context kind-armada-server \
  -n data \
  --version "${REDIS_HA_VERSION}" \
  --set hardAntiAffinity=false \
  --set replicas=2 \
  --no-hooks \
  --wait --timeout 120s

# ── data namespace: pulsar ────────────────────────────────────────────────────
helm upgrade --install pulsar apache/pulsar \
  --kube-context kind-armada-server \
  -n data \
  --version "${PULSAR_VERSION}" \
  --wait --timeout 300s \
  --values - <<'HELMEOF'
affinity:
  anti_affinity: false
autorecovery:
  podMonitor:
    enabled: false
bookkeeper:
  configData:
    dbStorage_readAheadCacheMaxSizeMb: "32"
    dbStorage_rocksDB_blockCacheSize: "8388608"
    dbStorage_rocksDB_writeBufferSizeMB: "8"
    dbStorage_writeCacheMaxSizeMb: "32"
    diskUsageThreshold: "0.999"
    useHostNameAsBookieID: "true"
  podMonitor:
    enabled: false
  replicaCount: 1
broker:
  configData:
    autoSkipNonRecoverableData: "true"
    managedLedgerDefaultAckQuorum: "1"
    managedLedgerDefaultEnsembleSize: "1"
    managedLedgerDefaultWriteQuorum: "1"
  podMonitor:
    enabled: false
  replicaCount: 1
components:
  autorecovery: false
  bookkeeper: true
  broker: true
  functions: false
  proxy: true
  pulsar_manager: true
  toolset: true
  zookeeper: true
monitoring:
  prometheus: false
proxy:
  podMonitor:
    enabled: false
  replicaCount: 1
volumes:
  persistence: false
zookeeper:
  podMonitor:
    enabled: false
  replicaCount: 1
HELMEOF

# ── armada namespace: operator ────────────────────────────────────────────────
kubectl --context kind-armada-server create namespace armada \
  --dry-run=client -o yaml | kubectl --context kind-armada-server apply -f -

helm upgrade --install armada-operator gresearch/armada-operator \
  --kube-context kind-armada-server \
  --version "${ARMADA_OPERATOR_VERSION}" \
  -n armada --create-namespace \
  --set image.repository=gresearch/armada-operator \
  --set image.tag=latest \
  --wait --timeout 120s

# ── armada namespace: CRs ────────────────────────────────────────────────────
kubectl --context kind-armada-server apply -f - <<EOF
apiVersion: install.armadaproject.io/v1alpha1
kind: ArmadaServer
metadata:
  name: armada-server
  namespace: armada
spec:
  image:
    repository: gresearch/armada-server
    tag: latest
  replicas: 1
  ingress:
    ingressClass: nginx
  pulsarInit: false
  applicationConfig:
    auth:
      anonymousAuth: true
      permissionGroupMapping:
        cancel_any_jobs: [everyone]
        create_queue: [everyone]
        delete_queue: [everyone]
        reprioritize_any_jobs: [everyone]
        submit_any_jobs: [everyone]
        watch_all_events: [everyone]
    corsAllowedOrigins:
    - http://localhost:3000
    - http://localhost:8089
    - http://localhost:10000
    - http://localhost:30000
    - http://${PUBLIC_IP}:3000
    grpcNodePort: 30002
    httpNodePort: 30001
    postgres:
      connection:
        host: postgresql.data.svc.cluster.local
        port: 5432
        user: postgres
        password: psw
        dbname: lookout
        sslmode: disable
    pulsar:
      URL: pulsar://pulsar-broker.data.svc.cluster.local:6650
    redis:
      addrs:
      - redis-redis-ha.data.svc.cluster.local:6379
    eventsApiRedis:
      addrs:
      - redis-redis-ha.data.svc.cluster.local:6379
    queryapi:
      postgres:
        connection:
          host: postgresql.data.svc.cluster.local
          port: 5432
          user: postgres
          password: psw
          dbname: lookout
          sslmode: disable
    schedulerApiConnection:
      armadaUrl: armada-scheduler.armada.svc.cluster.local:50051
      forceNoTls: true
---
apiVersion: install.armadaproject.io/v1alpha1
kind: Scheduler
metadata:
  name: armada-scheduler
  namespace: armada
spec:
  image:
    repository: ${SCHEDULER_IMAGE_REPO}
    tag: ${SCHEDULER_IMAGE_TAG}
  replicas: 1
  migrate: true
  ingress:
    ingressClass: nginx
  applicationConfig:
    auth:
      anonymousAuth: true
      permissionGroupMapping:
        execute_jobs: [everyone]
    grpc:
      port: 50051
    postgres:
      connection:
        host: postgresql.data.svc.cluster.local
        port: 5432
        user: postgres
        password: psw
        dbname: scheduler
        sslmode: disable
    pulsar:
      URL: pulsar://pulsar-broker.data.svc.cluster.local:6650
    armadaApi:
      armadaUrl: armada-server.armada.svc.cluster.local:50051
      forceNoTls: true
    scheduling:
      pools:
      - name: slurm
        skipNodeBinding: true
      - name: armada
---
apiVersion: install.armadaproject.io/v1alpha1
kind: SchedulerIngester
metadata:
  name: armada-scheduler-ingester
  namespace: armada
spec:
  image:
    repository: gresearch/armada-scheduler-ingester
    tag: latest
  replicas: 1
  applicationConfig:
    postgres:
      connection:
        host: postgresql.data.svc.cluster.local
        port: 5432
        user: postgres
        password: psw
        dbname: scheduler
        sslmode: disable
    pulsar:
      URL: pulsar://pulsar-broker.data.svc.cluster.local:6650
---
apiVersion: install.armadaproject.io/v1alpha1
kind: EventIngester
metadata:
  name: armada-event-ingester
  namespace: armada
spec:
  image:
    repository: gresearch/armada-event-ingester
    tag: latest
  replicas: 1
  applicationConfig:
    pulsar:
      URL: pulsar://pulsar-broker.data.svc.cluster.local:6650
    redis:
      addrs:
      - redis-redis-ha.data.svc.cluster.local:6379
---
apiVersion: install.armadaproject.io/v1alpha1
kind: LookoutIngester
metadata:
  name: armada-lookout-ingester
  namespace: armada
spec:
  image:
    repository: gresearch/armada-lookout-ingester
    tag: latest
  applicationConfig:
    postgres:
      connection:
        host: postgresql.data.svc.cluster.local
        port: 5432
        user: postgres
        password: psw
        dbname: lookout
        sslmode: disable
    pulsar:
      URL: pulsar://pulsar-broker.data.svc.cluster.local:6650
---
apiVersion: install.armadaproject.io/v1alpha1
kind: Lookout
metadata:
  name: armada-lookout
  namespace: armada
spec:
  image:
    repository: gresearch/armada-lookout
    tag: latest
  replicas: 1
  migrate: true
  ingress:
    ingressClass: nginx
  applicationConfig:
    apiPort: 8080
    httpNodePort: 30000
    corsAllowedOrigins:
    - http://localhost
    - http://${PUBLIC_IP}:3000
    postgres:
      connection:
        host: postgresql.data.svc.cluster.local
        port: 5432
        user: postgres
        password: psw
        dbname: lookout
        sslmode: disable
    uiConfig:
      armadaApiBaseUrl: http://${PUBLIC_IP}:8081
EOF

# ── scheduler NodePort (exposes gRPC to executor clusters) ────────────────────
kubectl --context kind-armada-server apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: armada-scheduler-nodeport
  namespace: armada
spec:
  type: NodePort
  selector:
    app: armada-scheduler
  ports:
  - name: grpc
    port: 50051
    targetPort: 50051
    nodePort: 30051
EOF

echo ""
echo "=== armada-server cluster ready ==="
echo ""
echo "  Lookout UI:   http://${PUBLIC_IP}:3000/"
echo "  REST API:     http://${PUBLIC_IP}:8081/"
echo "  gRPC:         ${PUBLIC_IP}:50051"
echo ""
echo "  Run ./deploy/apply-iptables.sh on the host to forward public ports."
