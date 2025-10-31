# Custom BuildKit image with vsock proxy for Arca
# Based on official moby/buildkit image

# Stage 1: Build vsock proxy
FROM golang:1.23-alpine AS proxy-builder

WORKDIR /build

# Copy proxy source
COPY proxy/main.go .

# Initialize go module and add vsock dependency
RUN go mod init vsock-proxy && \
    go get github.com/mdlayher/vsock@latest && \
    go mod tidy

# Build static binary for Linux
RUN CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags="-w -s" -o vsock-proxy main.go

# Stage 2: Final image based on official BuildKit
FROM moby/buildkit:latest

# Copy vsock proxy binary
COPY --from=proxy-builder /build/vsock-proxy /usr/local/bin/vsock-proxy

# Copy entrypoint script
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/vsock-proxy

# Use custom entrypoint that starts proxy + buildkitd
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
