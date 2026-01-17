#!/bin/bash
# Dynamic Agent Selector
# Uses LLM to match tasks to the best agent from the pool
# Falls back to phase-based defaults if LLM unavailable
#
# Usage: agent-selector.sh "<task_description>" "<phase>" [port]
# Output: Agent name to stdout

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_POOL="${AGENT_POOL:-${LOCAL_AGENTS_HOME:?LOCAL_AGENTS_HOME must be set}/agents}"
WORKER_PORT="${3:-8081}"

TASK_DESC="$1"
PHASE="$2"

# Validate AGENT_POOL directory exists
if [ ! -d "$AGENT_POOL" ]; then
    echo "Error: AGENT_POOL directory not found: $AGENT_POOL" >&2
    exit 1
fi

# Phase-based defaults (fallback)
get_default_agent() {
    local phase="$1"
    case "$phase" in
        "RED")      echo "test-writer-agent" ;;
        "GREEN")    echo "code-generator-agent" ;;
        "REFACTOR") echo "code-optimization-agent" ;;
        "ANALYZE"|"REVIEW") echo "code-review-automation-agent" ;;
        "SECURITY") echo "security-compliance-agent" ;;
        "DOCS")     echo "documentation-specialist-agent" ;;
        *)          echo "code-generator-agent" ;;
    esac
}

# Build agent catalog (name + first line of description)
build_agent_catalog() {
    local catalog=""
    for agent_file in "$AGENT_POOL"/*.md; do
        [ -f "$agent_file" ] || continue
        # Skip Zone.Identifier files
        [[ "$agent_file" == *":Zone.Identifier" ]] && continue

        local name=$(basename "$agent_file" .md)
        # Get first non-empty, non-header line as description (with fallback)
        local desc=$(grep -m1 -v '^#' "$agent_file" 2>/dev/null | grep -v '^$' | head -c 100)
        [ -z "$desc" ] && desc="No description"
        catalog+="- $name: $desc"$'\n'
    done
    printf '%s' "$catalog"
}

# Query LLM to select best agent
select_with_llm() {
    local task="$1"
    local phase="$2"
    local catalog="$3"
    
    local prompt="Select the BEST agent for this task. Reply with ONLY the agent name, nothing else.

Task: $task
Phase: $phase

Available agents:
$catalog

Agent name:"

    # Build JSON payload
    local payload=$(jq -n \
        --arg prompt "$prompt" \
        '{
            "model": "default",
            "messages": [{"role": "user", "content": $prompt}],
            "max_tokens": 50,
            "temperature": 0.1
        }')
    
    # Query local LLM (capture exit status properly)
    local response
    response=$(curl -s --max-time 5 \
        -X POST "http://127.0.0.1:$WORKER_PORT/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)
    local curl_exit=$?

    if [ $curl_exit -eq 0 ] && [ -n "$response" ]; then
        # Extract agent name from response (consolidated sed)
        local agent=$(printf '%s' "$response" | jq -r '.choices[0].message.content // empty' 2>/dev/null | \
            tr -d '\n' | \
            sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | \
            grep -oE '^[a-z][a-z0-9_-]*(-agent|_agent)?')

        # Validate agent exists
        if [ -n "$agent" ]; then
            # Normalize name (add -agent if missing)
            [[ "$agent" =~ -agent$|_agent$ ]] || agent="${agent}-agent"

            # Check if agent file exists
            if [ -f "$AGENT_POOL/${agent}.md" ]; then
                printf '%s\n' "$agent"
                return 0
            fi
            # Try with underscores
            local underscore_agent="${agent//-/_}"
            if [ -f "$AGENT_POOL/${underscore_agent}.md" ]; then
                printf '%s\n' "$underscore_agent"
                return 0
            fi
        fi
    fi

    return 1
}

# Check if task requires a specialized agent that doesn't exist
should_generate_agent() {
    local task="$1"
    # Note: phase parameter removed (was unused)

    # Keywords that suggest specialized domain needs
    local specialized_keywords="blockchain|kubernetes|terraform|ansible|graphql|grpc|websocket|mqtt|kafka|elasticsearch|redis|mongodb|postgresql|mysql|docker|nginx|aws|azure|gcp|ci/cd|devops|mlops|data pipeline|etl|scraping|crawling|regex|parsing|compiler|interpreter|dsl"

    # Use printf to safely handle special characters in task
    if printf '%s' "$task" | grep -qiE "$specialized_keywords"; then
        return 0  # Should consider generating
    fi
    return 1
}

# Generate a new agent if needed
generate_if_needed() {
    local task="$1"
    local phase="$2"
    local generator_script="$SCRIPT_DIR/agent-generator.sh"

    if [ -x "$generator_script" ]; then
        # Generate returns the path to new agent file
        local new_agent_path
        new_agent_path=$("$generator_script" "$task" "$phase" 2>/dev/null)

        if [ -n "$new_agent_path" ] && [ -f "$new_agent_path" ]; then
            # Extract agent name from path
            local agent_name=$(basename "$new_agent_path" .md)
            printf '[GENERATED] Created new agent: %s\n' "$agent_name" >&2
            printf '%s\n' "$agent_name"
            return 0
        fi
    fi
    return 1
}

# Main selection logic
main() {
    # If no task, return default
    if [ -z "$TASK_DESC" ]; then
        get_default_agent "$PHASE"
        return
    fi
    
    # Build catalog
    local catalog=$(build_agent_catalog)
    
    # Try LLM selection first
    local selected=$(select_with_llm "$TASK_DESC" "$PHASE" "$catalog")
    
    if [ -n "$selected" ]; then
        echo "$selected"
        return
    fi
    
    # Check if this task needs a specialized agent we don't have
    if should_generate_agent "$TASK_DESC"; then
        local generated=$(generate_if_needed "$TASK_DESC" "$PHASE")
        if [ -n "$generated" ]; then
            printf '%s\n' "$generated"
            return
        fi
    fi
    
    # Fall back to phase-based default
    get_default_agent "$PHASE"
}

main
