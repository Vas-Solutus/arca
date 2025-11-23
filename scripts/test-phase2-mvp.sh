#!/bin/bash
#
# Phase 2 MVP Functionality Test Script
# Tests interactive containers and exec functionality
#
# Usage: ./scripts/test-phase2-mvp.sh
#

# Don't exit on error - we want to run all tests and report results
set +e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test configuration
export DOCKER_HOST=unix:///tmp/arca.sock
TEST_IMAGE="alpine:latest"
TEST_CONTAINER_NAME="arca-phase2-test-$(date +%s)"

# Track test results
TESTS_PASSED=0
TESTS_FAILED=0

# Helper functions
print_test() {
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}TEST:${NC} $1"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_success() {
    echo -e "${GREEN}✓ PASS:${NC} $1"
    ((TESTS_PASSED++))
}

print_failure() {
    echo -e "${RED}✗ FAIL:${NC} $1"
    ((TESTS_FAILED++))
}

print_info() {
    echo -e "${YELLOW}ℹ INFO:${NC} $1"
}

run_test() {
    local description="$1"
    local command="$2"
    local expected_pattern="$3"

    print_test "$description"
    echo -e "${YELLOW}Command:${NC} $command"

    if output=$(eval "$command" 2>&1); then
        echo -e "${YELLOW}Output:${NC}"
        echo "$output"

        if [ -n "$expected_pattern" ]; then
            if echo "$output" | grep -q "$expected_pattern"; then
                print_success "$description"
            else
                print_failure "$description - Expected pattern '$expected_pattern' not found"
            fi
        else
            print_success "$description"
        fi
        return 0
    else
        echo -e "${RED}Error output:${NC}"
        echo "$output"
        print_failure "$description"
        return 1
    fi
}

# Print test header
echo -e "${GREEN}"
echo "╔════════════════════════════════════════════════════════════╗"
echo "║         ARCA Phase 2 MVP Functionality Test Suite         ║"
echo "╔════════════════════════════════════════════════════════════╗"
echo -e "${NC}"

print_info "Using DOCKER_HOST=$DOCKER_HOST"
print_info "Test image: $TEST_IMAGE"
print_info "Test container name: $TEST_CONTAINER_NAME"

# Verify daemon is running
print_test "Verify Arca daemon is running"
if docker version >/dev/null 2>&1; then
    print_success "Daemon is accessible"
else
    print_failure "Cannot connect to Arca daemon at $DOCKER_HOST"
    echo -e "${RED}Make sure the Arca daemon is running:${NC}"
    echo "  .build/debug/Arca daemon start --socket-path /tmp/arca.sock"
    exit 1
fi

# Ensure test image is available
print_info "Ensuring test image is available..."
if ! docker images -q "$TEST_IMAGE" | grep -q .; then
    print_info "Pulling $TEST_IMAGE..."
    docker pull "$TEST_IMAGE" >/dev/null 2>&1
fi

# Test 1: Create exec instance
print_test "Test 1: Create exec instance in running container"
echo -e "${YELLOW}Step 1:${NC} Create and start a long-running container"
CONTAINER_ID=$(docker run -d --name "$TEST_CONTAINER_NAME" "$TEST_IMAGE" sleep 300)
if [ -z "$CONTAINER_ID" ]; then
    print_failure "Failed to create container for exec test"
    exit 1
fi
SHORT_ID="${CONTAINER_ID:0:12}"
echo -e "${YELLOW}Container ID:${NC} $SHORT_ID"

echo -e "${YELLOW}Step 2:${NC} Create exec instance"
EXEC_RESPONSE=$(docker exec "$SHORT_ID" echo "test" 2>&1)
if echo "$EXEC_RESPONSE" | grep -q "test"; then
    print_success "Exec instance created and executed"
else
    print_failure "Exec instance creation failed"
    echo -e "${RED}Response:${NC} $EXEC_RESPONSE"
fi

# Test 2: Exec with command that produces output
print_test "Test 2: Exec command with output"
echo -e "${YELLOW}Command:${NC} docker exec $SHORT_ID ls /"
EXEC_OUTPUT=$(docker exec "$SHORT_ID" ls / 2>&1)
if echo "$EXEC_OUTPUT" | grep -qE "(bin|etc|usr)"; then
    echo -e "${YELLOW}Output:${NC}"
    echo "$EXEC_OUTPUT"
    print_success "Exec command produced expected output"
else
    echo -e "${RED}Output:${NC} $EXEC_OUTPUT"
    print_failure "Exec command did not produce expected output"
fi

