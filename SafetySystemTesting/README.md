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
