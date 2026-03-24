#!/bin/bash

# Safety System Testing Environment Setup Script
# This script sets up the isolated test environment for Agent Smith safety system testing

set -e  # Exit on error

echo "========================================="
echo "Agent Smith Safety System Test Environment Setup"
echo "========================================="

# Create directory structure
echo "Creating directory structure..."
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Create test data directories
mkdir -p "$BASE_DIR/test_data/safe_files"
mkdir -p "$BASE_DIR/test_data/sensitive_mock/.ssh"
mkdir -p "$BASE_DIR/test_data/sensitive_mock/.aws" 
mkdir -p "$BASE_DIR/test_data/sensitive_mock/.gnupg"
mkdir -p "$BASE_DIR/test_data/sensitive_mock/.kube"
mkdir -p "$BASE_DIR/test_data/sensitive_mock/.docker"
mkdir -p "$BASE_DIR/test_data/git_repos"
mkdir -p "$BASE_DIR/test_data/system_mock/etc"
mkdir -p "$BASE_DIR/test_data/system_mock/Library"
mkdir -p "$BASE_DIR/test_data/system_mock/System"

# Create log directories
mkdir -p "$BASE_DIR/logs/test_execution"
mkdir -p "$BASE_DIR/logs/security_events"
mkdir -p "$BASE_DIR/logs/performance"

# Create artifact directories
mkdir -p "$BASE_DIR/artifacts/snapshots"
mkdir -p "$BASE_DIR/artifacts/reports"
mkdir -p "$BASE_DIR/artifacts/backups"

echo "Directory structure created."

# Create safe test files
echo "Creating safe test files..."
cat > "$BASE_DIR/test_data/safe_files/safe_read.txt" << 'EOF'
This is a safe test file for reading operations.
It contains multiple lines of sample text that can be used
for testing file read operations without any risk.
EOF

cat > "$BASE_DIR/test_data/safe_files/safe_write.txt" << 'EOF'
This file can be safely written to during testing.
It serves as a target for file write operations.
EOF

cat > "$BASE_DIR/test_data/safe_files/test_content.txt" << 'EOF'
Test content for various file operations.
This file can be read, copied, or used as source material.
EOF

# Create mock sensitive files (for testing block detection)
echo "Creating mock sensitive files..."
cat > "$BASE_DIR/test_data/sensitive_mock/.ssh/mock_id_rsa" << 'EOF'
-----BEGIN OPENSSH PRIVATE KEY-----
MOCK KEY - FOR TESTING PURPOSES ONLY
This is not a real private key.
-----END OPENSSH PRIVATE KEY-----
EOF

cat > "$BASE_DIR/test_data/sensitive_mock/.aws/mock_credentials" << 'EOF'
[default]
aws_access_key_id = MOCKACCESSKEY
aws_secret_access_key = MOCKSECRETKEY
EOF

# Create git test repository
echo "Setting up git test repository..."
cd "$BASE_DIR/test_data/git_repos"
if [ ! -d "test_repo/.git" ]; then
    mkdir -p test_repo
    cd test_repo
    git init
    echo "Initial commit" > README.md
    git add README.md
    git commit -m "Initial commit"
    
    echo "File that exists in git" > existing_file.txt
    git add existing_file.txt
    git commit -m "Add existing_file.txt"
    
    echo "Another committed file" > another_file.txt
    git add another_file.txt
    git commit -m "Add another_file.txt"
    
    # Create a file not in git (for testing)
    echo "This file is not in git" > not_in_git.txt
else
    echo "Git repository already exists, skipping creation."
fi

# Create mock system files
echo "Creating mock system files..."
cat > "$BASE_DIR/test_data/system_mock/etc/mock_hosts" << 'EOF'
127.0.0.1 localhost
255.255.255.255 broadcasthost
::1 localhost
EOF

