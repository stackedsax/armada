#!/usr/bin/env bash
# Armada multi-pool demo: submit jobs to slurm and armada pools.
# Usage:
#   ./demo-submit.sh individual   - one job per pool
#   ./demo-submit.sh mixed        - batch of jobs across both pools (large resource requests force cluster spreading)
#   ./demo-submit.sh any          - jobs with no pool preference (scheduler decides)
#   ./demo-submit.sh all          - all of the above (default)

set -euo pipefail

QUEUE="demo"
TMPDIR_JOBS=$(mktemp -d)
trap 'rm -rf "$TMPDIR_JOBS"' EXIT

# ── helpers ────────────────────────────────────────────────────────────────────

submit_job() {
  local pool="$1" name="$2" sleep="${3:-30}"
  local jobfile="${TMPDIR_JOBS}/${name}.yaml"
  cat > "$jobfile" <<EOF
queue: ${QUEUE}
jobSetId: demo-${pool}-$(date +%s)-${RANDOM}
jobs:
  - priority: 1
    namespace: armada
    podSpec:
      terminationGracePeriodSeconds: 0
      nodeSelector:
        armadaproject.io/pool: ${pool}
      containers:
        - name: ${name}
          image: busybox:1.36
          command: [sh, -c]
          args: ["echo Running in pool: ${pool}; sleep ${sleep}"]
          resources:
            requests:
              cpu: 100m
              memory: 64Mi
            limits:
              cpu: 100m
              memory: 64Mi
EOF
  armadactl submit "$jobfile"
}

# ── individual: one job per pool ───────────────────────────────────────────────

submit_individual() {
  echo "Submitting one job to each pool..."

  echo ""
  echo "→ Pool: slurm  (routed to Slurm cluster via slurm-bridge)"
  submit_job slurm slurm-job 60

  echo ""
  echo "→ Pool: armada  (routed to plain K8s cluster)"
  submit_job armada armada-job 60

  echo ""
  echo "Individual jobs submitted. View at: http://5.78.201.87:3000"
}

# ── mixed: large-resource jobs that force spreading across both clusters per pool
# Each job requests 12 CPU. With 16-CPU worker nodes, only 1 job fits per node.
# slurm pool: 4 workers per cluster → fills slurm-executor after 4 jobs, next 2 go to slurm-executor-2.
# armada pool: 3 workers per cluster → fills armada-executor after 3 jobs, next 2 go to armada-executor-2.

submit_mixed() {
  echo "Submitting mixed batch across all pools (large resource requests to spread across clusters)..."
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

  armadactl submit "$jobfile"
  echo ""
  echo "Mixed batch submitted (jobSetId: ${jobset})."
  echo "View at: http://5.78.201.87:3000"
}

# ── any: jobs with no pool preference — scheduler assigns to any available cluster

submit_any_pool() {
  echo "Submitting jobs with no pool preference (scheduler decides)..."
  local jobset="demo-any-$(date +%s)-${RANDOM}"
  local jobfile="${TMPDIR_JOBS}/any.yaml"

  cat > "$jobfile" <<EOF
queue: ${QUEUE}
jobSetId: ${jobset}
jobs:
  - priority: 1
    namespace: armada
    podSpec:
      terminationGracePeriodSeconds: 0
      containers:
        - name: any-job-1
          image: busybox:1.36
          command: [sh, -c]
          args: ["echo any-job-1: assigned by scheduler; sleep 60"]
          resources:
            requests: {cpu: 100m, memory: 64Mi}
            limits:   {cpu: 100m, memory: 64Mi}
  - priority: 1
    namespace: armada
    podSpec:
      terminationGracePeriodSeconds: 0
      containers:
        - name: any-job-2
          image: busybox:1.36
          command: [sh, -c]
          args: ["echo any-job-2: assigned by scheduler; sleep 60"]
          resources:
            requests: {cpu: 100m, memory: 64Mi}
            limits:   {cpu: 100m, memory: 64Mi}
  - priority: 1
    namespace: armada
    podSpec:
      terminationGracePeriodSeconds: 0
      containers:
        - name: any-job-3
          image: busybox:1.36
          command: [sh, -c]
          args: ["echo any-job-3: assigned by scheduler; sleep 60"]
          resources:
            requests: {cpu: 100m, memory: 64Mi}
            limits:   {cpu: 100m, memory: 64Mi}
  - priority: 1
    namespace: armada
    podSpec:
      terminationGracePeriodSeconds: 0
      containers:
        - name: any-job-4
          image: busybox:1.36
          command: [sh, -c]
          args: ["echo any-job-4: assigned by scheduler; sleep 60"]
          resources:
            requests: {cpu: 100m, memory: 64Mi}
            limits:   {cpu: 100m, memory: 64Mi}
  - priority: 1
    namespace: armada
    podSpec:
      terminationGracePeriodSeconds: 0
      containers:
        - name: any-job-5
          image: busybox:1.36
          command: [sh, -c]
          args: ["echo any-job-5: assigned by scheduler; sleep 60"]
          resources:
            requests: {cpu: 100m, memory: 64Mi}
            limits:   {cpu: 100m, memory: 64Mi}
EOF

  armadactl submit "$jobfile"
  echo ""
  echo "Any-pool batch submitted (jobSetId: ${jobset})."
  echo "View at: http://5.78.201.87:3000"
}

# ── entrypoint ─────────────────────────────────────────────────────────────────

MODE="${1:-all}"
case "$MODE" in
  individual) submit_individual ;;
  mixed)      submit_mixed ;;
  any)        submit_any_pool ;;
  all)        submit_individual; echo ""; submit_mixed; echo ""; submit_any_pool ;;
  *)          echo "Usage: $0 [individual|mixed|any|all]"; exit 1 ;;
esac
