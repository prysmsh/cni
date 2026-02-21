package redirect

import (
	"fmt"
	"os"
	"os/exec"
)

const (
	DefaultTargetPort    = "15001"
	DefaultNoRedirectUID = "0"
)

// scriptSearchPaths lists locations to look for prysm-iptables.sh.
// k3s uses /bin, standard CNI installs use /opt/cni/bin.
var scriptSearchPaths = []string{
	"/opt/cni/bin/prysm-iptables.sh",
	"/bin/prysm-iptables.sh",
}

// findScript returns the first existing path from scriptSearchPaths.
func findScript() (string, error) {
	for _, p := range scriptSearchPaths {
		if _, err := os.Stat(p); err == nil {
			return p, nil
		}
	}
	return "", fmt.Errorf("prysm-iptables.sh not found in %v", scriptSearchPaths)
}

// Program sets up iptables NAT REDIRECT rules in the given network namespace.
// nodeIP is required — traffic to the node itself is excluded from redirect.
func Program(netns, targetPort, noRedirectUID, excludeCIDR, nodeIP string) error {
	if targetPort == "" {
		targetPort = DefaultTargetPort
	}
	if noRedirectUID == "" {
		noRedirectUID = DefaultNoRedirectUID
	}
	if nodeIP == "" {
		return fmt.Errorf("nodeIP is required for TPROXY mode")
	}

	scriptPath, err := findScript()
	if err != nil {
		return err
	}

	// Run via sh explicitly to avoid "No such file or directory" when nsenter execs
	// a script directly (shebang resolution can fail in some container/k3s environments)
	nsenterArgs := []string{
		"--net=" + netns,
		"/bin/sh", scriptPath,
		targetPort,
		noRedirectUID,
		excludeCIDR,
		nodeIP,
	}
	cmd := exec.Command("nsenter", nsenterArgs...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("prysm-iptables failed: %w: %s", err, string(out))
	}
	return nil
}

// Check verifies that iptables redirect rules are still in place in the given
// network namespace. Returns an error if the PRYSM_OUTPUT chain is missing.
func Check(netns string) error {
	cmd := exec.Command("nsenter", "--net="+netns,
		"iptables", "-t", "nat", "-L", "PRYSM_OUTPUT", "-n")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("iptables redirect rules missing in %s: %w: %s", netns, err, string(out))
	}
	return nil
}

// Clean removes iptables redirect rules from the given network namespace.
func Clean(netns string) error {
	scriptPath, err := findScript()
	if err != nil {
		return nil // best-effort: if script is gone, nothing to clean
	}
	nsenterArgs := []string{
		"--net=" + netns,
		"/bin/sh", scriptPath,
		"clean",
	}
	cmd := exec.Command("nsenter", nsenterArgs...)
	_ = cmd.Run() // Best-effort cleanup
	return nil
}
