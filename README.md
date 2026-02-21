# prysm-cni

A lightweight [CNI](https://www.cni.dev/) chained plugin that redirects pod TCP traffic to the Prysm Tunnel Daemon via iptables NAT REDIRECT rules.

## How It Works

prysm-cni is deployed as a chained CNI plugin. When a pod starts:

1. The kubelet invokes the primary CNI plugin (e.g. Flannel, Calico), which calls prysm-cni as a chained plugin.
2. prysm-cni runs `prysm-iptables.sh` inside the pod's network namespace to set up NAT REDIRECT rules.
3. All outbound TCP traffic from the pod is redirected to the Prysm Tunnel Daemon listening on `targetPort` (default `15001`).
4. The tunnel daemon reads the original destination via `SO_ORIGINAL_DST` and forwards traffic through the encrypted mesh.
5. On pod deletion, prysm-cni cleans up the iptables rules (best-effort).

Traffic from excluded namespaces (e.g. `kube-system`) passes through unmodified.

## Prerequisites

- Kubernetes 1.25+
- A primary CNI plugin already installed (Flannel, Calico, Cilium, etc.)
- `iptables` available on nodes
- Prysm agent / tunnel daemon running on each node

## Installation

### DaemonSet (recommended)

```bash
kubectl apply -f deployments/kubernetes/prysm-cni-daemonset.yaml
```

The DaemonSet installs the CNI binary and iptables script onto each node and chains prysm-cni into the existing CNI configuration.

### Manual

1. Copy `prysm-cni` to `/opt/cni/bin/` on each node.
2. Copy `scripts/prysm-iptables.sh` to `/opt/cni/bin/` on each node.
3. Add prysm-cni to your existing CNI conflist's `plugins` array (see `deployments/install/10-prysm-cni.conflist.template`).

## Configuration

The plugin is configured via the CNI conflist JSON:

| Parameter           | Type       | Default                                          | Description                                    |
|---------------------|------------|--------------------------------------------------|------------------------------------------------|
| `targetPort`        | string     | `"15001"`                                        | Port the tunnel daemon listens on              |
| `excludeNamespaces` | []string   | `["kube-system","kube-public","prysm-system"]`   | Namespaces to skip (no redirect)               |
| `excludeCIDR`       | string     | `""`                                             | Comma-separated CIDRs to exclude from redirect |
| `nodeIP`            | string     | *required*                                       | Node IP for DNAT return-path rules             |
| `noRedirectUID`     | string     | `"0"`                                            | UID whose traffic is not redirected             |

## Environment Variables

These are used by the install DaemonSet (`install-cni.sh`):

| Variable                 | Default                      | Description                                       |
|--------------------------|------------------------------|---------------------------------------------------|
| `MOUNTED_CNI_BIN_DIR`    | `/host/opt/cni/bin`          | Host CNI binary directory (mounted)               |
| `MOUNTED_CNI_NET_DIR`    | `/host/etc/cni/net.d`        | Host CNI config directory (mounted)               |
| `MOUNTED_CNI_BIN_DIR_K3S`| *(unset)*                    | K3s binary directory (`/host/bin`) if applicable   |
| `CHAINED_CNI_PLUGIN`     | `true`                       | Chain into existing CNI config vs. standalone      |
| `CNI_NETWORK_CONFIG`     | *(unset)*                    | Override plugin JSON config                        |
| `HOST_IP`                | *(from downward API)*        | Node IP, injected via `status.hostIP`              |
| `SLEEP`                  | `true`                       | Keep container running after install               |

## Development

```bash
# Build
make build

# Run tests
make test

# Lint (requires golangci-lint)
make lint

# Build Docker image
make docker

# Clean build artifacts
make clean
```

## Documentation

- [System Architecture](docs/architecture.md) — how the components (backend, agent, CNI, CLI, DERP relay) fit together
- [Traffic Flow](docs/traffic-flow.md) — step-by-step outbound/inbound paths, iptables rules explained, ports, bypass mechanisms, post-quantum security
- [Troubleshooting](docs/troubleshooting.md) — log locations, verification commands, common issues, configuration reference

## License

Apache License 2.0 - see [LICENSE](LICENSE).
