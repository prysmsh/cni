#!/bin/sh
#
# Prysm Zero Trust - iptables NAT REDIRECT for pod traffic
# Dual-stack (IPv4 + IPv6) support
# Uses NAT REDIRECT to capture TCP traffic (Istio-style approach)
# Original destination is retrieved via SO_ORIGINAL_DST socket option
# Requires: iptables with NAT support
#

set -e

PROXY_PORT=${1:-15001}
NO_REDIRECT_UID=${2:-0}
EXCLUDE_CIDR=${3:-}
NODE_IP=${4:-}

# Tunnel bypass mark - traffic from tunnel daemon that should skip redirect
# Must match tunnelBypassMark in netns_listener_linux.go
TUNNEL_BYPASS_MARK=0x800

# Chain names (unique to avoid conflicts with other CNI plugins)
CHAIN_OUTPUT="PRYSM_OUTPUT"
CHAIN_REDIRECT="PRYSM_REDIRECT"

# --- Validation helpers ---

is_ipv6() { case "$1" in *:*) return 0 ;; *) return 1 ;; esac; }

validate_ip() {
  if is_ipv6 "$1"; then
    printf '%s' "$1" | grep -qE '^[0-9a-fA-F:]+$'
  else
    printf '%s' "$1" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'
  fi
}

validate_cidr() {
  printf '%s' "$1" | grep -qE '^[0-9a-fA-F.:]+/[0-9]+$'
}

# --- Cleanup function (works for both iptables and ip6tables) ---

cleanup() {
  local ipt=$1

  # Clean old mangle/TPROXY rules if they exist (migration from TPROXY)
  $ipt -t mangle -F PRYSM_OUTPUT 2>/dev/null || true
  $ipt -t mangle -F PRYSM_REDIRECT 2>/dev/null || true
  $ipt -t mangle -F PRYSM_PREROUTING 2>/dev/null || true
  $ipt -t mangle -F PRYSM_DIVERT 2>/dev/null || true
  $ipt -t mangle -D OUTPUT -p tcp -j PRYSM_OUTPUT 2>/dev/null || true
  $ipt -t mangle -D PREROUTING -p tcp -j PRYSM_PREROUTING 2>/dev/null || true
  $ipt -t mangle -X PRYSM_OUTPUT 2>/dev/null || true
  $ipt -t mangle -X PRYSM_REDIRECT 2>/dev/null || true
  $ipt -t mangle -X PRYSM_PREROUTING 2>/dev/null || true
  $ipt -t mangle -X PRYSM_DIVERT 2>/dev/null || true

  # Clean NAT rules
  $ipt -t nat -F "${CHAIN_OUTPUT}" 2>/dev/null || true
  $ipt -t nat -F "${CHAIN_REDIRECT}" 2>/dev/null || true
  $ipt -t nat -D OUTPUT -p tcp -j "${CHAIN_OUTPUT}" 2>/dev/null || true
  $ipt -t nat -X "${CHAIN_OUTPUT}" 2>/dev/null || true
  $ipt -t nat -X "${CHAIN_REDIRECT}" 2>/dev/null || true
}

# --- Program base chains (exclusions added after) ---

