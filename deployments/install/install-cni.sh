#!/bin/sh
# Prysm CNI installer - chains with existing CNI, copies binaries, merges conflist
set -e

MOUNTED_CNI_NET_DIR=${MOUNTED_CNI_NET_DIR:-/host/etc/cni/net.d}
MOUNTED_CNI_BIN_DIR=${MOUNTED_CNI_BIN_DIR:-/host/opt/cni/bin}
CHAINED_CNI_PLUGIN=${CHAINED_CNI_PLUGIN:-true}

exit_with_error() {
  echo "ERROR: $1" >&2
  exit 1
}

# --- Cleanup on SIGTERM (DaemonSet pod deletion) ---
# Without this, removing the DaemonSet leaves a dangling conflist entry
# that references a binary that no longer exists, bricking pod creation.

cleanup() {
  echo "Removing Prysm CNI configuration..."

  # Remove prysm-cni plugin from any chained conflist
  for f in "${MOUNTED_CNI_NET_DIR}"/*.conflist; do
    [ -e "$f" ] || continue
    if jq -e '.plugins[]? | select(.type == "prysm-cni")' < "$f" >/dev/null 2>&1; then
      jq 'del(.plugins[] | select(.type == "prysm-cni"))' < "$f" > "$f.prysm.tmp"
      mv "$f.prysm.tmp" "$f"
      echo "Removed prysm-cni from $(basename "$f")"
    fi
  done

  # Remove standalone conflist if we created it (identified by our network name)
  if [ -f "${MOUNTED_CNI_NET_DIR}/10-prysm-cni.conflist" ]; then
    if jq -e '.name == "prysm-pod-network"' < "${MOUNTED_CNI_NET_DIR}/10-prysm-cni.conflist" >/dev/null 2>&1; then
      rm -f "${MOUNTED_CNI_NET_DIR}/10-prysm-cni.conflist"
      echo "Removed standalone prysm-cni conflist"
    fi
  fi

  # Remove binaries
  rm -f "${MOUNTED_CNI_BIN_DIR}/prysm-cni" "${MOUNTED_CNI_BIN_DIR}/prysm-iptables.sh"
  if [ -n "${MOUNTED_CNI_BIN_DIR_K3S:-}" ]; then
    rm -f "${MOUNTED_CNI_BIN_DIR_K3S}/prysm-cni" "${MOUNTED_CNI_BIN_DIR_K3S}/prysm-iptables.sh"
  fi

  echo "Prysm CNI removed."
  exit 0
}

trap cleanup TERM INT

# --- Copy binaries to host ---

echo "Installing Prysm CNI binaries..."
cp -f /opt/cni/bin/prysm-cni "${MOUNTED_CNI_BIN_DIR}/prysm-cni" || exit_with_error "Failed to copy prysm-cni"
cp -f /opt/cni/bin/prysm-iptables.sh "${MOUNTED_CNI_BIN_DIR}/prysm-iptables.sh" || exit_with_error "Failed to copy prysm-iptables.sh"
chmod +x "${MOUNTED_CNI_BIN_DIR}/prysm-cni" "${MOUNTED_CNI_BIN_DIR}/prysm-iptables.sh"
# K3s containerd uses bin_dir="/bin" - copy there when MOUNTED_CNI_BIN_DIR_K3S is set (e.g. /host/bin)
if [ -n "${MOUNTED_CNI_BIN_DIR_K3S:-}" ] && [ -d "${MOUNTED_CNI_BIN_DIR_K3S}" ] && [ -w "${MOUNTED_CNI_BIN_DIR_K3S}" ]; then
  # Also try /bin/ inside the container image (placed by Dockerfile for K3s)
  SRC_CNI="/opt/cni/bin/prysm-cni"
  SRC_IPT="/opt/cni/bin/prysm-iptables.sh"
  [ -f /bin/prysm-cni ] && SRC_CNI="/bin/prysm-cni"
  [ -f /bin/prysm-iptables.sh ] && SRC_IPT="/bin/prysm-iptables.sh"
  cp -f "$SRC_CNI" "${MOUNTED_CNI_BIN_DIR_K3S}/prysm-cni" || echo "WARNING: failed to copy prysm-cni to ${MOUNTED_CNI_BIN_DIR_K3S}"
  cp -f "$SRC_IPT" "${MOUNTED_CNI_BIN_DIR_K3S}/prysm-iptables.sh" || echo "WARNING: failed to copy prysm-iptables.sh to ${MOUNTED_CNI_BIN_DIR_K3S}"
  chmod +x "${MOUNTED_CNI_BIN_DIR_K3S}/prysm-cni" "${MOUNTED_CNI_BIN_DIR_K3S}/prysm-iptables.sh" 2>/dev/null
  echo "Also installed to ${MOUNTED_CNI_BIN_DIR_K3S} (K3s bin_dir)"
fi
echo "Prysm CNI binaries installed."

# --- Find existing conflist ---

find_cni_conf() {
  for f in "${MOUNTED_CNI_NET_DIR}"/*; do
    [ -e "$f" ] || continue
    case "$f" in
      *.conflist)
        if jq -e 'has("plugins")' < "$f" >/dev/null 2>&1; then
          basename "$f"
          return
        fi
        ;;
      *.conf)
        if jq -e 'has("type")' < "$f" >/dev/null 2>&1; then
          basename "$f"
          return
        fi
        ;;
    esac
  done
  echo ""
}

# --- Determine node IP ---

# Get node IP from environment (set via Kubernetes downward API)
NODE_IP="${HOST_IP:-}"
if [ -z "${NODE_IP}" ]; then
  # Fallback: try to detect from default route
  NODE_IP=$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([^ ]*\).*/\1/p' || true)
fi
if [ -z "${NODE_IP}" ]; then
  echo "WARNING: Could not determine node IP. CNI may fail to program iptables."
fi

# Build plugin JSON with nodeIP
PRYSM_PLUGIN_JSON=$(jq -n \
  --arg nodeIP "${NODE_IP}" \
  '{type:"prysm-cni",targetPort:"15001",excludeNamespaces:["kube-system","kube-public","prysm-system","prysm-logging","prysm-honeypots"],excludeCIDR:"10.43.0.0/16",nodeIP:$nodeIP}')

if [ -n "${CNI_NETWORK_CONFIG:-}" ]; then
  # Merge provided config with nodeIP
  PRYSM_PLUGIN_JSON=$(echo "${CNI_NETWORK_CONFIG}" | jq --arg nodeIP "${NODE_IP}" '. + {nodeIP:$nodeIP}')
fi

# --- Install CNI config ---

CNI_CONF=$(find_cni_conf)
if [ -z "$CNI_CONF" ] || [ "${CHAINED_CNI_PLUGIN}" != "true" ]; then
  [ -z "$CNI_CONF" ] && echo "WARNING: No existing CNI config found." || echo "CHAINED_CNI_PLUGIN=false, creating standalone config."
  jq -n --argjson plugin "$PRYSM_PLUGIN_JSON" '{cniVersion:"1.0.0",name:"prysm-pod-network",plugins:[$plugin]}' > "${MOUNTED_CNI_NET_DIR}/10-prysm-cni.conflist"
  echo "Created standalone config."
else
  # Chain: add prysm-cni to existing conflist (or replace if already chained)
  TMP_CONF="${MOUNTED_CNI_NET_DIR}/${CNI_CONF}.prysm.tmp"
  if jq -e '.plugins[]? | select(.type == "prysm-cni")' < "${MOUNTED_CNI_NET_DIR}/${CNI_CONF}" >/dev/null 2>&1; then
    # Already chained: replace entire prysm-cni plugin to pick up config changes
    jq --argjson plugin "$PRYSM_PLUGIN_JSON" '(.plugins |= map(if .type == "prysm-cni" then $plugin else . end))' < "${MOUNTED_CNI_NET_DIR}/${CNI_CONF}" > "$TMP_CONF"
    mv "$TMP_CONF" "${MOUNTED_CNI_NET_DIR}/${CNI_CONF}"
    echo "Updated Prysm CNI plugin in chain (${CNI_CONF})"
  else
    # Add prysm-cni to plugins array
    jq --argjson plugin "$PRYSM_PLUGIN_JSON" '.plugins += [$plugin]' < "${MOUNTED_CNI_NET_DIR}/${CNI_CONF}" > "$TMP_CONF"
    mv "$TMP_CONF" "${MOUNTED_CNI_NET_DIR}/${CNI_CONF}"
    echo "Chained Prysm CNI into ${CNI_CONF}"
  fi
fi

# --- Sleep (keep container alive so cleanup trap can fire) ---

if [ "${SLEEP:-true}" = "true" ]; then
  echo "Install complete. Sleeping..."
  # Use sleep+wait pattern so SIGTERM is handled promptly
  while true; do
    sleep 3600 &
    wait $! || true
  done
fi
