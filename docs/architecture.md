# System Architecture

Prysm is a zero-trust networking platform for Kubernetes. It encrypts pod-to-pod traffic with mTLS, provides mesh visibility, and tunnels connections through firewalls — all without changing application code.

This page describes how the components fit together.

## Overview

```
                         +------------------+
                         |     Backend      |
                         | (control plane)  |
                         +--------+---------+
                              ^   |
                    config,   |   |  auth, certs,
                    topology  |   |  zero-trust policy
                              |   v
+-----------+            +----+--------+            +-----------+
|           |    DERP    |             |    DERP    |           |
|    CLI    +<---------->+ DERP Relay  +<---------->+   Agent   |
|           |            |             |            |           |
+-----------+            +-------------+            +-----+-----+
                                                          |
                                               deploys &  | manages
                                                          v
                                                    +-----+-----+
                                                    |    CNI     |
                                                    | (per pod)  |
                                                    +-----+-----+
                                                          |
                                              iptables    | redirect
                                                          v
                                                    +-----+-----+
                                                    |  Tunnel    |
                                                    |  Daemon    |
                                                    +-----+-----+
                                                          |
                                                  mTLS    |  pod-to-pod
                                                          v
                                                    +-----+-----+
                                                    |    Pods    |
                                                    +-----------+
```

## Components

### Backend

The control plane. It handles authentication, issues certificates, distributes zero-trust configuration to agents, proxies `kubectl` for managed clusters, and aggregates mesh topology data for the analytics UI. Agents poll the backend for their configuration — including whether CNI should be enabled, which namespaces to exclude, and what port the tunnel daemon listens on.

### Agent

A per-cluster orchestrator deployed as a Deployment (typically one replica). The agent is responsible for:

- **CNI lifecycle** — deploys and reconciles the prysm-cni DaemonSet, updating it when configuration changes and removing it when zero-trust is disabled.
- **Tunnel daemon** — runs the transparent mTLS proxy that encrypts pod-to-pod traffic, managing certificate issuance per pod and per-pod network namespace listeners.
- **Telemetry** — reports cluster health (node/pod counts, CPU/memory usage) to the backend every 60 seconds.
- **Mesh topology** — buffers connection events from the tunnel daemon and flushes them to the backend for the network graph visualization.
- **mTLS renewal** — maintains the agent's own certificate and manages per-pod workload certificates with SPIFFE identities.

The agent fetches its configuration from `GET /api/v1/agent/zero-trust/config` and reports CNI status back to `POST /api/v1/agent/zero-trust/status`.

### CNI Plugin

A lightweight chained CNI plugin that runs once per pod, during pod creation. It does not run as a long-lived process. When the kubelet creates a pod:

1. The primary CNI plugin (Flannel, Calico, Cilium, etc.) runs first and sets up networking.
2. prysm-cni runs as a chained plugin and programs iptables NAT REDIRECT rules inside the pod's network namespace, redirecting all outbound TCP to port 15001.
3. It writes the pod's network namespace path to `/var/run/prysm/tunnel-pods/{podUID}` so the tunnel daemon can discover it.

On pod deletion, the CNI cleans up iptables rules and removes the registration file (best-effort).

Pods in excluded namespaces (`kube-system`, `kube-public`, `prysm-system`) are skipped entirely.

### CLI

A cross-platform tool (macOS, Windows, Linux) for interacting with Prysm from any machine — not just Kubernetes nodes. It supports:

- **Login and authentication** — obtains API tokens from the backend.
- **Kubeconfig generation** — creates kubeconfigs that route `kubectl` through the backend's cluster proxy.
- **Mesh networking** — joins/leaves the mesh from a laptop or workstation, views topology.
- **Tunnel management** — exposes services and connects to them across clusters and devices.

The CLI communicates with agents behind firewalls via the DERP relay, making it possible to reach clusters that have no public ingress. A developer on macOS can use `prysm connect` to tunnel into a service running in a private Kubernetes cluster without VPN or port forwarding.

### DERP Relay

A relay server based on the [DERP protocol](https://pkg.go.dev/tailscale.com/derp) that enables connectivity between components that cannot reach each other directly. When an agent starts behind a firewall (no public IP, no ingress), it connects outbound to the DERP relay and holds the connection open. The CLI and backend can then send messages to the agent through the relay.

This is how tunnel expose/connect works for private clusters: the CLI connects to the DERP relay, the agent connects to the same relay, and traffic flows between them without either side needing to accept inbound connections.

## How They Connect

The typical flow from deployment to encrypted traffic:

1. **Agent starts** — connects to the backend, authenticates with its agent token, and fetches zero-trust configuration.
2. **CNI deployment** — if zero-trust is enabled, the agent creates the `prysm-cni` DaemonSet in `prysm-system`. The install script on each node copies the CNI binary and iptables script to the host, then chains prysm-cni into the existing CNI configuration.
3. **Pod creation** — when a new pod starts, the kubelet invokes prysm-cni, which programs iptables rules and registers the pod's network namespace.
4. **Tunnel daemon discovery** — the tunnel daemon watches `/var/run/prysm/tunnel-pods/` for new entries. When it finds one, it enters the pod's network namespace and starts an outbound listener on port 15001.
5. **Traffic interception** — when the pod sends TCP traffic, iptables redirects it to the tunnel daemon. The daemon recovers the original destination via `SO_ORIGINAL_DST`.
6. **mTLS encryption** — for cross-node traffic, the tunnel daemon wraps the connection in TLS 1.3 with the pod's workload certificate and connects to the destination node's inbound listener on port 15002.
7. **Topology reporting** — connection events (source pod, destination pod, bytes, port) are buffered and flushed to the backend every 10 seconds, where they appear in the mesh topology graph.

## Configuration Source

The agent reconciles CNI configuration every 5 minutes. Configuration flows in one direction:

```
Backend (zero-trust config)
  → Agent (fetches config, builds DaemonSet spec)
    → CNI DaemonSet (env vars: CNI_NETWORK_CONFIG, HOST_IP, ...)
      → install-cni.sh (chains into existing CNI conflist)
        → prysm-cni binary (reads config from stdin per CNI spec)
          → prysm-iptables.sh (receives targetPort, nodeIP, excludeCIDR, noRedirectUID)
```

When zero-trust is disabled on the backend, the agent deletes the DaemonSet. The cleanup trap in `install-cni.sh` removes the conflist entry and binaries from each node on `SIGTERM`.
