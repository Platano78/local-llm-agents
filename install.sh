#!/bin/bash
# Local LLM Agents - Installation Script
# Sets up the environment and validates dependencies

set -e

echo "========================================"
echo "  Local LLM Agents - Installation"
echo "========================================"
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check dependencies
echo "Checking dependencies..."

check_dep() {
    if command -v "$1" &> /dev/null; then
        echo -e "  ${GREEN}✓${NC} $1 found"
        return 0
    else
        echo -e "  ${RED}✗${NC} $1 not found"
        return 1
    fi
}

MISSING=0
check_dep "bash" || MISSING=1
check_dep "curl" || MISSING=1
check_dep "jq" || MISSING=1

if [ "$MISSING" -eq 1 ]; then
    echo ""
    echo -e "${RED}Missing dependencies. Please install them:${NC}"
    echo "  Ubuntu/Debian: sudo apt install jq curl"
    echo "  macOS: brew install jq curl"
    echo "  Arch: sudo pacman -S jq curl"
    exit 1
fi

echo ""
echo "Setting up directories..."

# Ensure scripts are executable
chmod +x "$SCRIPT_DIR/scripts/"*.sh
echo -e "  ${GREEN}✓${NC} Scripts made executable"

# Set default config
CONFIG_FILE="$SCRIPT_DIR/.env"
if [ ! -f "$CONFIG_FILE" ]; then
    cat > "$CONFIG_FILE" << 'EOF'
# Local LLM Agents Configuration
# Copy this to .env and customize as needed

# LLM Server Settings
WORKER_PORT=8081
ORCHESTRATOR_PORT=8085

# Agent Pool Location
AGENT_POOL="./agents"

# Timeouts (seconds)
LLM_TIMEOUT=45
TOTAL_TIMEOUT=180

# Working directory for outputs (uses /tmp by default)
# WORK_DIR=/path/to/custom/workdir
EOF
    echo -e "  ${GREEN}✓${NC} Default config created (.env)"
else
    echo -e "  ${YELLOW}→${NC} Config file already exists (.env)"
fi

echo ""
echo "========================================"
echo -e "${GREEN}Installation complete!${NC}"
echo "========================================"
echo ""
echo "Next steps:"
echo "  1. Start your local LLM server on port 8081"
echo "  2. Run a test: ./scripts/orchestrate.sh \"Create a hello world function\" 2"
echo ""
echo "Configuration:"
echo "  Edit .env to customize settings"
echo ""
echo "Documentation:"
echo "  See README.md for full usage instructions"
echo ""
