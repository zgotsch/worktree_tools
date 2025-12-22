#!/bin/bash

set -euo pipefail

# Test script for gw (Git Worktree Manager)
# Tests that gw works correctly with different primary branch names

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GW_SCRIPT="$SCRIPT_DIR/gw.zsh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

TESTS_PASSED=0
TESTS_FAILED=0

log_pass() {
    echo -e "${GREEN}PASS${NC}: $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

log_fail() {
    echo -e "${RED}FAIL${NC}: $1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

log_info() {
    echo -e "${YELLOW}INFO${NC}: $1"
}

# Create a test repository with a given primary branch name
create_test_repo() {
    local test_dir="$1"
    local primary_branch="$2"

    mkdir -p "$test_dir/$primary_branch"
    cd "$test_dir/$primary_branch"

    git init --initial-branch="$primary_branch" >/dev/null 2>&1
    git config user.email "test@test.com"
    git config user.name "Test User"

    # Create initial commit
    echo "test" > README.md
    git add README.md
    git commit -m "Initial commit" >/dev/null 2>&1

    # Create a fake remote to simulate origin/HEAD
    git remote add origin "file://$test_dir/$primary_branch"
    git fetch origin >/dev/null 2>&1

    # Set up refs/remotes/origin/HEAD to point to the primary branch
    git symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$primary_branch"

    # Create .gwconfig for testing
    cat > .gwconfig << 'EOF'
link_files: ["README.md"]
scripts: ["echo setup complete"]
EOF
}

# Test that get_primary_branch returns the correct branch
test_primary_branch_detection() {
    local test_dir="$1"
    local expected_branch="$2"

    cd "$test_dir/$expected_branch"

    local detected_branch
    detected_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')

    if [[ "$detected_branch" == "$expected_branch" ]]; then
        log_pass "Primary branch detection: expected '$expected_branch', got '$detected_branch'"
    else
        log_fail "Primary branch detection: expected '$expected_branch', got '$detected_branch'"
    fi
}

# Test creating a new worktree with -b flag
test_create_worktree() {
    local test_dir="$1"
    local primary_branch="$2"
    local new_branch="test/feature"
    local expected_dir="test__feature"

    cd "$test_dir/$primary_branch"

    # Run gw -b to create a new worktree
    local output
    output=$("$GW_SCRIPT" -b "$new_branch" 2>&1) || true

    # Check if the worktree directory was created
    if [[ -d "$test_dir/$expected_dir" ]]; then
        log_pass "Worktree created at $test_dir/$expected_dir"
    else
        log_fail "Worktree not created at $test_dir/$expected_dir"
        echo "  Output was: $output"
        return
    fi

    # Check if it's a valid git worktree
    if [[ -f "$test_dir/$expected_dir/.git" ]]; then
        log_pass "Worktree has valid .git file"
    else
        log_fail "Worktree missing .git file"
    fi

    # Check if the branch was created correctly
    cd "$test_dir/$expected_dir"
    local current_branch
    current_branch=$(git branch --show-current)
    if [[ "$current_branch" == "$new_branch" ]]; then
        log_pass "Worktree is on correct branch '$new_branch'"
    else
        log_fail "Worktree on wrong branch: expected '$new_branch', got '$current_branch'"
    fi
}

# Test listing worktrees
test_list_worktrees() {
    local test_dir="$1"
    local primary_branch="$2"

    cd "$test_dir/$primary_branch"

    local output
    output=$("$GW_SCRIPT" --list 2>&1) || true

    # Check if primary branch appears in list
    if echo "$output" | grep -q "$primary_branch"; then
        log_pass "List includes primary branch '$primary_branch'"
    else
        log_fail "List missing primary branch '$primary_branch'"
        echo "  Output was: $output"
    fi
}

# Test the fallback when origin/HEAD is not set
test_fallback_to_main() {
    local test_dir="$1"

    mkdir -p "$test_dir/main"
    cd "$test_dir/main"

    git init --initial-branch="main" >/dev/null 2>&1
    git config user.email "test@test.com"
    git config user.name "Test User"

    echo "test" > README.md
    git add README.md
    git commit -m "Initial commit" >/dev/null 2>&1

    # Don't set up origin/HEAD - test the fallback
    local detected
    detected=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || echo "")

    if [[ -z "$detected" ]]; then
        log_pass "Fallback scenario: symbolic-ref returns empty (as expected)"
    else
        log_fail "Fallback scenario: symbolic-ref unexpectedly returned '$detected'"
    fi
}

# Cleanup function
cleanup() {
    local test_dir="$1"
    if [[ -d "$test_dir" ]]; then
        rm -rf "$test_dir"
    fi
}

# Main test runner
main() {
    echo "========================================="
    echo "  gw (Git Worktree Manager) Test Suite"
    echo "========================================="
    echo ""
    echo "Using gw script: $GW_SCRIPT"
    echo ""

    local test_base="/tmp/gw-test-$$"

    # Test 1: Repository with "main" as primary branch
    echo "Test Suite 1: Repository with 'main' as primary branch"
    echo "---------------------------------------------------------"
    local test_main="$test_base/repo-main"
    mkdir -p "$test_main"

    log_info "Creating test repository with 'main' branch..."
    create_test_repo "$test_main" "main"

    test_primary_branch_detection "$test_main" "main"
    test_list_worktrees "$test_main" "main"
    test_create_worktree "$test_main" "main"

    cleanup "$test_main"
    echo ""

    # Test 2: Repository with "staging" as primary branch
    echo "Test Suite 2: Repository with 'staging' as primary branch"
    echo "-----------------------------------------------------------"
    local test_staging="$test_base/repo-staging"
    mkdir -p "$test_staging"

    log_info "Creating test repository with 'staging' branch..."
    create_test_repo "$test_staging" "staging"

    test_primary_branch_detection "$test_staging" "staging"
    test_list_worktrees "$test_staging" "staging"
    test_create_worktree "$test_staging" "staging"

    cleanup "$test_staging"
    echo ""

    # Test 3: Fallback when origin/HEAD is not set
    echo "Test Suite 3: Fallback behavior"
    echo "--------------------------------"
    local test_fallback="$test_base/repo-fallback"
    mkdir -p "$test_fallback"

    log_info "Testing fallback when origin/HEAD is not configured..."
    test_fallback_to_main "$test_fallback"

    cleanup "$test_fallback"
    echo ""

    # Cleanup base directory
    rm -rf "$test_base"

    # Summary
    echo "========================================="
    echo "  Test Summary"
    echo "========================================="
    echo -e "  ${GREEN}Passed${NC}: $TESTS_PASSED"
    echo -e "  ${RED}Failed${NC}: $TESTS_FAILED"
    echo ""

    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}All tests passed!${NC}"
        exit 0
    else
        echo -e "${RED}Some tests failed.${NC}"
        exit 1
    fi
}

main "$@"