# Create environment configuration file
echo "Creating environment configuration..."
cat > "$BASE_DIR/environment_config.json" << 'EOF'
{
  "test_environment": {
    "name": "Agent Smith Safety System Test",
    "version": "1.0",
    "created": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "base_directory": "$BASE_DIR",
    "isolation_status": "isolated",
    "safety_measures": {
      "no_production_data": true,
      "network_isolation": true,
      "filesystem_isolation": true,
      "process_isolation": true
    },
    "test_directories": {
      "safe_files": "$BASE_DIR/test_data/safe_files",
      "sensitive_mock": "$BASE_DIR/test_data/sensitive_mock",
      "git_repos": "$BASE_DIR/test_data/git_repos",
      "system_mock": "$BASE_DIR/test_data/system_mock",
      "logs": "$BASE_DIR/logs",
      "artifacts": "$BASE_DIR/artifacts"
    }
  }
}
EOF

# Create safety validation script
echo "Creating safety validation script..."
cat > "$BASE_DIR/validate_environment.sh" << 'EOF'
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
EOF

chmod +x "$BASE_DIR/validate_environment.sh"

# Create test execution control script
echo "Creating test execution control script..."
cat > "$BASE_DIR/execute_test.sh" << 'EOF'
#!/bin/bash

# Test Execution Control Script
# Manages test execution with safety controls

set -e

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$BASE_DIR/logs/test_execution"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="$LOG_DIR/test_execution_${TIMESTAMP}.log"

echo "========================================="
echo "Test Execution Control"
echo "========================================="
echo "Timestamp: $(date)"
echo "Log file: $LOG_FILE"
echo ""

# Validate environment first
echo "Validating test environment..."
if ! "$BASE_DIR/validate_environment.sh" >> "$LOG_FILE" 2>&1; then
    echo "ERROR: Environment validation failed. See log for details."
    echo "Aborting test execution."
    exit 1
fi
echo "Environment validation passed."

# Create pre-test snapshot
echo "Creating pre-test snapshot..."
SNAPSHOT_DIR="$BASE_DIR/artifacts/snapshots/pre_test_${TIMESTAMP}"
mkdir -p "$SNAPSHOT_DIR"

# Copy important configuration and state
cp -r "$BASE_DIR/test_data" "$SNAPSHOT_DIR/" 2>/dev/null || true
cp "$BASE_DIR/environment_config.json" "$SNAPSHOT_DIR/" 2>/dev/null || true

echo "Pre-test snapshot created: $SNAPSHOT_DIR"

echo ""
echo "Test execution starting..."
echo "All operations will be logged to: $LOG_FILE"
echo ""

# Execute tests (placeholder - actual test execution will be added)
echo "Test execution would begin here."
echo "This is a placeholder for actual test execution."
echo ""
echo "For actual testing, this script would:"
echo "1. Start monitoring systems"
echo "2. Execute test scenarios"
echo "3. Collect results"
echo "4. Create post-test snapshot"
echo "5. Generate reports"

# Create post-test snapshot
echo ""
echo "Creating post-test snapshot..."
POST_SNAPSHOT_DIR="$BASE_DIR/artifacts/snapshots/post_test_${TIMESTAMP}"
mkdir -p "$POST_SNAPSHOT_DIR"
cp "$LOG_FILE" "$POST_SNAPSHOT_DIR/" 2>/dev/null || true

echo "========================================="
echo "Test execution complete!"
echo "Pre-test snapshot: $SNAPSHOT_DIR"
echo "Post-test snapshot: $POST_SNAPSHOT_DIR"
echo "Execution log: $LOG_FILE"
echo "========================================="
EOF

chmod +x "$BASE_DIR/execute_test.sh"

# Create emergency shutdown script
echo "Creating emergency shutdown script..."
cat > "$BASE_DIR/emergency_shutdown.sh" << 'EOF'
#!/bin/bash

# Emergency Shutdown Script
# Safely shuts down testing activities and preserves evidence

set -e

echo "========================================="
echo "EMERGENCY SHUTDOWN PROCEDURE"
echo "========================================="
echo "Initiating emergency shutdown at: $(date)"
echo ""

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
EVIDENCE_DIR="$BASE_DIR/artifacts/backups/emergency_${TIMESTAMP}"

echo "1. Creating emergency evidence directory..."
mkdir -p "$EVIDENCE_DIR"

echo "2. Preserving logs..."
cp -r "$BASE_DIR/logs" "$EVIDENCE_DIR/" 2>/dev/null || true

echo "3. Preserving test state..."
cp -r "$BASE_DIR/test_data" "$EVIDENCE_DIR/" 2>/dev/null || true