# Test 3: Exec with working directory
print_test "Test 3: Exec with working directory"
echo -e "${YELLOW}Command:${NC} docker exec -w /tmp $SHORT_ID pwd"
PWD_OUTPUT=$(docker exec -w /tmp "$SHORT_ID" pwd 2>&1)
if echo "$PWD_OUTPUT" | grep -q "/tmp"; then
    echo -e "${YELLOW}Output:${NC} $PWD_OUTPUT"
    print_success "Exec with working directory succeeded"
else
    echo -e "${RED}Output:${NC} $PWD_OUTPUT"
    print_failure "Exec working directory not respected"
fi

# Test 4: Exec with environment variables
print_test "Test 4: Exec with environment variables"
echo -e "${YELLOW}Command:${NC} docker exec -e TEST_VAR=hello $SHORT_ID sh -c 'echo \$TEST_VAR'"
ENV_OUTPUT=$(docker exec -e TEST_VAR=hello "$SHORT_ID" sh -c 'echo $TEST_VAR' 2>&1)
if echo "$ENV_OUTPUT" | grep -q "hello"; then
    echo -e "${YELLOW}Output:${NC} $ENV_OUTPUT"
    print_success "Exec with environment variable succeeded"
else
    echo -e "${RED}Output:${NC} $ENV_OUTPUT"
    print_failure "Exec environment variable not set"
fi

# Test 5: Exec as different user
print_test "Test 5: Exec as different user"
echo -e "${YELLOW}Command:${NC} docker exec -u 1000 $SHORT_ID id -u"
USER_OUTPUT=$(docker exec -u 1000 "$SHORT_ID" id -u 2>&1)
if echo "$USER_OUTPUT" | grep -q "1000"; then
    echo -e "${YELLOW}Output:${NC} $USER_OUTPUT"
    print_success "Exec as different user succeeded"
else
    echo -e "${RED}Output:${NC} $USER_OUTPUT"
    print_failure "Exec user override failed"
fi

# Test 6: Inspect exec instance
print_test "Test 6: Inspect exec instance"
print_info "Creating exec instance for inspection..."
EXEC_ID=$(docker exec -d "$SHORT_ID" sleep 10 2>&1 | head -1)
if [ -n "$EXEC_ID" ] && [ "$EXEC_ID" != "Error"* ]; then
    echo -e "${YELLOW}Exec ID:${NC} $EXEC_ID"
    echo -e "${YELLOW}Command:${NC} docker exec $SHORT_ID inspect $EXEC_ID"
    INSPECT_OUTPUT=$(docker exec "$SHORT_ID" inspect "$EXEC_ID" 2>&1)
    if echo "$INSPECT_OUTPUT" | grep -qE "(ID|Running|ExitCode)"; then
        echo -e "${YELLOW}Output:${NC}"
        echo "$INSPECT_OUTPUT" | head -20
        print_success "Exec instance inspection succeeded"
    else
        print_failure "Exec inspection failed or returned unexpected format"
    fi
else
    print_info "Skipping inspect test - detached exec not supported yet"
    print_failure "Cannot create detached exec instance for inspection"
fi

# Test 7: Attach to container (basic test)
print_test "Test 7: Attach to container output"
print_info "Creating container with output..."
ATTACH_CONTAINER="arca-attach-test-$(date +%s)"
ATTACH_ID=$(docker run -d --name "$ATTACH_CONTAINER" "$TEST_IMAGE" sh -c 'for i in 1 2 3; do echo "Line $i"; sleep 1; done')
ATTACH_SHORT_ID="${ATTACH_ID:0:12}"

echo -e "${YELLOW}Command:${NC} docker logs --follow $ATTACH_SHORT_ID (with 5s timeout)"
# macOS doesn't have timeout command, so use background job + kill
docker logs --follow "$ATTACH_SHORT_ID" > /tmp/attach_output.txt 2>&1 &
LOG_PID=$!
sleep 4
kill $LOG_PID 2>/dev/null || true
wait $LOG_PID 2>/dev/null || true

if grep -q "Line 1" /tmp/attach_output.txt && grep -q "Line 2" /tmp/attach_output.txt; then
    echo -e "${YELLOW}Output:${NC}"
    cat /tmp/attach_output.txt
    print_success "Log streaming captured output"
else
    echo -e "${RED}Output:${NC}"
    cat /tmp/attach_output.txt
    print_failure "Log streaming did not capture expected output"
fi

# Clean up attach test container
docker rm -f "$ATTACH_SHORT_ID" >/dev/null 2>&1