program_base() {
  local ipt=$1
  local localhost_cidr=$2

  # Create redirect chain — performs the actual REDIRECT
  $ipt -t nat -N "${CHAIN_REDIRECT}"
  $ipt -t nat -A "${CHAIN_REDIRECT}" -p tcp -j REDIRECT --to-port "${PROXY_PORT}"

  # OUTPUT chain for locally-originated traffic
  $ipt -t nat -N "${CHAIN_OUTPUT}"
  $ipt -t nat -A OUTPUT -p tcp -j "${CHAIN_OUTPUT}"

  # Don't redirect traffic marked by tunnel daemon (bypass mark to avoid loops)
  # The tunnel daemon sets SO_MARK=0x800 on its sockets to bypass redirect
  $ipt -t nat -A "${CHAIN_OUTPUT}" -m mark --mark ${TUNNEL_BYPASS_MARK} -j RETURN

  # Don't redirect traffic from the no-redirect UID (e.g. tunnel daemon).
  # Skipped for UID 0 (root) — too broad, would bypass most container traffic.
  if [ -n "${NO_REDIRECT_UID}" ] && [ "${NO_REDIRECT_UID}" != "0" ]; then
    $ipt -t nat -A "${CHAIN_OUTPUT}" -m owner --uid-owner "${NO_REDIRECT_UID}" -j RETURN
  fi

  # Don't redirect localhost
  $ipt -t nat -A "${CHAIN_OUTPUT}" -d "${localhost_cidr}" -j RETURN

  # Don't redirect traffic to the proxy port itself (avoid loops)
  $ipt -t nat -A "${CHAIN_OUTPUT}" -p tcp --dport "${PROXY_PORT}" -j RETURN
}

# =========================================================================
# Main
# =========================================================================

# Always clean up both address families
cleanup iptables
cleanup ip6tables 2>/dev/null || true

# Clean up old TPROXY routing rules
ip rule del fwmark 0x1/0x1 lookup 100 2>/dev/null || true
ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null || true
ip -6 rule del fwmark 0x1/0x1 lookup 100 2>/dev/null || true
ip -6 route del local ::/0 dev lo table 100 2>/dev/null || true

# If called with "clean" as first arg, just clean and exit
if [ "${1:-}" = "clean" ]; then
  exit 0
fi

# Validate node IP is provided and well-formed
if [ -z "${NODE_IP}" ]; then
  echo "ERROR: NODE_IP is required" >&2
  exit 1
fi
if ! validate_ip "${NODE_IP}"; then
  echo "ERROR: invalid NODE_IP format: ${NODE_IP}" >&2
  exit 1
fi

# --- Program IPv4 rules ---
program_base iptables "127.0.0.0/8"

# --- Program IPv6 rules (best-effort: ip6tables may not be available) ---
if command -v ip6tables >/dev/null 2>&1; then
  program_base ip6tables "::1/128" 2>/dev/null || true
fi

# --- Node IP exclusion (address-family aware) ---
if is_ipv6 "${NODE_IP}"; then
  ip6tables -t nat -A "${CHAIN_OUTPUT}" -d "${NODE_IP}/128" -j RETURN 2>/dev/null || true
else
  iptables -t nat -A "${CHAIN_OUTPUT}" -d "${NODE_IP}/32" -j RETURN
fi

# --- Exclude CIDRs (address-family aware) ---
if [ -n "${EXCLUDE_CIDR}" ]; then
  OLD_IFS="$IFS"
  IFS=","
  for cidr in ${EXCLUDE_CIDR}; do
    cidr=$(printf '%s' "${cidr}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "${cidr}" ] && continue
    if ! validate_cidr "${cidr}"; then
      echo "WARNING: skipping invalid CIDR: ${cidr}" >&2
      continue
    fi
    if is_ipv6 "${cidr}"; then
      ip6tables -t nat -A "${CHAIN_OUTPUT}" -d "${cidr}" -j RETURN 2>/dev/null || true
    else
      iptables -t nat -A "${CHAIN_OUTPUT}" -d "${cidr}" -j RETURN
    fi
  done
  IFS="$OLD_IFS"
fi

# --- Final: redirect all remaining outbound TCP to proxy port ---
iptables -t nat -A "${CHAIN_OUTPUT}" -p tcp -j "${CHAIN_REDIRECT}"
if command -v ip6tables >/dev/null 2>&1; then
  ip6tables -t nat -A "${CHAIN_OUTPUT}" -p tcp -j "${CHAIN_REDIRECT}" 2>/dev/null || true
fi

echo "NAT REDIRECT rules installed (proxy port: ${PROXY_PORT}, node: ${NODE_IP})"
exit 0
