#!/bin/bash
# Example: Create a Calculator class
# This demonstrates a more complex multi-file task

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"

echo "Running calculator example..."
echo ""

"$PARENT_DIR/scripts/orchestrate.sh" \
    "Create a Python Calculator class with add, subtract, multiply, and divide methods, plus unit tests" \
    2