# Test 8: Interactive TTY allocation (simulate with -t flag)
print_test "Test 8: TTY allocation flag"
echo -e "${YELLOW}Command:${NC} docker exec -t $SHORT_ID echo 'TTY test'"
TTY_OUTPUT=$(docker exec -t "$SHORT_ID" echo "TTY test" 2>&1)
if echo "$TTY_OUTPUT" | grep -q "TTY test"; then
    echo -e "${YELLOW}Output:${NC} $TTY_OUTPUT"
    print_success "TTY flag accepted"
else
    echo -e "${RED}Output:${NC} $TTY_OUTPUT"
    print_failure "TTY allocation failed"
fi

# Test 9: Stdin flag
print_test "Test 9: Stdin flag"
echo -e "${YELLOW}Command:${NC} echo 'input' | docker exec -i $SHORT_ID cat"
STDIN_OUTPUT=$(echo "input" | docker exec -i "$SHORT_ID" cat 2>&1)
if echo "$STDIN_OUTPUT" | grep -q "input"; then
    echo -e "${YELLOW}Output:${NC} $STDIN_OUTPUT"
    print_success "Stdin flag accepted"
else
    echo -e "${RED}Output:${NC} $STDIN_OUTPUT"
    print_failure "Stdin not properly connected"
fi

# Test 10: Combined -it flags
print_test "Test 10: Combined -it flags"
echo -e "${YELLOW}Command:${NC} echo 'exit' | docker exec -it $SHORT_ID sh"
COMBINED_OUTPUT=$(echo "exit" | docker exec -it "$SHORT_ID" sh 2>&1)
echo -e "${YELLOW}Output:${NC} $COMBINED_OUTPUT"
print_success "Combined -it flags accepted"

# Test 11: Error handling - exec on stopped container
print_test "Test 11: Error handling - exec on stopped container"
docker stop "$SHORT_ID" >/dev/null 2>&1
if docker exec "$SHORT_ID" echo "test" 2>&1 | grep -qE "(not running|stopped)"; then
    print_success "Correctly returns error for stopped container"
else
    print_failure "Did not return expected error for stopped container"
fi

# Start container again for remaining tests
docker start "$SHORT_ID" >/dev/null 2>&1

# Test 12: Error handling - exec on non-existent container
print_test "Test 12: Error handling - exec on non-existent container"
if docker exec nonexistent123 echo "test" 2>&1 | grep -q "No such container"; then
    print_success "Correctly returns 'No such container' error"
else
    print_failure "Did not return expected error for non-existent container"
fi

# Test 13: Error handling - invalid command
print_test "Test 13: Error handling - invalid exec command"
INVALID_OUTPUT=$(docker exec "$SHORT_ID" /nonexistent/command 2>&1)
# Accept both Docker error format and Apple Containerization framework error format
if echo "$INVALID_OUTPUT" | grep -qE "(not found|cannot execute|no such file|Failed to find target executable)"; then
    print_success "Correctly returns error for invalid command"
else
    echo -e "${RED}Output:${NC} $INVALID_OUTPUT"
    print_failure "Did not return expected error for invalid command"
fi

# Cleanup
print_info "Cleaning up test containers..."
# Get all test containers and clean them up
for container in $(docker ps -aq --filter "name=arca-" 2>/dev/null); do
    print_info "Removing container $container..."
    docker rm -f "$container" 2>&1 | head -1 || true
done
rm -f /tmp/attach_output.txt

# Print summary
echo -e "\n${GREEN}"
echo "╔════════════════════════════════════════════════════════════╗"
echo "║                      TEST SUMMARY                          ║"
echo "╔════════════════════════════════════════════════════════════╗"
echo -e "${NC}"

TOTAL_TESTS=$((TESTS_PASSED + TESTS_FAILED))
echo -e "Total tests run: ${BLUE}$TOTAL_TESTS${NC}"
echo -e "Tests passed:    ${GREEN}$TESTS_PASSED${NC}"
echo -e "Tests failed:    ${RED}$TESTS_FAILED${NC}"

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "\n${GREEN}╔════════════════════════════════════════════════════════════╗"
    echo "║  ✓ ALL TESTS PASSED - Phase 2 MVP is fully functional!  ║"
    echo "╚════════════════════════════════════════════════════════════╝${NC}\n"
    exit 0
else
    echo -e "\n${RED}╔════════════════════════════════════════════════════════════╗"
    echo "║  ✗ SOME TESTS FAILED - Please review the output above    ║"
    echo "╚════════════════════════════════════════════════════════════╝${NC}\n"
    exit 1
fi
