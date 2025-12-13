#!/bin/bash
# Local LLM Agents - Installation Script
# Sets up scripts, slash command, and validates dependencies

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

# Create Claude Code directories
CLAUDE_SCRIPTS_PARENT="$HOME/.claude/scripts"
CLAUDE_SCRIPTS="$CLAUDE_SCRIPTS_PARENT/local-agents"
CLAUDE_COMMANDS="$HOME/.claude/commands"
CLAUDE_AGENTS="$HOME/.claude/agents"

mkdir -p "$CLAUDE_SCRIPTS_PARENT"
mkdir -p "$CLAUDE_COMMANDS"
mkdir -p "$CLAUDE_AGENTS"
echo -e "  ${GREEN}✓${NC} Claude Code directories created"

# Install scripts via symlink (keeps repo and active scripts in sync)
if [ -L "$CLAUDE_SCRIPTS" ]; then
    # Already a symlink - update it
    rm "$CLAUDE_SCRIPTS"
    ln -s "$SCRIPT_DIR/scripts" "$CLAUDE_SCRIPTS"
    echo -e "  ${GREEN}✓${NC} Scripts symlink updated"
elif [ -d "$CLAUDE_SCRIPTS" ]; then
    # Existing directory - ask user
    echo -e "  ${YELLOW}!${NC} Existing scripts directory found at $CLAUDE_SCRIPTS"
    read -p "    Replace with symlink to repo? (recommended) [y/N]: " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$CLAUDE_SCRIPTS"
        ln -s "$SCRIPT_DIR/scripts" "$CLAUDE_SCRIPTS"
        echo -e "  ${GREEN}✓${NC} Scripts symlink created (replaced directory)"
    else
        # Fall back to copy mode
        cp "$SCRIPT_DIR/scripts/"*.sh "$CLAUDE_SCRIPTS/"
        chmod +x "$CLAUDE_SCRIPTS/"*.sh
        mkdir -p "$CLAUDE_SCRIPTS/prompts"
        cp "$SCRIPT_DIR/scripts/prompts/"*.txt "$CLAUDE_SCRIPTS/prompts/"
        echo -e "  ${YELLOW}→${NC} Scripts copied (not symlinked)"
    fi
else
    # Fresh install - create symlink
    ln -s "$SCRIPT_DIR/scripts" "$CLAUDE_SCRIPTS"
    echo -e "  ${GREEN}✓${NC} Scripts symlink created: ~/.claude/scripts/local-agents → repo/scripts"
fi

echo -e "  ${GREEN}✓${NC} Prompts included (in scripts/prompts/)"

# Copy agents (only if not already present)
for agent in "$SCRIPT_DIR/agents/"*.md; do
    agent_name=$(basename "$agent")
    if [ ! -f "$CLAUDE_AGENTS/$agent_name" ]; then
        cp "$agent" "$CLAUDE_AGENTS/"
        echo -e "  ${GREEN}✓${NC} Agent installed: $agent_name"
    else
        echo -e "  ${YELLOW}→${NC} Agent exists, skipping: $agent_name"
    fi
done

# Install slash command
cp "$SCRIPT_DIR/commands/local-agents.md" "$CLAUDE_COMMANDS/"
echo -e "  ${GREEN}✓${NC} Slash command installed: /local-agents"

# Create config file if not exists
CONFIG_FILE="$CLAUDE_SCRIPTS/.env"
if [ ! -f "$CONFIG_FILE" ]; then
    cat > "$CONFIG_FILE" << 'EOF'
# Local LLM Agents Configuration

# LLM Server Settings
WORKER_PORT=8081
ORCHESTRATOR_PORT=8085

# Agent Pool Location
AGENT_POOL="$HOME/.claude/agents"

# Timeouts (seconds)
LLM_TIMEOUT=45
TOTAL_TIMEOUT=180
EOF
    echo -e "  ${GREEN}✓${NC} Config created: ~/.claude/scripts/local-agents/.env"
else
    echo -e "  ${YELLOW}→${NC} Config exists, skipping"
fi

echo ""
echo "========================================"
echo -e "${GREEN}Installation complete!${NC}"
echo "========================================"
echo ""
echo "Installed:"
echo "  • Scripts: ~/.claude/scripts/local-agents/ (symlink to repo)"
echo "  • Command: /local-agents <task>"
echo "  • Agents:  ~/.claude/agents/"
echo ""
echo "Symlink benefits:"
echo "  • Edit repo scripts → changes apply immediately"
echo "  • Git tracks all modifications automatically"
echo "  • No manual syncing needed"
echo ""
echo "Next steps:"
echo "  1. Start your local LLM server on port 8081"
echo "  2. In Claude Code, use: /local-agents \"Create a hello world function\""
echo ""
echo "Documentation:"
echo "  See README.md for full usage instructions"
echo ""
