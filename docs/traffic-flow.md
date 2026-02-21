# Traffic Flow

This page explains how pod traffic moves through the Prysm zero-trust mesh, step by step.

## Outbound Path

When a pod sends TCP traffic to another pod on a different node:

```
Pod app
  │  connect(10.0.2.15:8080)
  v
iptables NAT OUTPUT chain
  │  -j PRYSM_OUTPUT (check exclusions)
  │  -j PRYSM_REDIRECT
  │  REDIRECT --to-port 15001
  v
Tunnel daemon (:15001, inside pod netns)
  │  accept(), getsockopt(SO_ORIGINAL_DST) → 10.0.2.15:8080
  │  look up destination pod's node
  │  load pod's workload certificate
  │  TLS 1.3 dial to destination node :15002
  v
Destination node tunnel daemon (:15002)
  │  verify client certificate against org CA
  │  extract target from connection metadata
  │  forward to localhost:8080 in destination pod netns
  v
Destination pod app receives the connection
```

**Same-node traffic** skips the mTLS step. The tunnel daemon detects that the destination pod is local and proxies directly without encryption.

**Non-pod destinations** (external IPs, IPs not belonging to any known pod) pass through without tunneling.

## Inbound Path

There are no iptables rules on the inbound side. The tunnel daemon's mTLS listener on port 15002 **is** the inbound path:

```
Remote tunnel daemon
  │  TLS 1.3 connection to :15002
  v
Local tunnel daemon (:15002)
  │  RequireAndVerifyClientCert against org CA
  │  extract destination pod and port
  │  forward to pod's localhost:targetPort
  v
Pod app receives the connection
```

No PREROUTING rules are needed because the tunnel daemon accepts connections directly. There is no traffic to intercept — the remote side explicitly connects to port 15002.

## iptables Rules Explained

The CNI programs two chains in the `nat` table inside each pod's network namespace.

### PRYSM_REDIRECT Chain

Contains a single rule — the actual redirect:

| Rule | Purpose |
|------|---------|
| `-p tcp -j REDIRECT --to-port 15001` | Send all remaining TCP traffic to the tunnel daemon |

### PRYSM_OUTPUT Chain

Inserted into the OUTPUT chain. Contains exclusion rules checked in order, followed by a jump to PRYSM_REDIRECT:

| # | Rule | Purpose |
|---|------|---------|
| 1 | `-m mark --mark 0x800 -j RETURN` | Skip traffic from the tunnel daemon itself (prevents redirect loops) |
| 2 | `-m owner --uid-owner {UID} -j RETURN` | Skip traffic from a specific UID (only if `noRedirectUID` is not `"0"`) |
| 3 | `-d 127.0.0.0/8 -j RETURN` | Skip localhost traffic |
| 4 | `-p tcp --dport 15001 -j RETURN` | Skip traffic already destined for the proxy port |
| 5 | `-d {nodeIP}/32 -j RETURN` | Skip traffic to the node's own IP (prevents DNAT loops) |
| 6 | `-d {cidr} -j RETURN` | Skip traffic to each excluded CIDR (e.g., service CIDR `10.43.0.0/16`) |
| 7 | `-p tcp -j PRYSM_REDIRECT` | Everything else: redirect to the tunnel daemon |

Rules 3-6 also have IPv6 equivalents (e.g., `-d ::1/128 -j RETURN`) applied via `ip6tables`.

## Port Table

| Port | Direction | Protocol | Purpose |
|------|-----------|----------|---------|
| 15001 | Outbound | TCP | Tunnel daemon listener inside each pod's netns. Receives iptables-redirected traffic. |
| 15002 | Inbound | TCP | Tunnel daemon mTLS server on the node. Receives encrypted connections from other nodes. |

Both ports are configurable via environment variables (`TUNNEL_DAEMON_OUTBOUND_PORT`, `TUNNEL_DAEMON_INBOUND_PORT`) but 15001/15002 are the defaults.

## Bypass Mechanisms

Traffic can bypass the redirect in several ways:

| Mechanism | How It Works |
|-----------|-------------|
| **Socket mark** (`0x800`) | The tunnel daemon marks its own outbound sockets with `SO_MARK = 0x800`. The first iptables rule returns immediately for marked packets, preventing redirect loops. |
| **Namespace exclusion** | The CNI plugin skips pods in excluded namespaces entirely — no iptables rules are programmed. Default: `kube-system`, `kube-public`, `prysm-system`. |
| **CIDR exclusion** | Traffic to specified CIDRs passes through unmodified. Used to exclude service CIDRs (e.g., `10.43.0.0/16`) that should be handled by kube-proxy. |
| **Node IP exclusion** | Traffic to the pod's own node IP is skipped. This prevents loops when the pod communicates with node-level services. |
| **UID exclusion** | Traffic from a specific UID bypasses the redirect. Disabled by default (`noRedirectUID = "0"`, which means no UID is excluded — root traffic is not special-cased). |
| **Localhost** | Traffic to `127.0.0.0/8` and `::1/128` is never redirected. |
| **Proxy port** | Traffic already destined for port 15001 is not redirected again. |

## IPv6

The iptables script applies rules to both `iptables` (IPv4) and `ip6tables` (IPv6). IPv6 support is best-effort: if `ip6tables` is not available on the node, IPv4 rules are still applied and the script continues without error.

Node IP and CIDR exclusion rules are address-family aware — an IPv6 node IP creates an `ip6tables` rule with a `/128` mask, while an IPv4 node IP creates an `iptables` rule with a `/32` mask.

## Security

### Workload Identity

Each pod receives a workload certificate with a SPIFFE identity. These certificates are issued by the agent and signed by the organization's CA. The tunnel daemon uses them for mutual authentication: both sides of a connection present and verify certificates.

### Post-Quantum Key Exchange

Cross-node connections use TLS 1.3 with hybrid key exchange. The preferred curve order is:

1. **X25519+ML-KEM-768** — hybrid post-quantum key exchange (NIST Level 3, equivalent to AES-192 security)
2. **X25519** — fallback if the peer does not support ML-KEM
3. **P-256** — fallback for older TLS implementations

This means connections are protected against harvest-now-decrypt-later attacks by quantum computers, while remaining compatible with peers that only support classical key exchange.

### Certificate Verification

The inbound listener (port 15002) requires mutual TLS — `RequireAndVerifyClientCert` is enforced. A connection is only accepted if the client presents a valid workload certificate signed by the same organization CA. This prevents unauthorized pods or external attackers from connecting to the mesh.
