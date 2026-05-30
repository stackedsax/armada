#!/usr/bin/env bash
# Applies DNAT rules that forward public ports to kind-armada-server NodePorts.
# Designed to run as a systemd service after Docker, so the IP is discovered
# fresh each time rather than hardcoded.
#
# Public → NodePort mapping:
#   3000  → 30000  (Lookout UI)
#   8081  → 30001  (REST API)
#   50051 → 30002  (gRPC)

set -euo pipefail

# Wait for the kind-armada-server API server to be reachable (may take a minute after reboot).
SERVER_IP=""
for attempt in $(seq 1 30); do
  SERVER_IP=$(kubectl --context kind-armada-server get nodes \
    -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)
  [[ -n "$SERVER_IP" ]] && break
  echo "apply-iptables: waiting for kind-armada-server (attempt ${attempt}/30)..."
  sleep 10
done

if [[ -z "$SERVER_IP" ]]; then
  echo "apply-iptables: timed out waiting for kind-armada-server, aborting" >&2
  exit 1
fi

echo "apply-iptables: server IP is ${SERVER_IP}"

apply_rule() {
  local table="$1" chain="$2"; shift 2
  iptables -t "$table" -C "$chain" "$@" 2>/dev/null || iptables -t "$table" -A "$chain" "$@"
}

# Insert a FORWARD rule before DOCKER-FORWARD (position 2) so it isn't shadowed.
# Docker prepends DOCKER-USER and DOCKER-FORWARD at startup; -A rules appended after
# those are never reached for DNAT-forwarded traffic.
insert_forward_rule() {
  iptables -C FORWARD "$@" 2>/dev/null || iptables -I FORWARD 2 "$@"
}

declare -A PORTS=([3000]=30000 [8081]=30001 [50051]=30002)
for pub in "${!PORTS[@]}"; do
  node="${PORTS[$pub]}"
  apply_rule nat PREROUTING -i eth0 -p tcp --dport "$pub"  -j DNAT --to-destination "${SERVER_IP}:${node}"
  apply_rule nat OUTPUT          -p tcp --dport "$pub"  -j DNAT --to-destination "${SERVER_IP}:${node}"
done

insert_forward_rule -i eth0 -d 172.18.0.0/16 -j ACCEPT
insert_forward_rule -o eth0 -s 172.18.0.0/16 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

echo "apply-iptables: done"
