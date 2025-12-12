#!/bin/bash
# Dynamic Agent Generator
# Creates new agents on-demand when no existing agent fits the task
# Uses LLM to generate agent definition based on task requirements
# Saves to agent pool for future use
#
# Usage: agent-generator.sh "<task_description>" "<suggested_name>" [port]
# Output: Path to new agent file, or empty if generation failed

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_POOL="${AGENT_POOL:-$LOCAL_AGENTS_HOME/agents}"
WORKER_PORT="${3:-8081}"

TASK_DESC="$1"
SUGGESTED_NAME="$2"

# Validate inputs
if [ -z "$TASK_DESC" ]; then
    echo "" >&2
    exit 1
fi

# Generate agent name if not provided
if [ -z "$SUGGESTED_NAME" ]; then
    # Use LLM to suggest a name
    NAME_PROMPT="Suggest a short, descriptive agent name for this task. Use lowercase with hyphens. End with -agent. Reply with ONLY the name, nothing else.\n\nTask: $TASK_DESC\n\nAgent name:"
    
    NAME_PAYLOAD=$(jq -n --arg prompt "$NAME_PROMPT" '{
        "model": "default",
        "messages": [{"role": "user", "content": $prompt}],
        "max_tokens": 30,
        "temperature": 0.3
    }')
    
    SUGGESTED_NAME=$(curl -s --max-time 10 \
        -X POST "http://127.0.0.1:$WORKER_PORT/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "$NAME_PAYLOAD" 2>/dev/null | \
        jq -r '.choices[0].message.content // empty' | \
        tr -d '\n' | tr ' ' '-' | tr '[:upper:]' '[:lower:]' | \
        sed 's/[^a-z0-9-]//g')
    
    # Ensure it ends with -agent
    [[ "$SUGGESTED_NAME" != *-agent ]] && SUGGESTED_NAME="${SUGGESTED_NAME}-agent"
fi

# Check if agent already exists
if [ -f "$AGENT_POOL/${SUGGESTED_NAME}.md" ]; then
    echo "$AGENT_POOL/${SUGGESTED_NAME}.md"
    exit 0
fi

# Read a few existing agents as examples
EXAMPLE_AGENTS=""
for example in "code-generator-agent" "test-writer-agent" "security-compliance-agent"; do
    if [ -f "$AGENT_POOL/${example}.md" ]; then
        EXAMPLE_AGENTS+="\n---\nExample: ${example}.md\n"
        EXAMPLE_AGENTS+=$(head -50 "$AGENT_POOL/${example}.md")
    fi
done

# Generate agent definition using LLM
GEN_PROMPT="Create a new Claude Code agent definition for the following task. Follow the example format exactly.

Task requiring new agent: $TASK_DESC
Agent name: $SUGGESTED_NAME

Existing agent examples for format reference:$EXAMPLE_AGENTS

Generate a complete agent definition markdown file with:
1. # Agent Name header
2. Clear description of capabilities
3. ## Tools section listing relevant tools
4. ## Personality section with communication style
5. ## Instructions section with step-by-step guidance

Output ONLY the markdown content, no explanations:"

GEN_PAYLOAD=$(jq -n --arg prompt "$GEN_PROMPT" '{
    "model": "default",
    "messages": [{"role": "user", "content": $prompt}],
    "max_tokens": 2000,
    "temperature": 0.4
}')

AGENT_CONTENT=$(curl -s --max-time 30 \
    -X POST "http://127.0.0.1:$WORKER_PORT/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "$GEN_PAYLOAD" 2>/dev/null | \
    jq -r '.choices[0].message.content // empty')

# Validate we got content
if [ -z "$AGENT_CONTENT" ] || [ ${#AGENT_CONTENT} -lt 100 ]; then
    echo "Failed to generate agent content" >&2
    echo ""
    exit 1
fi

# Add metadata header
AGENT_FILE="$AGENT_POOL/${SUGGESTED_NAME}.md"
cat > "$AGENT_FILE" << EOF
<!-- Auto-generated agent: $(date -Iseconds) -->
<!-- Task: $TASK_DESC -->

$AGENT_CONTENT
EOF

echo "$AGENT_FILE"