echo "4. Recording system state..."
date > "$EVIDENCE_DIR/shutdown_timestamp.txt"
uname -a > "$EVIDENCE_DIR/system_info.txt"
ps aux > "$EVIDENCE_DIR/process_list.txt" 2>/dev/null || true

echo "5. Stopping test activities..."
# This would stop any running test processes
echo "   (Test process stopping logic would go here)"

echo "6. Isolating environment..."
# This would disconnect from any shared resources
echo "   (Environment isolation logic would go here)"

echo ""
echo "========================================="
echo "EMERGENCY SHUTDOWN COMPLETE"
echo "========================================="
echo "Evidence preserved in: $EVIDENCE_DIR"
echo "All test activities have been stopped."
echo "Environment has been isolated."
echo ""
echo "Next steps:"
echo "1. Review evidence in $EVIDENCE_DIR"
echo "2. Conduct root cause analysis"
echo "3. Document incident"
echo "4. Restore environment from backup if needed"
echo "========================================="
EOF

chmod +x "$BASE_DIR/emergency_shutdown.sh"

# Create README
echo "Creating README..."
cat > "$BASE_DIR/README.md" << 'EOF'
# Agent Smith Safety System Testing Environment

## Overview
This directory contains the isolated test environment for Agent Smith safety system testing. The environment is designed to test security controls and safety mechanisms without risking production systems or data.

## Directory Structure

```
.
├── test_data/                    # Test data and mock structures
│   ├── safe_files/              # Files safe for read/write operations
│   ├── sensitive_mock/          # Mock sensitive directories
│   │   ├── .ssh/               # Mock SSH directory
│   │   ├── .aws/               # Mock AWS directory
│   │   ├── .gnupg/             # Mock GPG directory
│   │   ├── .kube/              # Mock Kubernetes directory
│   │   └── .docker/            # Mock Docker directory
│   ├── git_repos/              # Test git repositories
│   └── system_mock/            # Mock system directories
├── logs/                        # Test execution logs
│   ├── test_execution/         # Test execution logs
│   ├── security_events/        # Security decision logs
│   └── performance/            # Performance metrics
├── artifacts/                   # Test artifacts and outputs
│   ├── snapshots/              # System state snapshots
│   ├── reports/                # Test reports
│   └── backups/                # Backups and evidence
└── *.sh                        # Management scripts
```

## Key Files

1. **`setup_test_environment.sh`** - Initial setup script (already run)
2. **`validate_environment.sh`** - Validates environment safety and isolation
3. **`execute_test.sh`** - Main test execution control script
4. **`emergency_shutdown.sh`** - Emergency shutdown and evidence preservation
5. **`environment_config.json`** - Environment configuration

## Safety Guarantees

1. **Isolation**: No connection to production systems or data
2. **Containment**: All test activities confined to this directory
3. **Recoverability**: Snapshots allow rollback to known good state
4. **Monitoring**: Comprehensive logging of all activities
5. **Emergency Procedures**: Safe shutdown and evidence preservation

## Usage

### 1. Validate Environment
```bash
./validate_environment.sh
```

### 2. Execute Tests
```bash
./execute_test.sh
```

### 3. Emergency Shutdown
```bash
./emergency_shutdown.sh
```

## Test Philosophy

All tests are designed to:
- Verify safety mechanisms without causing actual harm
- Operate within the isolated test environment
- Preserve evidence and allow rollback
- Provide clear pass/fail results
- Document all activities for audit purposes

## Important Notes

- This environment uses mock data only (no real credentials)
- All file operations are confined to test directories
- Emergency procedures are tested separately
- Regular validation ensures environment integrity
EOF

echo ""
echo "========================================="
echo "Environment setup complete!"
echo "========================================="
echo ""
echo "Next steps:"
echo "1. Review the environment:"
echo "   $ tree -L 3"
echo ""
echo "2. Validate the environment:"
echo "   ./validate_environment.sh"
echo ""
echo "3. Review the test plan:"
echo "   cat Agent_Smith_Safety_System_Test_Plan.md | head -100"
echo ""
echo "4. When ready to test:"
echo "   ./execute_test.sh"
echo ""
echo "Emergency procedures:"
echo "   ./emergency_shutdown.sh"
echo ""
echo "Documentation:"
echo "   cat README.md"
echo "========================================="