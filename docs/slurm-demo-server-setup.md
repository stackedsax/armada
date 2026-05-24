# Slurm Demo Server Setup

This guide reproduces the Armada multi-pool Slurm demo on a single Linux server using
[kind](https://kind.sigs.k8s.io/). You will end up with five kind clusters:

| Cluster | Role |
|---|---|
| `armada-server` | Armada control plane (scheduler, server, Lookout, Pulsar, Postgres) |
| `slurm-executor` | Slurm + slurm-bridge + Armada executor (pool: slurm) |
| `slurm-executor-2` | Slurm + slurm-bridge + Armada executor (pool: slurm) |
| `armada-executor` | Plain K8s + Armada executor (pool: armada) |
| `armada-executor-2` | Plain K8s + Armada executor (pool: armada) |

## Server requirements

- 16+ CPU cores, 64+ GB RAM (each kind cluster gets full node resources; kind nodes
  share the host's CPUs)
- Linux (Ubuntu 22.04 or similar)
- Outbound internet access for pulling images

## 1. Install tools

```bash
# Docker
curl -fsSL https://get.docker.com | sh

# kind
curl -Lo /usr/local/bin/kind \
  https://kind.sigs.k8s.io/dl/v0.24.0/kind-linux-amd64
chmod +x /usr/local/bin/kind

# kubectl
curl -Lo /usr/local/bin/kubectl \
  "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x /usr/local/bin/kubectl

# helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

## 2. Increase inotify limits

Five kind clusters with many pods will exhaust the default inotify limits.

```bash
sysctl -w fs.inotify.max_user_instances=2048
sysctl -w fs.inotify.max_user_watches=1048576

# Persist across reboots
cat >> /etc/sysctl.conf <<EOF
fs.inotify.max_user_instances=2048
fs.inotify.max_user_watches=1048576
EOF
```

## 3. Build and push Armada images

The `SkipNodeBinding` feature in the scheduler is not yet in an upstream release. Build
from this branch and push to a container registry (Docker Hub shown here).

```bash
# On a machine with Go ≥ 1.22 and Docker
git clone https://github.com/stackedsax/armada.git -b slurm-skip-node-binding
cd armada

# Build for linux/amd64 (required when building on Apple Silicon for a Linux server)
GOOS=linux GOARCH=amd64 go build -o bin/armada-scheduler ./cmd/scheduler
GOOS=linux GOARCH=amd64 go build -o bin/armada-executor ./cmd/executor

docker build --platform linux/amd64 -f ./build/scheduler/Dockerfile \
  -t <your-dockerhub-user>/armada-scheduler:slurm-dev .
docker build --platform linux/amd64 -f ./build/executor/Dockerfile \
  -t <your-dockerhub-user>/armada-executor:slurm-dev .

docker push <your-dockerhub-user>/armada-scheduler:slurm-dev
docker push <your-dockerhub-user>/armada-executor:slurm-dev
```

## 4. Build slurm-bridge images

slurm-bridge is not yet published to a public registry. Build on any machine with Docker
and load the images into each slurm kind cluster.

```bash
git clone --depth=1 https://github.com/SlinkyProject/slurm-bridge.git
cd slurm-bridge

# Patch the kubeVersion constraint (slurm-bridge requires >= 1.34; kind ships 1.32)
sed -i 's/kubeVersion: .*/kubeVersion: ">= 1.29.0-0"/' helm/slurm-bridge/Chart.yaml

docker build --target scheduler   -t slurm-bridge-scheduler:dev   .
docker build --target admission   -t slurm-bridge-admission:dev   .
docker build --target controllers -t slurm-bridge-controllers:dev .
```

Keep the `slurm-bridge` directory handy — you will reference its Helm chart during
executor setup.

## 5. Create the armada-server cluster

```bash
kind create cluster --name armada-server
```

### Install armada-operator

```bash
git clone https://github.com/armadaproject/armada-operator.git
helm upgrade --install armada-operator \
  armada-operator/charts/armada-operator \
  --kube-context kind-armada-server \
  -n armada --create-namespace --wait
```

### Deploy the Armada control plane

Apply the following CRs. Replace `<SCHEDULER_IMAGE_REPO>` with your Docker Hub repo from
step 3. The `scheduling.pools` config enables `skipNodeBinding` for the slurm pool and
defines a plain `armada` pool.

```yaml
# armada-server.yaml
apiVersion: install.armadaproject.io/v1alpha1
kind: Scheduler
metadata:
  name: armada-scheduler
  namespace: armada
spec:
  replicas: 1
  image:
    repository: <SCHEDULER_IMAGE_REPO>/armada-scheduler
    tag: slurm-dev
  applicationConfig:
    grpc:
      port: 50051
    auth:
      anonymousAuth: true
      permissionGroupMapping:
        execute_jobs: [everyone]
    pulsar:
      URL: pulsar://pulsar-broker.data.svc.cluster.local:6650
    postgres:
      connection:
        host: postgresql.data.svc.cluster.local
        dbname: scheduler
        user: postgres
        password: psw
        port: 5432
        sslmode: disable
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
kind: ArmadaServer
metadata:
  name: armada-server
  namespace: armada
spec:
  replicas: 1
  image:
    repository: gresearch/armada-server
    tag: latest
  applicationConfig:
    auth:
      anonymousAuth: true
      permissionGroupMapping:
        submit_any_jobs: [everyone]
        cancel_any_jobs: [everyone]
        reprioritize_any_jobs: [everyone]
        watch_all_events: [everyone]
        create_queue: [everyone]
        delete_queue: [everyone]
    grpcNodePort: 30002
    httpNodePort: 30001
    pulsar:
      URL: pulsar://pulsar-broker.data.svc.cluster.local:6650
    redis:
      addrs: [redis-ha.data.svc.cluster.local:6379]
    eventsApiRedis:
      addrs: [redis-ha.data.svc.cluster.local:6379]
    schedulerApiConnection:
      armadaUrl: armada-scheduler.armada.svc.cluster.local:50051
      forceNoTls: true
---
apiVersion: install.armadaproject.io/v1alpha1
kind: Lookout
metadata:
  name: armada-lookout
  namespace: armada
spec:
  replicas: 1
  image:
    repository: gresearch/armada-lookout
    tag: latest
  applicationConfig:
    httpNodePort: 30000
    apiPort: 8080
    corsAllowedOrigins:
      - http://<SERVER_PUBLIC_IP>:3000
    postgres:
      connection:
        host: postgresql.data.svc.cluster.local
        dbname: lookout
        user: postgres
        password: psw
        port: 5432
        sslmode: disable
    uiConfig:
      armadaApiBaseUrl: http://<SERVER_PUBLIC_IP>:8081
```

```bash
kubectl --context kind-armada-server apply -f armada-server.yaml
```

Also apply `LookoutIngester`, `EventIngester`, and `SchedulerIngester` CRs pointing at
the same Pulsar and Postgres services (see the armada-operator docs for examples).

### Create the demo queue

```bash
armadactl create queue demo --priority-factor 1
```

## 6. Set up slurm executor clusters

Repeat for both `slurm-executor` and `slurm-executor-2`.

### Create the cluster

```bash
cat > /tmp/kind-slurm-executor.yaml <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
  - role: worker
  - role: worker
  - role: worker
EOF

kind create cluster --name slurm-executor --config /tmp/kind-slurm-executor.yaml
```

### Label and taint slurm-bridge worker nodes

The last two workers are dedicated to Slurm; the other two handle Armada's executor pod
and system workloads.

```bash
for node in $(kubectl --context kind-slurm-executor get nodes -o name | grep worker | tail -2); do
  kubectl --context kind-slurm-executor label $node \
    scheduler.slinky.slurm.net/slurm-bridge=worker --overwrite
  kubectl --context kind-slurm-executor taint $node \
    slinky.slurm.net/managed-node=slurm-bridge-scheduler:NoExecute --overwrite
done
```

### Install dependencies

```bash
# cert-manager
helm upgrade --install cert-manager cert-manager \
  --kube-context kind-slurm-executor \
  --repo https://charts.jetstack.io \
  -n cert-manager --create-namespace \
  --set crds.enabled=true --version v1.20.2 --wait

# jobset, lws, scheduler-plugins (CoScheduling)
helm upgrade --install jobset oci://registry.k8s.io/jobset/charts/jobset \
  --kube-context kind-slurm-executor \
  -n jobset-system --create-namespace --wait

helm upgrade --install lws oci://registry.k8s.io/lws/charts/lws \
  --kube-context kind-slurm-executor \
  -n lws-system --create-namespace --wait

helm upgrade --install scheduler-plugins scheduler-plugins \
  --kube-context kind-slurm-executor \
  --repo https://scheduler-plugins.sigs.k8s.io \
  -n scheduler-plugins --create-namespace \
  --set plugins.enabled='{CoScheduling}' --wait

# slurm-operator
helm upgrade --install slurm-operator-crds \
  oci://ghcr.io/slinkyproject/charts/slurm-operator-crds \
  --kube-context kind-slurm-executor \
  -n slurm --create-namespace --wait

helm upgrade --install slurm-operator \
  oci://ghcr.io/slinkyproject/charts/slurm-operator \
  --kube-context kind-slurm-executor \
  -n slurm --wait
```

### Deploy the Slurm cluster

```bash
helm upgrade --install slurm oci://ghcr.io/slinkyproject/charts/slurm \
  --version 1.1.0 \
  --kube-context kind-slurm-executor \
  -n slurm --wait --timeout=10m \
  --values - <<EOF
nodesets:
  slinky:
    enabled: false
  slurm-bridge:
    enabled: true
    scalingMode: DaemonSet
    slurmd:
      image:
        repository: ghcr.io/slinkyproject/slurmd
        tag: 25.11-ubuntu24.04
    partition:
      enabled: true
    podSpec:
      nodeSelector:
        kubernetes.io/os: linux
        scheduler.slinky.slurm.net/slurm-bridge: worker
      tolerations:
        - key: slinky.slurm.net/managed-node
          operator: Equal
          value: slurm-bridge-scheduler
          effect: NoExecute
EOF
```

Verify Slurm is up:

```bash
kubectl --context kind-slurm-executor exec -n slurm slurm-controller-0 -- sinfo
# PARTITION     AVAIL  TIMELIMIT  NODES  STATE NODELIST
# slurm-bridge     up   infinite      2   idle ...
```

### Deploy slurm-bridge

```bash
kind load docker-image slurm-bridge-scheduler:dev   --name slurm-executor
kind load docker-image slurm-bridge-admission:dev   --name slurm-executor
kind load docker-image slurm-bridge-controllers:dev --name slurm-executor

# Create the JWT token resource slurm-bridge needs
kubectl --context kind-slurm-executor create namespace slinky
kubectl --context kind-slurm-executor apply -n slinky -f - <<EOF
apiVersion: slinky.slurm.net/v1beta1
kind: Token
metadata:
  name: slurm-bridge-token
spec:
  secretRef:
    name: slurm-auth-jwt
    namespace: slurm
EOF

helm upgrade --install slurm-bridge slurm-bridge/helm/slurm-bridge \
  --kube-context kind-slurm-executor \
  -n slinky --wait \
  --set scheduler.image.repository=slurm-bridge-scheduler \
  --set scheduler.image.tag=dev \
  --set scheduler.image.pullPolicy=Never \
  --set admission.image.repository=slurm-bridge-admission \
  --set admission.image.tag=dev \
  --set admission.image.pullPolicy=Never \
  --set controllers.image.repository=slurm-bridge-controllers \
  --set controllers.image.tag=dev \
  --set controllers.image.pullPolicy=Never \
  --set schedulerConfig.partition=slurm-bridge
```

### Deploy the Armada executor

```bash
kubectl --context kind-slurm-executor create namespace armada
kubectl --context kind-slurm-executor apply -f - <<EOF
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: armada-default
value: 1000
globalDefault: false
EOF

helm upgrade --install armada-operator armada-operator/charts/armada-operator \
  --kube-context kind-slurm-executor \
  -n armada --wait

kubectl --context kind-slurm-executor apply -f - <<EOF
apiVersion: install.armadaproject.io/v1alpha1
kind: Executor
metadata:
  name: armada-executor
  namespace: armada
spec:
  replicas: 1
  image:
    repository: <EXECUTOR_IMAGE_REPO>/armada-executor
    tag: slurm-dev
  applicationConfig:
    application:
      clusterId: slurm-executor      # unique name shown in Lookout
      pool: slurm
      skipNodeBinding: true
    executorApiConnection:
      armadaUrl: <ARMADA_SERVER_CONTROL_PLANE_IP>:30051
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
EOF

# Label all worker nodes with the pool so pool-based nodeSelectors match
for node in $(kubectl --context kind-slurm-executor get nodes -o name | grep worker); do
  kubectl --context kind-slurm-executor label $node armadaproject.io/pool=slurm --overwrite
done
```

The armada-server control-plane IP is:
```bash
kubectl --context kind-armada-server get node armada-server-control-plane \
  -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'
```

Repeat the entire section for `slurm-executor-2`, changing `clusterId` to
`slurm-executor-2`.

## 7. Set up armada executor clusters

Repeat for both `armada-executor` and `armada-executor-2`.

```bash
cat > /tmp/kind-armada-executor.yaml <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
  - role: worker
  - role: worker
EOF

kind create cluster --name armada-executor --config /tmp/kind-armada-executor.yaml
```

```bash
kubectl --context kind-armada-executor create namespace armada
kubectl --context kind-armada-executor apply -f - <<EOF
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: armada-default
value: 1000
globalDefault: false
EOF

helm upgrade --install cert-manager cert-manager \
  --kube-context kind-armada-executor \
  --repo https://charts.jetstack.io \
  -n cert-manager --create-namespace \
  --set crds.enabled=true --version v1.20.2 --wait

helm upgrade --install armada-operator armada-operator/charts/armada-operator \
  --kube-context kind-armada-executor \
  -n armada --wait

kubectl --context kind-armada-executor apply -f - <<EOF
apiVersion: install.armadaproject.io/v1alpha1
kind: Executor
metadata:
  name: armada-executor
  namespace: armada
spec:
  replicas: 1
  image:
    repository: <EXECUTOR_IMAGE_REPO>/armada-executor
    tag: slurm-dev
  applicationConfig:
    application:
      clusterId: armada-executor     # unique name shown in Lookout
      pool: armada
    executorApiConnection:
      armadaUrl: <ARMADA_SERVER_CONTROL_PLANE_IP>:30051
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
EOF

for node in $(kubectl --context kind-armada-executor get nodes -o name | grep worker); do
  kubectl --context kind-armada-executor label $node armadaproject.io/pool=armada --overwrite
done
```

Repeat for `armada-executor-2`, changing `clusterId` to `armada-executor-2`.

## 8. Expose ports externally

kind NodePort services are only reachable from within the Docker bridge network
(`172.18.0.0/16`). To expose them on the server's public IP, add iptables DNAT rules.

Get the armada-server control-plane IP:
```bash
docker inspect armada-server-control-plane \
  --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'
# e.g. 172.18.0.3
```

```bash
CONTROL_PLANE_IP=172.18.0.3   # replace with your actual IP

# DNAT: public port → NodePort
iptables -t nat -A PREROUTING -p tcp --dport 3000  -j DNAT --to-destination ${CONTROL_PLANE_IP}:30000
iptables -t nat -A PREROUTING -p tcp --dport 8081  -j DNAT --to-destination ${CONTROL_PLANE_IP}:30001
iptables -t nat -A PREROUTING -p tcp --dport 50051 -j DNAT --to-destination ${CONTROL_PLANE_IP}:30002

# FORWARD: allow traffic to/from the Docker bridge
# (required when the FORWARD chain policy is DROP, which Docker sets by default)
iptables -I FORWARD -d 172.18.0.0/16 -j ACCEPT
iptables -I FORWARD -s 172.18.0.0/16 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
```

### Make iptables rules persistent

```bash
apt-get install -y iptables-persistent
iptables-save > /etc/iptables/rules.v4
```

Or add the `iptables` commands to a systemd service or `/etc/rc.local` if you prefer.

## 9. Verify

```bash
# All 5 clusters running
kind get clusters
# armada-executor
# armada-executor-2
# armada-server
# slurm-executor
# slurm-executor-2

# Armada executor pods healthy on each cluster
kubectl --context kind-slurm-executor   get pods -n armada
kubectl --context kind-slurm-executor-2 get pods -n armada
kubectl --context kind-armada-executor  get pods -n armada
kubectl --context kind-armada-executor-2 get pods -n armada

# Executors reporting to scheduler (look for "Requesting N new jobs")
kubectl --context kind-slurm-executor logs -n armada deployment/armada-executor -f
```

Then run the demo:

```bash
# From a laptop with armadactl configured
./scripts/demo-submit.sh all
```

See [slurm-integration-demo.md](slurm-integration-demo.md) for what to observe.
