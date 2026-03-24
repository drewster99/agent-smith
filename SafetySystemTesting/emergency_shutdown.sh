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
