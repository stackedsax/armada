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

# Build a single-job YAML. $1=pool (or "any"), $2=name, $3=sleep seconds.
# Jobs targeting the slurm pool need a toleration for the slinky managed-node
# taint that slurm-operator applies to all slurm-executor worker nodes.
# "any" jobs carry the toleration too so the scheduler is free to place them
# on either pool.
job_yaml() {
  local pool="$1" name="$2" sleep="${3:-60}"

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
              cpu: 200m
              memory: 128Mi
            limits:
              cpu: 200m
              memory: 128Mi
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

# ── any: no pool preference — scheduler picks a pool ─────────────────────────
# Jobs carry the slinky toleration so the scheduler is free to assign them to
# either pool. Armada processes pools in config order, so in practice all jobs
# will land on whichever pool has capacity first. Use this to show "I don't care
# which infrastructure runs my job — Armada will find capacity."

submit_any_pool() {
  echo "Submitting jobs with no pool preference (scheduler fair-shares across Slurm and Armada)..."
  local jobset="demo-any-$(date +%s)-${RANDOM}"
  local jobfile="${TMPDIR_JOBS}/any.yaml"
  {
    echo "queue: ${QUEUE}"
    echo "jobSetId: ${jobset}"
    echo "jobs:"
    job_yaml any any-job-1 60
    job_yaml any any-job-2 60
    job_yaml any any-job-3 60
    job_yaml any any-job-4 60
    job_yaml any any-job-5 60
    job_yaml any any-job-6 60
  } > "$jobfile"
  submit_yaml "$jobfile"
  echo "  jobSetId: ${jobset}"
  echo "  Note: jobs go to whichever pool has capacity (no cross-pool fair-share)"
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
