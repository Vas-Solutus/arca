FROM alpine:3.22

# Install OVN/OVS and dependencies
RUN apk add --no-cache \
    openvswitch \
    openvswitch-ovn \
    dnsmasq \
    go \
    protobuf-dev \
    protoc-gen-go \
    protoc-gen-go-grpc \
    bash \
    iproute2 \
    iptables \
    curl

# Set up Go build environment
ENV GOPATH=/go
ENV PATH=$PATH:/go/bin

# Build control API server
COPY control-api/ /build/control-api/
WORKDIR /build/control-api
RUN go mod init arca-network-api || true
RUN go mod tidy || true
RUN go build -o /usr/local/bin/arca-network-api .

# Copy startup scripts
COPY scripts/startup.sh /usr/local/bin/startup.sh
COPY scripts/ovs-init.sh /usr/local/bin/ovs-init.sh
RUN chmod +x /usr/local/bin/startup.sh /usr/local/bin/ovs-init.sh

# Copy dnsmasq configuration
COPY config/dnsmasq.conf /etc/dnsmasq.conf

# Create directories for OVS/OVN
RUN mkdir -p /var/run/openvswitch /var/log/openvswitch /etc/openvswitch

# Expose vsock port for control API (port 9999)
# Note: vsock doesn't use EXPOSE but documenting for clarity
# EXPOSE 9999

ENTRYPOINT ["/usr/local/bin/startup.sh"]
