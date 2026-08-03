#!/bin/bash
# node-scout: reconcile host config on a worker, then stamp configured + labels.
# Runs as a privileged DaemonSet (hostPID + hostPath / + /dev + /run). Config
# comes from the mounted node-scout-config ConfigMap (git-managed).
set -u
export PATH=/usr/sbin:/sbin:/usr/local/sbin:$PATH

NODE_NAME="${NODE_NAME:-$(hostname)}"
CFG_DIR=/config
HOST="/host"
NSENTER="nsenter -t 1 -m -u -i -n --"
KUBE_TOKEN="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
KUBE_CA=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
KUBE="https://kubernetes.default.svc"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

yq() { # yq key [default]  — naive YAML value extractor for our flat ConfigMap
  awk -v k="$1" 'BEGIN{FS=": "} $1==k {sub(/^"|"$/,"",$2); print $2; exit}'
}

node_get() { curl -sf --cacert "$KUBE_CA" -H "Authorization: Bearer $KUBE_TOKEN" "$KUBE/api/v1/nodes/$NODE_NAME"; }

ensure_swapfile() {
  local size_mb="$(yq swapfile_size_mb $CFG_DIR/checklist.yaml)"
  [ -z "$size_mb" ] && size_mb=8192
  local path="$(yq swapfile_path $CFG_DIR/checklist.yaml)"
  [ -z "$path" ] && path=/swapfile
  if [ -f "$HOST$path" ] && [ "$(stat -c%s "$HOST$path" 2>/dev/null || echo 0)" -ge $((size_mb*1024*1024)) ]; then
    log "swapfile $path OK ($(du -h "$HOST$path" | cut -f1))"
  else
    log "creating $path (${size_mb}MB)"
    rm -f "$HOST$path"
    if ! fallocate -l ${size_mb}M "$HOST$path" 2>/dev/null; then
      dd if=/dev/zero of="$HOST$path" bs=1M count="$size_mb" status=none
    fi
    chmod 600 "$HOST$path"
    mkswap "$HOST$path" >/dev/null 2>&1
  fi
  # ensure fstab entry
  grep -q "$path none swap sw" "$HOST/etc/fstab" 2>/dev/null || echo "$path none swap sw 0 0" >> "$HOST/etc/fstab"
  # active?
  $NSENTER swapon --show 2>/dev/null | grep -q "$path" || $NSENTER swapon "$path" 2>/dev/null
  $NSENTER swapon --show 2>/dev/null | grep -q "$path" && { log "swap $path ACTIVE"; return 0; }
  log "WARN: swap $path not active"; return 1
}

ensure_eviction_config() {
  local dst="$HOST/etc/rancher/k3s/config.yaml"
  local want="kubelet-arg:"
  local arg1="$(yq eviction_arg1 $CFG_DIR/checklist.yaml)"
  local arg2="$(yq eviction_arg2 $CFG_DIR/checklist.yaml)"
  mkdir -p "$(dirname "$dst")"
  {
    echo "kubelet-arg:"
    echo "  - \"$arg1\""
    echo "  - \"$arg2\""
  } > "$dst.tmp"
  if [ -f "$dst" ] && grep -q "$arg1" "$dst" && grep -q "$arg2" "$dst"; then
    log "k3s config.yaml OK (eviction args present)"
    rm -f "$dst.tmp"
  else
    mv "$dst.tmp" "$dst" && log "wrote k3s config.yaml (eviction args)"
  fi
  # NOTE: applying needs a k3s-agent restart; on an already-configured node the
  # args are live; on a fresh node the agent picks them up at first start.
  grep -q "$arg1" "$dst" || { log "WARN: eviction arg not in config"; return 1; }
  return 0
}

ensure_packages() {
  local distro=""
  [ -f "$HOST/etc/os-release" ] && distro="$(grep -E '^ID=' "$HOST/etc/os-release" | cut -d= -f2 | tr -d '"')"
  log "distro: $distro"
  if [ "$distro" = "debian" ] || [ "$distro" = "ubuntu" ]; then
    for pkg in $(yq packages_debian $CFG_DIR/checklist.yaml | tr ',' ' '); do
      [ -z "$pkg" ] && continue
      chroot "$HOST" dpkg -s "$pkg" >/dev/null 2>&1 || {
        log "installing $pkg"
        timeout 300 chroot "$HOST" apt-get install -y -qq "$pkg" >/dev/null 2>&1 || log "WARN: apt install $pkg failed"
      }
    done
  elif [ "$distro" = "manjaro" ] || [ "$distro" = "arch" ]; then
    for pkg in $(yq packages_manjaro $CFG_DIR/checklist.yaml | tr ',' ' '); do
      [ -z "$pkg" ] && continue
      chroot "$HOST" pacman -Q "$pkg" >/dev/null 2>&1 || {
        log "installing $pkg"
        timeout 300 chroot "$HOST" pacman -S --noconfirm --needed "$pkg" >/dev/null 2>&1 || log "WARN: pacman install $pkg failed"
      }
    done
  fi
  return 0
}

