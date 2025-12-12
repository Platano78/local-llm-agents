#!/bin/bash
# Agent Mapper
# Takes decomposed tasks JSON and maps them to available worker slots
# Handles slot allocation and creates execution batches
#
# Usage: agent-mapper.sh <decomposed_json_file> <available_slots>
# Output: JSON with slot assignments to stdout

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DECOMPOSED_FILE="$1"
AVAILABLE_SLOTS="${2:-6}"

# Validate input
if [ ! -f "$DECOMPOSED_FILE" ]; then
    echo '{"error": "Decomposed JSON file not found", "batches": []}' >&2
    exit 1
fi

# Read and validate JSON
DECOMPOSED=$(cat "$DECOMPOSED_FILE")
if ! echo "$DECOMPOSED" | jq -e '.' >/dev/null 2>&1; then
    echo '{"error": "Invalid JSON in decomposed file", "batches": []}' >&2
    exit 1
fi

# Check for error in decomposed output
if echo "$DECOMPOSED" | jq -e '.error' >/dev/null 2>&1; then
    ERROR=$(echo "$DECOMPOSED" | jq -r '.error')
    echo "{\"error\": \"Decomposition failed: $ERROR\", \"batches\": []}" >&2
    exit 1
fi

# Extract parallel groups
PARALLEL_GROUPS=$(echo "$DECOMPOSED" | jq -r '.parallel_groups // []')
NUM_GROUPS=$(echo "$PARALLEL_GROUPS" | jq 'length')

if [ "$NUM_GROUPS" -eq 0 ]; then
    echo '{"error": "No parallel groups found in decomposition", "batches": []}' >&2
    exit 1
fi

# Dynamic agent selection - uses LLM to match tasks to best agent
# Falls back to phase-based defaults if LLM unavailable
SELECTOR_SCRIPT="$SCRIPT_DIR/agent-selector.sh"

# Select agent dynamically using LLM or fall back to defaults
select_agent() {
    local task="$1"
    local phase="$2"
    
    # Try dynamic selection if script exists
    if [ -x "$SELECTOR_SCRIPT" ]; then
        local selected=$("$SELECTOR_SCRIPT" "$task" "$phase" 2>/dev/null)
        if [ -n "$selected" ]; then
            echo "$selected"
            return 0
        fi
    fi
    
    # Fall back to phase-based defaults
    case "$phase" in
        "RED")      echo "test-writer-agent" ;;
        "GREEN")    echo "code-generator-agent" ;;
        "REFACTOR") echo "code-optimization-agent" ;;
        "ANALYZE"|"REVIEW") echo "code-review-automation-agent" ;;
        *)          echo "code-generator-agent" ;;
    esac
}

# Process each task through dynamic agent selection
# First, create base structure with jq, then update agents via bash loop

# Create temporary file for building output
TMP_OUTPUT=$(mktemp)

# Initialize output structure
echo '{"batches": [], "total_groups": '$NUM_GROUPS', "available_slots": '$AVAILABLE_SLOTS'}' > "$TMP_OUTPUT"

TOTAL_TASKS=0

# Process each group
for group_idx in $(seq 0 $((NUM_GROUPS - 1))); do
    GROUP=$(echo "$PARALLEL_GROUPS" | jq ".[$group_idx]")
    GROUP_NUM=$(echo "$GROUP" | jq -r '.group')
    GROUP_DESC=$(echo "$GROUP" | jq -r '.description // .name // "unnamed"')
    TASKS=$(echo "$GROUP" | jq -r '.tasks')
    NUM_TASKS=$(echo "$TASKS" | jq 'length')
    
    # Build tasks array with dynamic agent selection
    MAPPED_TASKS='[]'
    
    for task_idx in $(seq 0 $((NUM_TASKS - 1))); do
        TASK=$(echo "$TASKS" | jq ".[$task_idx]")
        TASK_ID=$(echo "$TASK" | jq -r '.id')
        PHASE=$(echo "$TASK" | jq -r '.phase')
        TASK_DESC=$(echo "$TASK" | jq -r '.task')
        ORIG_AGENT=$(echo "$TASK" | jq -r '.agent // "unknown"')
        FILES=$(echo "$TASK" | jq -c '.files // []')
        SLOT=$(( (task_idx % AVAILABLE_SLOTS) + 1 ))
        
        # Dynamic agent selection!
        SELECTED_AGENT=$(select_agent "$TASK_DESC" "$PHASE")
        
        # Add to mapped tasks
        MAPPED_TASKS=$(echo "$MAPPED_TASKS" | jq \
            --arg slot "$SLOT" \
            --arg task_id "$TASK_ID" \
            --arg phase "$PHASE" \
            --arg orig_agent "$ORIG_AGENT" \
            --arg agent "$SELECTED_AGENT" \
            --arg task "$TASK_DESC" \
            --argjson files "$FILES" \
            '. + [{
                "slot": ($slot | tonumber),
                "task_id": $task_id,
                "phase": $phase,
                "original_agent": $orig_agent,
                "agent": $agent,
                "task": $task,
                "files": $files
            }]')
        
        TOTAL_TASKS=$((TOTAL_TASKS + 1))
    done
    
    # Calculate parallelism
    PARALLELISM=$NUM_TASKS
    [ $PARALLELISM -gt $AVAILABLE_SLOTS ] && PARALLELISM=$AVAILABLE_SLOTS
    
    # Add batch to output
    BATCH=$(jq -n \
        --argjson group "$GROUP_NUM" \
        --arg desc "$GROUP_DESC" \
        --argjson tasks "$MAPPED_TASKS" \
        --argjson parallelism "$PARALLELISM" \
        '{
            "group": $group,
            "description": $desc,
            "tasks": $tasks,
            "parallelism": $parallelism
        }')
    
    # Append batch
    jq --argjson batch "$BATCH" '.batches += [$batch]' "$TMP_OUTPUT" > "${TMP_OUTPUT}.new"
    mv "${TMP_OUTPUT}.new" "$TMP_OUTPUT"
done

# Add execution summary
jq --argjson total "$TOTAL_TASKS" \
   --argjson batches "$NUM_GROUPS" \
   --argjson max_par "$AVAILABLE_SLOTS" \
   '. + {"execution_summary": {"total_tasks": $total, "total_batches": $batches, "max_parallelism": $max_par}}' \
   "$TMP_OUTPUT"

rm -f "$TMP_OUTPUT"
