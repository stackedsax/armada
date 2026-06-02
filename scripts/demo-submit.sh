#!/usr/bin/env bash
# Armada multi-pool demo: submit jobs to slurm and armada pools.
# Usage:
#   ./demo-submit.sh slurm      - a few jobs pinned to the Slurm pool
#   ./demo-submit.sh armada     - a few jobs pinned to the Armada (K8s) pool
#   ./demo-submit.sh mixed      - large-resource batch that fills capacity across both pools
#   ./demo-submit.sh any        - jobs with no pool preference (scheduler picks a pool)
#   ./demo-submit.sh all        - all of the above (default)

set -euo pipefail

QUEUE="demo"
ARMADA_URL="${ARMADA_URL:-localhost:50051}"
TMPDIR_JOBS=$(mktemp -d)
trap 'rm -rf "$TMPDIR_JOBS"' EXIT

# ── helpers ────────────────────────────────────────────────────────────────────

# Build a single-job YAML.
# $1=pool (or "any"), $2=name, $3=sleep seconds, $4=cpu request, $5=memory request
# Jobs targeting the slurm pool need a toleration for the slinky managed-node
# taint that slurm-operator applies to all slurm-executor worker nodes.
# "any" jobs carry the toleration too so the scheduler is free to place them
# on either pool.
job_yaml() {
  local pool="$1" name="$2" sleep="${3:-60}" cpu="${4:-200m}" mem="${5:-128Mi}"

  local node_selector=""
  if [[ "$pool" != "any" ]]; then
    node_selector="      nodeSelector:
        armadaproject.io/pool: ${pool}"
  fi

  cat <<EOF
  - priority: 1
    namespace: armada
    podSpec:
      terminationGracePeriodSeconds: 0
      tolerations:
      - key: slinky.slurm.net/managed-node
        operator: Exists
        effect: NoExecute
${node_selector}
      containers:
        - name: ${name}
          image: busybox:1.36
          command: [sh, -c]
          args: ["echo Running in pool: ${pool}; sleep ${sleep}"]
          resources:
            requests:
              cpu: ${cpu}
              memory: ${mem}
            limits:
              cpu: ${cpu}
              memory: ${mem}
EOF
}

submit_yaml() {
  local jobfile="$1"
  armadactl submit "$jobfile" --armadaUrl "${ARMADA_URL}"
}

# ── slurm: jobs pinned to the Slurm pool ──────────────────────────────────────

submit_slurm() {
  echo "Submitting jobs to the Slurm pool (routed via slurm-bridge → Slurm)..."
  local jobset="demo-slurm-$(date +%s)-${RANDOM}"
  local jobfile="${TMPDIR_JOBS}/slurm.yaml"
  {
    echo "queue: ${QUEUE}"
    echo "jobSetId: ${jobset}"
    echo "jobs:"
    job_yaml slurm slurm-job-1 60
    job_yaml slurm slurm-job-2 60
    job_yaml slurm slurm-job-3 60
  } > "$jobfile"
  submit_yaml "$jobfile"
  echo "  jobSetId: ${jobset}"
  echo "  View at: http://5.78.201.87:3000"
}

# ── armada: jobs pinned to the Armada (K8s) pool ─────────────────────────────

submit_armada() {
  echo "Submitting jobs to the Armada (K8s) pool (routed to plain Kubernetes)..."
  local jobset="demo-armada-$(date +%s)-${RANDOM}"
  local jobfile="${TMPDIR_JOBS}/armada.yaml"
  {
    echo "queue: ${QUEUE}"
    echo "jobSetId: ${jobset}"
    echo "jobs:"
    job_yaml armada armada-job-1 60
    job_yaml armada armada-job-2 60
    job_yaml armada armada-job-3 60
  } > "$jobfile"
  submit_yaml "$jobfile"
  echo "  jobSetId: ${jobset}"
  echo "  View at: http://5.78.201.87:3000"
}

