#!/bin/bash
# Example: Create a prime number checker with tests
# This demonstrates the full TDD workflow

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"

echo "Running prime checker example..."
echo ""

"$PARENT_DIR/scripts/orchestrate.sh" \
    "Create a Python function to check if a number is prime, with comprehensive tests" \
    2
