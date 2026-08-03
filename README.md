# node-scout

Privileged worker configurator + configured gate (Reed's design, 2026-08-03).

- **DaemonSet** `node-scout` (ns `node-scout`, workers only): privileged, hostPID,
  hostPath `/` → `/host`. Reconciles host config from the `node-scout-config`
  ConfigMap (sutliff-cluster `infra/node-scout/`), verifies, then stamps
  `rook.io/configured=true` + per-node labels and clears the
  `rook.io/unconfigured:NoSchedule` gate taint.
- **CronJob** `node-gatekeeper` (every 2 min): taints any worker without
  `configured=true` so nothing deploys until the scout passes.

Checklist (ConfigMap, git-managed): swapfile, k3s eviction args, smartd/iscsid,
per-distro packages, Manjaro nftables flannel rules.

Runbook + pitfalls: k3s-homelab-cluster skill `references/node-scout.md`.

Image built by CI (this workflow) on push to main → `192.168.1.2:3000/reeds/node-scout:latest` + `:<sha8>`. Bump the tag in sutliff-cluster after a source change.