# ── mixed: large-resource jobs that fill capacity across both pools ────────────
# Each job requests 12 CPU. With 16-CPU worker nodes, only 1 job fits per node.
# slurm pool:  4 workers across 2 clusters  → spreads across slurm-executor and slurm-executor-2
# armada pool: 3 workers across 2 clusters  → spreads across armada-executor and armada-executor-2

submit_mixed() {
  echo "Submitting large-resource mixed batch (forces spreading across clusters)..."
  local jobset="demo-mixed-$(date +%s)-${RANDOM}"
  local jobfile="${TMPDIR_JOBS}/mixed.yaml"

  cat > "$jobfile" <<EOF
queue: ${QUEUE}
jobSetId: ${jobset}
jobs:
  - priority: 1
    namespace: armada
    podSpec:
      terminationGracePeriodSeconds: 0
      tolerations:
      - key: slinky.slurm.net/managed-node
        operator: Exists
        effect: NoExecute
      nodeSelector:
        armadaproject.io/pool: slurm
      containers:
        - name: slurm-batch-1
          image: busybox:1.36
          command: [sh, -c]
          args: ["echo slurm batch 1; sleep 60"]
          resources:
            requests: {cpu: "12", memory: 4Gi}
            limits:   {cpu: "12", memory: 4Gi}
  - priority: 1
    namespace: armada
    podSpec:
      terminationGracePeriodSeconds: 0
      tolerations:
      - key: slinky.slurm.net/managed-node
        operator: Exists
        effect: NoExecute
      nodeSelector:
        armadaproject.io/pool: slurm
      containers:
        - name: slurm-batch-2
          image: busybox:1.36
          command: [sh, -c]
          args: ["echo slurm batch 2; sleep 60"]
          resources:
            requests: {cpu: "12", memory: 4Gi}
            limits:   {cpu: "12", memory: 4Gi}
  - priority: 1
    namespace: armada
    podSpec:
      terminationGracePeriodSeconds: 0
      tolerations:
      - key: slinky.slurm.net/managed-node
        operator: Exists
        effect: NoExecute
      nodeSelector:
        armadaproject.io/pool: slurm
      containers:
        - name: slurm-batch-3
          image: busybox:1.36
          command: [sh, -c]
          args: ["echo slurm batch 3; sleep 60"]
          resources:
            requests: {cpu: "12", memory: 4Gi}
            limits:   {cpu: "12", memory: 4Gi}
  - priority: 1
    namespace: armada
    podSpec:
      terminationGracePeriodSeconds: 0
      tolerations:
      - key: slinky.slurm.net/managed-node
        operator: Exists
        effect: NoExecute
      nodeSelector:
        armadaproject.io/pool: slurm
      containers:
        - name: slurm-batch-4
          image: busybox:1.36
          command: [sh, -c]
          args: ["echo slurm batch 4; sleep 60"]
          resources:
            requests: {cpu: "12", memory: 4Gi}
            limits:   {cpu: "12", memory: 4Gi}
  - priority: 1
    namespace: armada
    podSpec:
      terminationGracePeriodSeconds: 0
      tolerations:
      - key: slinky.slurm.net/managed-node
        operator: Exists
        effect: NoExecute
      nodeSelector:
        armadaproject.io/pool: slurm
      containers:
        - name: slurm-batch-5
          image: busybox:1.36
          command: [sh, -c]
          args: ["echo slurm batch 5; sleep 60"]
          resources:
            requests: {cpu: "12", memory: 4Gi}
            limits:   {cpu: "12", memory: 4Gi}
  - priority: 1
    namespace: armada
    podSpec:
      terminationGracePeriodSeconds: 0
      tolerations:
      - key: slinky.slurm.net/managed-node
        operator: Exists
        effect: NoExecute
      nodeSelector:
        armadaproject.io/pool: slurm
      containers:
        - name: slurm-batch-6
          image: busybox:1.36
          command: [sh, -c]
          args: ["echo slurm batch 6; sleep 60"]
          resources:
            requests: {cpu: "12", memory: 4Gi}
            limits:   {cpu: "12", memory: 4Gi}
  - priority: 1
    namespace: armada
    podSpec:
      terminationGracePeriodSeconds: 0
      nodeSelector:
        armadaproject.io/pool: armada
      containers:
        - name: armada-batch-1
          image: busybox:1.36
          command: [sh, -c]
          args: ["echo armada batch 1; sleep 60"]
          resources:
            requests: {cpu: "12", memory: 4Gi}
            limits:   {cpu: "12", memory: 4Gi}
  - priority: 1
    namespace: armada
    podSpec:
      terminationGracePeriodSeconds: 0
      nodeSelector:
        armadaproject.io/pool: armada
      containers:
        - name: armada-batch-2
          image: busybox:1.36
          command: [sh, -c]
          args: ["echo armada batch 2; sleep 60"]
          resources:
            requests: {cpu: "12", memory: 4Gi}
            limits:   {cpu: "12", memory: 4Gi}
  - priority: 1
    namespace: armada
    podSpec:
      terminationGracePeriodSeconds: 0
      nodeSelector:
        armadaproject.io/pool: armada
      containers:
        - name: armada-batch-3
          image: busybox:1.36
          command: [sh, -c]
          args: ["echo armada batch 3; sleep 60"]
          resources:
            requests: {cpu: "12", memory: 4Gi}
            limits:   {cpu: "12", memory: 4Gi}
  - priority: 1
    namespace: armada
    podSpec:
      terminationGracePeriodSeconds: 0
      nodeSelector:
        armadaproject.io/pool: armada
      containers:
        - name: armada-batch-4
          image: busybox:1.36
          command: [sh, -c]
          args: ["echo armada batch 4; sleep 60"]
          resources:
            requests: {cpu: "12", memory: 4Gi}
            limits:   {cpu: "12", memory: 4Gi}
  - priority: 1
    namespace: armada
    podSpec:
      terminationGracePeriodSeconds: 0
      nodeSelector:
        armadaproject.io/pool: armada
      containers:
        - name: armada-batch-5
          image: busybox:1.36
          command: [sh, -c]
          args: ["echo armada batch 5; sleep 60"]
          resources:
            requests: {cpu: "12", memory: 4Gi}
            limits:   {cpu: "12", memory: 4Gi}
EOF

  submit_yaml "$jobfile"
  echo "  jobSetId: ${jobset}"
  echo "  View at: http://5.78.201.87:3000"
}

