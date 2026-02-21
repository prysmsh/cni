# Troubleshooting

Practical guide for diagnosing and resolving Prysm CNI issues.

## Log Locations

| Source | Location | What It Contains |
|--------|----------|-----------------|
| CNI plugin | `/var/log/prysm-cni.log` on each node | Per-pod add/del/check operations, errors during iptables setup |
| Install script | DaemonSet pod logs (`kubectl logs -n prysm-system -l app=prysm-cni-node`) | Binary installation, conflist chaining, cleanup events |
| Agent | Agent pod logs | CNI DaemonSet reconciliation, tunnel daemon activity, certificate issuance |
| Tunnel daemon | Agent pod logs | Connection events, mTLS handshake errors, SO_ORIGINAL_DST failures |

## Verifying iptables Rules

To check whether the redirect rules are programmed correctly inside a pod:

```bash
# Get the pod's PID
POD_PID=$(crictl inspect $(crictl ps --name <container-name> -q) | jq .info.pid)

# List the PRYSM_OUTPUT chain in the pod's network namespace
nsenter -t $POD_PID -n iptables -t nat -L PRYSM_OUTPUT -n -v

# Expected output (example):
# Chain PRYSM_OUTPUT (1 references)
#  pkts bytes target     prot opt in  out  source    destination
#     0     0 RETURN     all  --  *   *    0.0.0.0/0 0.0.0.0/0  mark match 0x800
#     0     0 RETURN     all  --  *   *    0.0.0.0/0 127.0.0.0/8
#     0     0 RETURN     tcp  --  *   *    0.0.0.0/0 0.0.0.0/0  tcp dpt:15001
#     0     0 RETURN     all  --  *   *    0.0.0.0/0 10.0.1.5/32
#     0     0 PRYSM_REDIRECT all -- *   *  0.0.0.0/0 0.0.0.0/0

# Also check the redirect target
nsenter -t $POD_PID -n iptables -t nat -L PRYSM_REDIRECT -n -v

# Expected output:
# Chain PRYSM_REDIRECT (1 references)
#  pkts bytes target   prot opt in  out  source    destination
#     0     0 REDIRECT tcp  --  *   *    0.0.0.0/0 0.0.0.0/0  redir ports 15001
```

If the chains do not exist, the CNI plugin either did not run or the pod is in an excluded namespace.

## Verifying Tunnel Registration

When the CNI plugin runs successfully, it writes a file for the tunnel daemon:

```bash
# On the node, check registered pods
ls /var/run/prysm/tunnel-pods/

# Each file is named by pod UID and contains the netns path
cat /var/run/prysm/tunnel-pods/<pod-uid>
```

If the file exists but the tunnel daemon is not handling traffic, check the agent logs for netns listener errors.

## Common Issues

### Pod Stuck in ContainerCreating

**Symptom**: Pods stay in `ContainerCreating` after deploying the CNI DaemonSet.

**Cause**: The CNI binary or iptables script is missing from the node, or the conflist is malformed.

**Steps**:
1. Check the DaemonSet pod status: `kubectl get pods -n prysm-system -l app=prysm-cni-node`
2. Check the install logs: `kubectl logs -n prysm-system <cni-pod>`
3. Verify binaries exist on the node: `ls /opt/cni/bin/prysm-cni /opt/cni/bin/prysm-iptables.sh`
4. Verify the conflist is valid JSON: `cat /etc/cni/net.d/*.conflist | jq .`

### Traffic Not Being Redirected

**Symptom**: Pod traffic goes directly to the destination without passing through the tunnel daemon. No connection events appear in the mesh topology.

**Cause**: iptables rules were flushed or never applied.

**Steps**:
1. Verify iptables rules exist in the pod's netns (see above).
2. If rules are missing, restart the pod — the CNI plugin runs on pod creation, not continuously.
3. Check `/var/log/prysm-cni.log` on the node for errors during the pod's creation.

### mTLS Handshake Failures

**Symptom**: Cross-node connections fail. Agent logs show TLS errors like `certificate verify failed` or `unknown certificate authority`.

**Cause**: The pod's workload certificate has expired, was not issued, or the organization CA has rotated.

**Steps**:
1. Check the agent's mTLS status: `curl localhost:8080/mtls/status` from inside the agent pod.
2. Check tunnel daemon status: `curl localhost:8080/tunnel/status` — look at `certs_issued` count.
3. If certificates are expired, the agent should renew automatically. Check agent logs for certificate renewal errors.

### K3s Path Issues

**Symptom**: CNI binary not found on K3s nodes. Pods fail with CNI errors.

**Cause**: K3s stores CNI binaries in `/bin` instead of `/opt/cni/bin`, and config in `/var/lib/rancher/k3s/agent/etc/cni/net.d` instead of `/etc/cni/net.d`.

