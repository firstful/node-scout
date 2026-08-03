#!/bin/bash
# node-gatekeeper: every tick, taint any non-configured worker so nothing
# deploys until node-scout has configured it and stamped rook.io/configured=true.
set -u
export PATH=/usr/sbin:/sbin:$PATH
KUBE_TOKEN="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
KUBE_CA=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
KUBE="https://kubernetes.default.svc"
AUTH="Authorization: Bearer $KUBE_TOKEN"

nodes=$(curl -sf --cacert "$KUBE_CA" -H "$AUTH" "$KUBE/api/v1/nodes")
echo "$nodes" | jq -r '
  .items[] | select(.metadata.labels["node-role.kubernetes.io/control-plane"] != "true") | .metadata.name
' | while read -r node; do
  configured=$(echo "$nodes" | jq -r --arg n "$node" '.items[] | select(.metadata.name==$n) | .metadata.labels["rook.io/configured"] // empty')
  has_taint=$(echo "$nodes" | jq -r --arg n "$node" '[.items[] | select(.metadata.name==$n) | .spec.taints // [] | .[]? | select(.key=="rook.io/unconfigured")] | length')
  if [ "$configured" != "true" ] && [ "$has_taint" = "0" ]; then
    curl -sf --cacert "$KUBE_CA" -X PATCH -H "$AUTH" \
      -H "Content-Type: application/strategic-merge-patch+json" \
      -d '{"spec":{"taints":[{"key":"rook.io/unconfigured","effect":"NoSchedule"}]}}' \
      "$KUBE/api/v1/nodes/$node" >/dev/null 2>&1 \
      && echo "[$(date -u +%H:%M:%S)] tainted unconfigured node $node" || echo "[$(date -u +%H:%M:%S)] ERROR tainting $node"
  elif [ "$configured" = "true" ] && [ "$has_taint" != "0" ]; then
    echo "[$(date -u +%H:%M:%S)] node $node configured but still tainted (scout should clear)"
  fi
done
echo "[$(date -u +%H:%M:%S)] gatekeeper sweep done"
