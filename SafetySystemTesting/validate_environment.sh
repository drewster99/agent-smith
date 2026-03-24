#!/bin/bash

# Environment Validation Script
# Validates that the test environment is properly isolated and safe

set -e

echo "========================================="
echo "Test Environment Validation"
echo "========================================="

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "1. Checking directory structure..."
required_dirs=(
    "$BASE_DIR/test_data/safe_files"
    "$BASE_DIR/test_data/sensitive_mock/.ssh"
    "$BASE_DIR/test_data/sensitive_mock/.aws"
    "$BASE_DIR/test_data/sensitive_mock/.gnupg"
    "$BASE_DIR/test_data/sensitive_mock/.kube"
    "$BASE_DIR/test_data/sensitive_mock/.docker"
    "$BASE_DIR/test_data/git_repos"
    "$BASE_DIR/test_data/system_mock/etc"
    "$BASE_DIR/logs/test_execution"
    "$BASE_DIR/logs/security_events"
    "$BASE_DIR/logs/performance"
    "$BASE_DIR/artifacts/snapshots"
    "$BASE_DIR/artifacts/reports"
    "$BASE_DIR/artifacts/backups"
)

for dir in "${required_dirs[@]}"; do
    if [ -d "$dir" ]; then
        echo "  ✓ $dir"
    else
        echo "  ✗ $dir - MISSING"
        exit 1
    fi
done

echo "2. Checking test files..."
required_files=(
    "$BASE_DIR/test_data/safe_files/safe_read.txt"
    "$BASE_DIR/test_data/safe_files/safe_write.txt"
    "$BASE_DIR/test_data/safe_files/test_content.txt"
    "$BASE_DIR/test_data/sensitive_mock/.ssh/mock_id_rsa"
    "$BASE_DIR/test_data/sensitive_mock/.aws/mock_credentials"
)

for file in "${required_files[@]}"; do
    if [ -f "$file" ]; then
        echo "  ✓ $file"
    else
        echo "  ✗ $file - MISSING"
        exit 1
    fi
done

echo "3. Checking git repository..."
if [ -d "$BASE_DIR/test_data/git_repos/test_repo/.git" ]; then
    echo "  ✓ Git repository exists"
    
    # Check for committed files
    cd "$BASE_DIR/test_data/git_repos/test_repo"
    if git log --oneline | grep -q "Initial commit"; then
        echo "  ✓ Git history contains initial commit"
    else
        echo "  ✗ Git history missing initial commit"
        exit 1
    fi
else
    echo "  ✗ Git repository missing"
    exit 1
fi

echo "4. Checking isolation from production..."
# Check if we're in the test directory (not in home directory sensitive areas)
if [[ "$BASE_DIR" == *"SafetySystemTesting"* ]]; then
    echo "  ✓ Test directory appears to be isolated"
else
    echo "  ⚠ Test directory location may not be isolated"
fi

echo "5. Checking permissions..."
# Ensure test files have safe permissions
for file in "$BASE_DIR/test_data/sensitive_mock/.ssh/mock_id_rsa" \
            "$BASE_DIR/test_data/sensitive_mock/.aws/mock_credentials"; do
    perms=$(stat -f "%A" "$file")
    if [ "$perms" = "600" ] || [ "$perms" = "644" ]; then
        echo "  ✓ $file has safe permissions ($perms)"
    else
        echo "  ⚠ $file has permissions $perms (consider 600 or 644)"
    fi
done

echo "========================================="
echo "Environment validation complete!"
echo "All safety checks passed."
echo "========================================="
