# Prysm CNI - Build stage
FROM golang:1.26.0-alpine AS builder
RUN apk add --no-cache git
WORKDIR /build

COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 go build -o prysm-cni ./cmd/prysm-cni

# Install stage - minimal image for CNI install DaemonSet
FROM alpine:3.21
RUN apk add --no-cache jq iptables

# Standard CNI bin path
COPY --from=builder /build/prysm-cni /opt/cni/bin/prysm-cni
COPY scripts/prysm-iptables.sh /opt/cni/bin/prysm-iptables.sh
# K3s containerd uses bin_dir="/bin"
COPY --from=builder /build/prysm-cni /bin/prysm-cni
COPY scripts/prysm-iptables.sh /bin/prysm-iptables.sh
RUN chmod +x /opt/cni/bin/prysm-cni /opt/cni/bin/prysm-iptables.sh /bin/prysm-cni /bin/prysm-iptables.sh

# Install script and config
COPY deployments/install/install-cni.sh /install-cni.sh
COPY deployments/install/10-prysm-cni.conflist.template /etc/cni/net.d/10-prysm-cni.conflist.template
RUN chmod +x /install-cni.sh

ENV SLEEP=true
CMD ["/install-cni.sh"]
