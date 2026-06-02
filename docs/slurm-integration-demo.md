# Slurm Integration Demo

This demo shows Armada routing jobs to two different backend pool types from a
single submission point:

- **slurm pool** — jobs are routed to one of two Slurm clusters via
  [slurm-bridge](https://github.com/SlinkyProject/slurm-bridge); Slurm handles
  node selection within each cluster
- **armada pool** — jobs are routed to one of two plain Kubernetes clusters;
  Armada's scheduler handles node selection directly

## Architecture

```
                        ┌────────────────────────────┐
                        │      armada-server         │
                        │  (Armada control plane)    │
                        │                            │
                        │  pools:                    │
                        │   slurm  (skipNodeBinding) │
                        │   armada (standard K8s)    │
                        └──────────────┬─────────────┘
                                       │ gRPC :50051
          ┌───────────────────┬────────┴────────┬───────────────────┐
          │                   │                 │                   │
┌─────────▼────────┐  ┌───────▼──────────┐  ┌───▼──────────────┐  ┌─▼─────────────────┐
│  slurm-executor  │  │ slurm-executor-2 │  │  armada-executor │  │ armada-executor-2 │
│ (Slurm + bridge) │  │ (Slurm + bridge) │  │  (plain K8s)     │  │ (plain K8s)       │
└──────────────────┘  └──────────────────┘  └──────────────────┘  └───────────────────┘
        ...more clusters can be added to either pool
```

## Scheduling behaviour

### Within a pool: bin-packing and cluster-level overflow

Within each pool, Armada bin-packs jobs onto the first available cluster.
When that cluster fills up, jobs spill to the next cluster in the pool. This
is what makes multi-cluster pools work: add capacity by adding clusters, and
Armada distributes the load automatically.

### Across pools: first-fit with overflow, not fair-share

Armada processes pools in config order during each scheduling cycle. The first
pool's pass claims every job it has capacity for; whatever remains queued is
picked up by the next pool's pass. This means:

- Jobs targeting **slurm** always go to slurm.
- Jobs targeting **armada** always go to armada.
- Jobs with **no pool selector** go to slurm (first in config) until slurm
  is full, then overflow to armada.

This is **first-fit with overflow**, not fair-share. Armada does not
automatically balance pool-agnostic jobs across pools — the first pool wins
until exhausted. To route a job to a specific pool, set the
`armadaproject.io/pool` nodeSelector explicitly.

## Hosted demo

A live instance is running at `5.78.201.87`. Configure `armadactl` to point at it:

```bash
cat > ~/.armadactl.yaml <<EOF
currentContext: demo
contexts:
  demo:
    armadaUrl: 5.78.201.87:50051
    forceNoTls: true
EOF
```

- **Lookout UI**: http://5.78.201.87:3000
- **REST API**: http://5.78.201.87:8081
- **gRPC**: 5.78.201.87:50051

## Prerequisites (local)

- [armadactl](https://github.com/armadaproject/armada/releases) — download the
  binary for your platform from the Armada releases page

## Running the demo

Use `scripts/demo-submit.sh` from the repo root (requires `armadactl` configured above):

```bash
./scripts/demo-submit.sh all    # run all modes (default)
./scripts/demo-submit.sh slurm  # jobs pinned to the Slurm pool
./scripts/demo-submit.sh armada # jobs pinned to the Armada (K8s) pool
./scripts/demo-submit.sh mixed  # large-resource batch across both pools
./scripts/demo-submit.sh any    # jobs with no pool preference (overflow demo)
```

**slurm**: submits 3 small jobs with `nodeSelector: armadaproject.io/pool: slurm`.
All three are routed through slurm-bridge to Slurm for execution.

**armada**: submits 3 small jobs with `nodeSelector: armadaproject.io/pool: armada`.
All three are scheduled directly onto Kubernetes worker nodes.

**mixed**: submits 6 slurm jobs and 5 armada jobs, each requesting 12 CPU. With
16-CPU worker nodes, only one job fits per node. The slurm pool's first cluster
(4 workers) fills after 4 jobs; the remaining 2 spill to `slurm-executor-2`. The
armada pool's first cluster (3 workers) fills after 3 jobs; the remaining 2 spill
to `armada-executor-2`. This demonstrates Armada's cluster-level bin-packing and
overflow within each pool.

**any**: submits 10 large jobs (14 CPU each) with no pool selector. The slurm pool
has 8 workers across two clusters; at 14 CPU per job, one job fits per worker,
giving slurm a capacity of 8 jobs. The first 8 land on slurm; the remaining 2
overflow to armada. This demonstrates first-fit with overflow across pools.

## What to observe

In Lookout, filter by job set to see where each batch landed:

- The **Cluster** column shows which executor cluster each job ran on
- For `mixed`: slurm jobs spread across `slurm-executor` and `slurm-executor-2`;
  armada jobs spread across `armada-executor` and `armada-executor-2`
- For `any`: first 8 jobs on slurm clusters, last 2 on armada clusters
- Slurm jobs show `schedulerName: slurm-bridge-scheduler` in their pod spec;
  armada jobs show `schedulerName: default-scheduler`

## Setting up your own instance

See [slurm-demo-server-setup.md](slurm-demo-server-setup.md) for a full guide to
reproducing this setup on a Linux server.
