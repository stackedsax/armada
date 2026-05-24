#!/usr/bin/env bash
# Armada multi-pool demo: submit jobs to slurm, armada, and default pools.
# Usage:
#   ./demo-submit.sh individual   - one job per pool
#   ./demo-submit.sh mixed        - batch of jobs across all pools
#   ./demo-submit.sh all          - both of the above (default)

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
jobSetId: demo-${pool}-$(date +%s)
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
  echo "→ Pool: default  (scheduled across all capacity, fair-share)"
  submit_job default default-job 60

  echo ""
  echo "Individual jobs submitted. View at: http://5.78.201.87:3000"
}

# ── mixed: several jobs spread across all pools ────────────────────────────────

submit_mixed() {
  echo "Submitting mixed batch across all pools..."
  local jobset="demo-mixed-$(date +%s)"
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
            requests: {cpu: 100m, memory: 64Mi}
            limits:   {cpu: 100m, memory: 64Mi}
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
            requests: {cpu: 100m, memory: 64Mi}
            limits:   {cpu: 100m, memory: 64Mi}
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
            requests: {cpu: 100m, memory: 64Mi}
            limits:   {cpu: 100m, memory: 64Mi}
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
            requests: {cpu: 100m, memory: 64Mi}
            limits:   {cpu: 100m, memory: 64Mi}
  - priority: 1
    namespace: armada
    podSpec:
      terminationGracePeriodSeconds: 0
      nodeSelector:
        armadaproject.io/pool: default
      containers:
        - name: default-batch-1
          image: busybox:1.36
          command: [sh, -c]
          args: ["echo default batch 1; sleep 60"]
          resources:
            requests: {cpu: 100m, memory: 64Mi}
            limits:   {cpu: 100m, memory: 64Mi}
  - priority: 1
    namespace: armada
    podSpec:
      terminationGracePeriodSeconds: 0
      nodeSelector:
        armadaproject.io/pool: default
      containers:
        - name: default-batch-2
          image: busybox:1.36
          command: [sh, -c]
          args: ["echo default batch 2; sleep 60"]
          resources:
            requests: {cpu: 100m, memory: 64Mi}
            limits:   {cpu: 100m, memory: 64Mi}
EOF

  armadactl submit "$jobfile"
  echo ""
  echo "Mixed batch submitted (jobSetId: ${jobset})."
  echo "View at: http://5.78.201.87:3000"
}

# ── entrypoint ─────────────────────────────────────────────────────────────────

MODE="${1:-all}"
case "$MODE" in
  individual) submit_individual ;;
  mixed)      submit_mixed ;;
  all)        submit_individual; echo ""; submit_mixed ;;
  *)          echo "Usage: $0 [individual|mixed|all]"; exit 1 ;;
esac
