# ============================================================================
# Stage 1: Builder - Build OVS, OVN, and Go control API server
# ============================================================================
FROM alpine:3.22 AS builder

# Install build dependencies
RUN apk add --no-cache \
    # Build tools
    build-base \
    autoconf \
    automake \
    libtool \
    linux-headers \
    python3 \
    python3-dev \
    py3-pip \
    openssl-dev \
    libcap-ng-dev \
    unbound-dev \
    # Go for control API
    go \
    protobuf-dev \
    # Download tools
    wget \
    ca-certificates

# Set up Go environment
ENV GOPATH=/go
ENV PATH=$PATH:/go/bin

# Install Go protoc plugins
RUN go install google.golang.org/protobuf/cmd/protoc-gen-go@latest && \
    go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest

# Build Open vSwitch v3.6.0 from source
WORKDIR /tmp/ovs-build
RUN wget https://www.openvswitch.org/releases/openvswitch-3.6.0.tar.gz && \
    tar xzf openvswitch-3.6.0.tar.gz && \
    cd openvswitch-3.6.0 && \
    ./configure \
        --prefix=/usr \
        --localstatedir=/var \
        --sysconfdir=/etc \
        --enable-ssl && \
    make -j$(nproc) && \
    make install DESTDIR=/tmp/ovs-install && \
    make install

# Build OVN v25.09 from source
WORKDIR /tmp/ovn-build
RUN wget https://github.com/ovn-org/ovn/archive/refs/tags/v25.09.0.tar.gz && \
    tar xzf v25.09.0.tar.gz && \
    cd ovn-25.09.0 && \
    ./boot.sh && \
    ./configure \
        --prefix=/usr \
        --localstatedir=/var \
        --sysconfdir=/etc \
        --with-ovs-source=/tmp/ovs-build/openvswitch-3.6.0 && \
    make -j$(nproc) && \
    make install DESTDIR=/tmp/ovn-install && \
    make install

# Build control API server
COPY control-api/ /build/control-api/
WORKDIR /build/control-api
RUN go mod init arca-network-api || true && \
    go mod tidy && \
    CGO_ENABLED=0 go build -o /tmp/arca-network-api .

# ============================================================================
# Stage 2: Runtime - Minimal image with only necessary components
# ============================================================================
FROM alpine:3.22

# Install only runtime dependencies
RUN apk add --no-cache \
    bash \
    dnsmasq \
    iproute2 \
    iptables \
    openssl \
    libcap-ng \
    unbound-libs \
    python3 \
    curl

# Copy OVS binaries and libraries from builder
COPY --from=builder /tmp/ovs-install/usr /usr
COPY --from=builder /usr/bin/ovs-* /usr/bin/
COPY --from=builder /usr/sbin/ovs-* /usr/sbin/
COPY --from=builder /usr/share/openvswitch /usr/share/openvswitch

# Copy OVN binaries and libraries from builder
COPY --from=builder /tmp/ovn-install/usr /usr
COPY --from=builder /usr/bin/ovn-* /usr/bin/
COPY --from=builder /usr/share/ovn /usr/share/ovn

# Copy control API server
COPY --from=builder /tmp/arca-network-api /usr/local/bin/arca-network-api
RUN chmod +x /usr/local/bin/arca-network-api

# Copy startup scripts
COPY scripts/startup.sh /usr/local/bin/startup.sh
COPY scripts/ovs-init.sh /usr/local/bin/ovs-init.sh
RUN chmod +x /usr/local/bin/startup.sh /usr/local/bin/ovs-init.sh

# Copy dnsmasq configuration
COPY config/dnsmasq.conf /etc/dnsmasq.conf

# Create directories for OVS/OVN
RUN mkdir -p \
    /var/run/openvswitch \
    /var/log/openvswitch \
    /var/log/ovn \
    /etc/openvswitch \
    /etc/ovn \
    /var/run/ovn

# Expose TCP port for control API (port 9999)
# Note: Using TCP instead of vsock due to grpc-swift limitation
EXPOSE 9999

ENTRYPOINT ["/usr/local/bin/startup.sh"]