ensure_services() {
  for svc in $(yq services_always $CFG_DIR/checklist.yaml | tr ',' ' '); do
    [ -z "$svc" ] && continue
    $NSENTER systemctl is-active "$svc" >/dev/null 2>&1 || $NSENTER systemctl enable --now "$svc" >/dev/null 2>&1
    $NSENTER systemctl is-active "$svc" >/dev/null 2>&1 && log "service $svc active" || log "WARN: service $svc inactive"
  done
  return 0
}

ensure_nftables() {
  # Manjaro/Arch only: persist the flannel VXLAN + CNI accept rules.
  local distro=""
  [ -f "$HOST/etc/os-release" ] && distro="$(grep -E '^ID=' "$HOST/etc/os-release" | cut -d= -f2 | tr -d '"')"
  [ "$distro" != "manjaro" ] && [ "$distro" != "arch" ] && return 0
  local d="$HOST/etc/nftables.d"
  mkdir -p "$d"
  cat > "$d/rook-ffilt.nft" <<'EOF'
table inet filter {
  chain input {
    udp dport 8472 accept
    iifname "flannel.1" accept
    iifname "cni0" accept
  }
}
EOF
  # ensure include line in main config
  grep -q 'nftables.d/\*.nft' "$HOST/etc/nftables.conf" 2>/dev/null || echo 'include "/etc/nftables.d/*.nft";' >> "$HOST/etc/nftables.conf"
  # apply now (idempotent-ish: only if ruleset lacks the rule)
  $NSENTER systemctl is-active nftables >/dev/null 2>&1 || $NSENTER systemctl enable --now nftables >/dev/null 2>&1
  if ! $NSENTER nft list ruleset 2>/dev/null | grep -q "dport 8472"; then
    $NSENTER nft -f /etc/nftables.d/rook-ffilt.nft 2>/dev/null || log "WARN: nft apply failed (rules will load at boot)"
  fi
  log "nftables rules ensured"
  return 0
}

verify_all() {
  local ok=0
  ensure_swapfile || ok=1
  ensure_eviction_config || ok=1
  ensure_packages
  ensure_services
  ensure_nftables
  return $ok
}

patch_node() {
  # Add labels + remove rook.io/unconfigured taint; stamp rook.io/configured=true.
  # labels.yaml format:  <node>: rook.io/avx=true,rook.io/build=true
  local label_arg=""
  [ -f "$CFG_DIR/labels.yaml" ] && label_arg=$(grep "^${NODE_NAME}:" "$CFG_DIR/labels.yaml" | head -1 | cut -d: -f2- | tr -d ' ')
  local body
  body=$(node_get)
  body=$(echo "$body" | jq --arg l "$label_arg" '
    .metadata.labels["rook.io/configured"]="true" |
    reduce ($l | split(",") | map(select(length>0)) | map(capture("^(?<k>[^=]+)=(?<v>.*)$")))[] as $x (.;
      .metadata.labels[$x.k]=$x.v)
  ')
  # remove unconfigured taint
  body=$(echo "$body" | jq 'if (.spec.taints // [] | map(select(.key=="rook.io/unconfigured")) | length) > 0 then
      .spec.taints = [.spec.taints[] | select(.key!="rook.io/unconfigured")]
    else . end')
  # PUT the node back
  curl -sf --cacert "$KUBE_CA" -X PUT -H "Authorization: Bearer $KUBE_TOKEN" \
    -H "Content-Type: application/json" -d "$body" "$KUBE/api/v1/nodes/$NODE_NAME" >/dev/null 2>&1 \
    && { log "node $NODE_NAME: configured=true + labels applied, taint cleared"; return 0; } \
    || { log "ERROR: node patch failed"; return 1; }
}

# main reconcile loop
log "scout on node=$NODE_NAME start"
failures=0
while true; do
  if verify_all; then
    failures=0
    patch_node && log "OK: node configured"
  else
    failures=$((failures+1))
    log "reconcile FAILED ($failures) — NOT stamping configured"
  fi
  sleep 900
done
