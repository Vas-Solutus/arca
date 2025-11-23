#!/bin/bash
#
# Phase 1 MVP Functionality Test Script
# Tests all basic Docker commands against Arca daemon
#
# Usage: ./scripts/test-phase1-mvp.sh
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
TEST_CONTAINER_NAME="arca-test-$(date +%s)"

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
echo "║         ARCA Phase 1 MVP Functionality Test Suite         ║"
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

# Test 1: docker ps (empty list)
run_test "List containers (empty)" \
    "docker ps -a" \
    "CONTAINER ID"

# Test 2: docker images (list current images)
run_test "List images" \
    "docker images" \
    "REPOSITORY"

# Test 3: docker pull with progress
print_test "Pull image with real-time progress"
echo -e "${YELLOW}Command:${NC} docker pull $TEST_IMAGE"
print_info "This should show progress bars and layer downloads..."
if docker pull "$TEST_IMAGE"; then
    print_success "Image pull with progress"
else
    print_failure "Image pull failed"
fi

# Test 4: Verify image exists
run_test "Verify pulled image exists" \
    "docker images $TEST_IMAGE" \
    "alpine"

# Test 5: docker run -d (create and start container)
print_test "Create and start container"
echo -e "${YELLOW}Command:${NC} docker run -d --name $TEST_CONTAINER_NAME $TEST_IMAGE sh -c 'echo Hello from Arca; sleep 2; echo Goodbye'"
if CONTAINER_ID=$(docker run -d --name "$TEST_CONTAINER_NAME" "$TEST_IMAGE" sh -c 'echo Hello from Arca; sleep 2; echo Goodbye'); then
    echo -e "${YELLOW}Container ID:${NC} $CONTAINER_ID"
    # Extract short ID (first 12 chars)
    SHORT_ID="${CONTAINER_ID:0:12}"
    echo -e "${YELLOW}Short ID:${NC} $SHORT_ID"
    print_success "Container created with ID $SHORT_ID"
else
    print_failure "Failed to create container"
    exit 1
fi

# Test 6: docker ps (with running container)
run_test "List running containers" \
    "docker ps" \
    "$SHORT_ID"

# Test 7: Wait for container to finish
print_info "Waiting for container to exit..."
sleep 3

# Test 8: docker logs
run_test "View container logs" \
    "docker logs $SHORT_ID" \
    "Hello from Arca"

# Test 9: docker ps -a (with exited container)
run_test "List all containers (including exited)" \
    "docker ps -a" \
    "$SHORT_ID"

# Test 10: docker start (restart exited container)
run_test "Restart exited container" \
    "docker start $SHORT_ID" \
    "$SHORT_ID"

# Test 11: docker stop (using short ID)
print_info "Waiting a moment for container to run..."
sleep 1
run_test "Stop container by short ID" \
    "docker stop $SHORT_ID" \
    "$SHORT_ID"

# Test 12: docker rm (remove container)
run_test "Remove container" \
    "docker rm $SHORT_ID" \
    "$SHORT_ID"

# Test 13: Verify container is removed
print_test "Verify container no longer exists"
if docker ps -a | grep -q "$SHORT_ID"; then
    print_failure "Container still exists after removal"
else
    print_success "Container successfully removed"
fi

# Test 14: Force remove running container
print_test "Create and start container for force removal test"
FORCE_CONTAINER="arca-force-test-$(date +%s)"
FORCE_ID=$(docker run -d --name "$FORCE_CONTAINER" "$TEST_IMAGE" sleep 30)
FORCE_SHORT_ID="${FORCE_ID:0:12}"
echo -e "${YELLOW}Container ID:${NC} $FORCE_SHORT_ID"

run_test "Force remove running container" \
    "docker rm -f $FORCE_SHORT_ID" \
    "$FORCE_SHORT_ID"

# Test 15: Remove container without starting
print_test "Create container without starting"
CREATE_ONLY_CONTAINER="arca-create-only-$(date +%s)"
CREATE_ONLY_ID=$(docker create --name "$CREATE_ONLY_CONTAINER" "$TEST_IMAGE" echo "test")
CREATE_ONLY_SHORT_ID="${CREATE_ONLY_ID:0:12}"
echo -e "${YELLOW}Container ID:${NC} $CREATE_ONLY_SHORT_ID"

run_test "Remove container without starting" \
    "docker rm $CREATE_ONLY_SHORT_ID" \
    "$CREATE_ONLY_SHORT_ID"

# Test 16: Get image ID for deletion test
print_test "Get image short ID for deletion test"
IMAGE_ID=$(docker images -q "$TEST_IMAGE" | head -1)
IMAGE_SHORT_ID="${IMAGE_ID:0:12}"  # Get first 12 chars of image ID
echo -e "${YELLOW}Image ID:${NC} $IMAGE_ID"
echo -e "${YELLOW}Short ID:${NC} $IMAGE_SHORT_ID"

# Test 17: docker rmi by short ID
run_test "Remove image by short ID" \
    "docker rmi $IMAGE_SHORT_ID" \
    ""

# Test 18: Pull image again for name-based deletion
print_info "Pulling image again to test name-based deletion..."
docker pull "$TEST_IMAGE" >/dev/null 2>&1

# Test 19: docker rmi by name
run_test "Remove image by name" \
    "docker rmi $TEST_IMAGE" \
    "Untagged"

# Test 20: Error handling - missing image
print_test "Error handling: Delete non-existent image"
if docker rmi nonexistent:image 2>&1 | grep -q "No such image"; then
    print_success "Correctly returns 'No such image' error"
else
    print_failure "Did not return expected error for missing image"
fi

# Test 21: Error handling - missing container
print_test "Error handling: Stop non-existent container"
if docker stop nonexistent123 2>&1 | grep -q "No such container"; then
    print_success "Correctly returns 'No such container' error"
else
    print_failure "Did not return expected error for missing container"
fi

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
    echo "║  ✓ ALL TESTS PASSED - Phase 1 MVP is fully functional!  ║"
    echo "╚════════════════════════════════════════════════════════════╝${NC}\n"
    exit 0
else
    echo -e "\n${RED}╔════════════════════════════════════════════════════════════╗"
    echo "║  ✗ SOME TESTS FAILED - Please review the output above    ║"
    echo "╚════════════════════════════════════════════════════════════╝${NC}\n"
    exit 1
fi