**Steps**:
1. Verify the DaemonSet has `MOUNTED_CNI_BIN_DIR_K3S=/host/bin` set.
2. Verify the DaemonSet mounts `/host/var/lib/rancher/k3s/agent/etc/cni/net.d`.
3. Check both paths on the node: `ls /bin/prysm-cni /opt/cni/bin/prysm-cni`

The default DaemonSet manifest handles K3s automatically.

### CNI Check Failures

**Symptom**: `kubectl exec` or pod health checks fail with CNI CHECK errors.

**Cause**: The `PRYSM_OUTPUT` chain was deleted from the pod's netns (e.g., by another tool resetting iptables).

**Steps**:
1. Verify the chain exists (see "Verifying iptables Rules" above).
2. If missing, delete and recreate the pod — the CNI plugin reprograms rules on pod creation.

## DaemonSet Removal and Cleanup

When the DaemonSet is deleted (or zero-trust is disabled on the backend), each DaemonSet pod receives `SIGTERM`. The install script's cleanup trap:

1. Removes the `prysm-cni` plugin entry from all CNI conflist files on the node.
2. Removes the standalone conflist if it was created (`prysm-pod-network`).
3. Deletes `prysm-cni` and `prysm-iptables.sh` binaries from `/opt/cni/bin` and `/bin` (K3s).
4. Exits cleanly.

Existing pods keep their iptables rules until they are restarted. New pods created after cleanup will not have redirect rules.

## Configuration Reference

### CNI Plugin Config

Passed as JSON via the CNI conflist. These fields are in the plugin entry with `"type": "prysm-cni"`:

| Field | Type | Default | Required | Description |
|-------|------|---------|----------|-------------|
| `targetPort` | string | `"15001"` | No | Port the tunnel daemon listens on for redirected traffic |
| `excludeNamespaces` | []string | `["kube-system", "kube-public", "prysm-system"]` | No | Namespaces where no iptables rules are programmed |
| `excludeCIDR` | string | `""` | No | Comma-separated CIDRs to exclude from redirect (e.g., `"10.43.0.0/16"`) |
| `nodeIP` | string | — | Yes | Node IP address for DNAT return-path exclusion rules |
| `noRedirectUID` | string | `"0"` | No | UID whose traffic is not redirected. `"0"` means no UID exclusion. |

### Install Script Environment Variables

Set on the DaemonSet container:

| Variable | Default | Description |
|----------|---------|-------------|
| `MOUNTED_CNI_BIN_DIR` | `/host/opt/cni/bin` | Host path where CNI binaries are installed (mounted into the container) |
| `MOUNTED_CNI_NET_DIR` | `/host/etc/cni/net.d` | Host path where CNI conflist files are stored (mounted into the container) |
| `MOUNTED_CNI_BIN_DIR_K3S` | *(unset)* | Additional binary directory for K3s nodes (`/host/bin`). If set and writable, binaries are copied here too. |
| `CHAINED_CNI_PLUGIN` | `"true"` | `"true"`: append to existing conflist. `"false"`: create standalone conflist. |
| `CNI_NETWORK_CONFIG` | *(unset)* | JSON string overriding the default plugin config. `nodeIP` is always injected from `HOST_IP`. |
| `HOST_IP` | *(from Kubernetes downward API)* | Node IP. Set via `status.hostIP` in the DaemonSet pod spec. Falls back to default route detection. |
| `SLEEP` | `"true"` | `"true"`: keep the container running after install (handles SIGTERM for cleanup). `"false"`: exit after install. |

### Agent Environment Variables

These configure the agent's CNI controller and tunnel daemon:

| Variable | Default | Description |
|----------|---------|-------------|
| `PRYSM_CNI_ENABLED` | *(from backend)* | Enable/disable CNI DaemonSet deployment |
| `PRYSM_CNI_TARGET_PORT` | `"15001"` | Port for iptables redirect |
| `PRYSM_CNI_EXCLUDE_NAMESPACES` | `"kube-system,kube-public,prysm-system,prysm-logging"` | Namespaces to skip |
| `PRYSM_CNI_IMAGE` | `"ghcr.io/prysmsh/cni:latest"` | Container image for the CNI DaemonSet |
| `PRYSM_CNI_RECONCILE_INTERVAL` | `5m` | How often the agent reconciles the DaemonSet |
| `TUNNEL_DAEMON_ENABLED` | `"false"` | Enable the tunnel daemon |
| `TUNNEL_DAEMON_OUTBOUND_PORT` | `"15001"` | Outbound listener port inside pod netns |
| `TUNNEL_DAEMON_INBOUND_PORT` | `"15002"` | Inbound mTLS listener port on the node |