# ── any: no pool preference — first-fit with overflow ────────────────────────
# Armada schedules pools in config order (slurm first). Each pool's scheduling
# pass claims as many jobs as its capacity allows; any remainder stays queued for
# the next pool's pass. This is first-fit with overflow, not fair-share.
#
# To make the overflow visible we use large jobs (14 CPU each). The slurm pool
# has 8 workers (4 per cluster × 2 clusters); at 1 job per worker it can absorb
# 8 jobs. Submitting 10 guarantees 2 overflow to the armada pool.

submit_any_pool() {
  echo "Submitting 10 large jobs with no pool preference (first-fit with overflow)..."
  echo "  slurm pool capacity: 8 workers → absorbs jobs 1-8"
  echo "  jobs 9-10 overflow to armada pool"
  local jobset="demo-any-$(date +%s)-${RANDOM}"
  local jobfile="${TMPDIR_JOBS}/any.yaml"
  {
    echo "queue: ${QUEUE}"
    echo "jobSetId: ${jobset}"
    echo "jobs:"
    for i in $(seq 1 10); do
      job_yaml any "any-job-${i}" 60 "14" "20Gi"
    done
  } > "$jobfile"
  submit_yaml "$jobfile"
  echo "  jobSetId: ${jobset}"
  echo "  View at: http://5.78.201.87:3000"
}

# ── entrypoint ─────────────────────────────────────────────────────────────────

MODE="${1:-all}"
case "$MODE" in
  slurm)   submit_slurm ;;
  armada)  submit_armada ;;
  mixed)   submit_mixed ;;
  any)     submit_any_pool ;;
  all)     submit_slurm; echo ""; submit_armada; echo ""; submit_mixed; echo ""; submit_any_pool ;;
  *)       echo "Usage: $0 [slurm|armada|mixed|any|all]"; exit 1 ;;
esac
