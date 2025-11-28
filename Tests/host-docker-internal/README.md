# host.docker.internal DNS Resolution Test

This test verifies that containers can resolve `host.docker.internal` to access services running on the host machine.

## Running the Test

### 1. Start a test HTTP server on your host

```bash
python3 -m http.server 8888
```

### 2. Configure Docker CLI to use Arca

```bash
export DOCKER_HOST=unix:///tmp/arca.sock
```

### 3. Run the test

```bash
cd tests/host-docker-internal
docker compose up
```

### Expected Output

**dns-test** should show the gateway IP:
```
Server:         192.168.64.1
Address:        192.168.64.1#53

Name:   host.docker.internal
Address: 192.168.64.1
```

**http-test** should successfully connect to the host's HTTP server:
```
* Connected to host.docker.internal (192.168.64.1) port 8888
< HTTP/1.0 200 OK
```

## Troubleshooting

If DNS resolution fails:
- Check that the Arca daemon is running with the updated vminit
- Verify the container is on a bridge network (not host network)
- Check daemon logs for DNS-related messages

If HTTP connection fails but DNS works:
- Verify your HTTP server is running on port 8888
- Check if any firewall is blocking the connection
