# Slurm Integration Demo

This demo shows Armada routing jobs to two different backend pool types from a single
submission point:

- **slurm pool** — jobs are routed to one of two Slurm clusters via
  [slurm-bridge](https://github.com/SlinkyProject/slurm-bridge); Slurm handles node
  selection within each cluster
- **armada pool** — jobs are routed to one of two plain Kubernetes clusters; Armada's
  scheduler handles node selection directly

Armada distributes load across the two clusters in each pool using its fair-share
algorithm: it bin-packs until one cluster fills up, then spills over to the second.

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

- [armadactl](https://github.com/armadaproject/armada/releases) — download the binary
  for your platform from the Armada releases page

## Running the demo

Use `scripts/demo-submit.sh` from the repo root (requires `armadactl` configured above):

```bash
./scripts/demo-submit.sh all        # run all modes (default)
./scripts/demo-submit.sh individual # one job per pool
./scripts/demo-submit.sh mixed      # batch that forces spreading across both clusters
./scripts/demo-submit.sh any        # jobs with no pool preference — scheduler decides
```

**individual**: submits one small job to each pool — useful to show basic routing.

**mixed**: submits 6 slurm jobs and 5 armada jobs, each requesting 12 CPU. With
16-CPU worker nodes, only one job fits per node. The slurm pool's first cluster (4
workers) fills after 4 jobs; the remaining 2 spill to `slurm-executor-2`. The armada
pool's first cluster (3 workers) fills after 3 jobs; the remaining 2 spill to
`armada-executor-2`. This demonstrates Armada's cluster-level bin-packing and overflow.

**any**: submits 5 small jobs with no `armadaproject.io/pool` nodeSelector. The
scheduler assigns them to whichever cluster has capacity, showing that Armada can route
jobs without the submitter specifying a pool.

Watch jobs appear and spread across clusters in Lookout at http://5.78.201.87:3000.

## What to observe

In Lookout, filter by job set to see where each batch landed. For the `mixed` batch:

- The **Cluster** column shows which executor cluster each job ran on
- Slurm jobs should appear across both `slurm-executor` and `slurm-executor-2`
- Armada jobs should appear across both `armada-executor` and `armada-executor-2`
- Slurm jobs will show `schedulerName: slurm-bridge-scheduler` in their pod spec
- Armada jobs will show `schedulerName: default-scheduler`

## Setting up your own instance

See [slurm-demo-server-setup.md](slurm-demo-server-setup.md) for a full guide to
reproducing this setup on a Linux server.
