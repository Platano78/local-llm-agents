#!/bin/bash
# TDD Task Decomposer
# Routes decomposition to GPU worker or GPU orchestrator based on DECOMP_TARGET
#
# Routing logic (set by health-check.sh):
# - DECOMP_TARGET=orchestrator: GPU orchestrator detected (>30 t/s) - use it
# - DECOMP_TARGET=worker: CPU orchestrator or no orchestrator - use GPU worker
#
# Handles reasoning models that output:
#   - reasoning_content (chain-of-thought)
#   - content (final answer)
# When content is empty, the answer may be at the end of reasoning_content
#
# Usage: tdd-decomposer.sh <task> <slots>
# Output: JSON task decomposition to stdout

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASK="$1"
SLOTS="${2:-6}"
ORCHESTRATOR_PORT="${ORCHESTRATOR_PORT:-8083}"
WORKER_PORT="${WORKER_PORT:-8081}"
DECOMP_TARGET="${DECOMP_TARGET:-worker}"  # Set by orchestrate.sh based on health check
TIMEOUT=60
MAX_RETRIES=2  # Qwen3 recommendation: validation retries

# Load decomposition prompt
DECOMPOSE_PROMPT=$(cat "$SCRIPT_DIR/prompts/decompose.txt")

# Read model IDs from status file (set by health-check.sh)
STATUS_FILE="${STATUS_FILE:-/tmp/local-agents-status.json}"
if [ -f "$STATUS_FILE" ]; then
    WORKER_MODEL_ID=$(jq -r '.worker.model_id // ""' "$STATUS_FILE" 2>/dev/null)
    ORCH_MODEL_ID=$(jq -r '.orchestrator.model_id // ""' "$STATUS_FILE" 2>/dev/null)
fi

# Determine which server to use based on routing decision
PORT=""
MODEL=""

if [ "$DECOMP_TARGET" = "orchestrator" ]; then
    # GPU orchestrator is fast enough for decomposition
    if curl -s --max-time 2 "http://localhost:$ORCHESTRATOR_PORT/health" 2>/dev/null | grep -q "ok"; then
        PORT=$ORCHESTRATOR_PORT
        MODEL="${ORCH_MODEL_ID:-orchestrator}"  # Use actual model ID or fallback
        MAX_TOKENS=4096
        echo "[ROUTING] Using GPU orchestrator for decomposition (model: $MODEL)" >&2
    else
        # Fallback to worker
        PORT=$WORKER_PORT
        MODEL="${WORKER_MODEL_ID:-worker}"  # Use actual model ID or fallback
        MAX_TOKENS=4096
        echo "[ROUTING] GPU orchestrator unavailable, falling back to worker (model: $MODEL)" >&2
    fi
else
    # CPU orchestrator is too slow - use GPU worker
    if curl -s --max-time 2 "http://localhost:$WORKER_PORT/health" 2>/dev/null | grep -q "ok"; then
        PORT=$WORKER_PORT
        MODEL="${WORKER_MODEL_ID:-worker}"  # Use actual model ID or fallback
        MAX_TOKENS=4096
        echo "[ROUTING] Using GPU worker for decomposition (model: $MODEL)" >&2
    elif curl -s --max-time 2 "http://localhost:$ORCHESTRATOR_PORT/health" 2>/dev/null | grep -q "ok"; then
        PORT=$ORCHESTRATOR_PORT
        MODEL="${ORCH_MODEL_ID:-orchestrator}"  # Use actual model ID or fallback
        MAX_TOKENS=1500
        echo "[ROUTING] Worker unavailable, using orchestrator (model: $MODEL)" >&2
    else
        echo '{"error": "No LLM server available", "parallel_groups": []}' >&2
        exit 1
    fi
fi

# Build user message - Qwen3 recommendation: explicit JSON constraint
USER_MSG="RESPOND ONLY WITH VALID JSON. No markdown, no explanation, just the JSON object.

Task: $TASK

Available worker slots: $SLOTS

Decompose this task into atomic TDD tasks."

# Build JSON payload and write to temp file (avoids heredoc issues with large payloads)
TMPFILE=$(mktemp /tmp/tdd-decomposer.XXXXXX.json)
trap "rm -f '$TMPFILE'" EXIT

jq -n \
    --arg model "$MODEL" \
    --arg system "$DECOMPOSE_PROMPT" \
    --arg user "$USER_MSG" \
    --argjson max_tokens "$MAX_TOKENS" \
    '{
        model: $model,
        messages: [
            {role: "system", content: $system},
            {role: "user", content: $user}
        ],
        max_tokens: $max_tokens,
        temperature: 0.3
    }' > "$TMPFILE"

# Call LLM with increased tokens for reasoning models
RESPONSE=$(curl -s --max-time "$TIMEOUT" "http://localhost:$PORT/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "@$TMPFILE")

# Check for curl error
if [ $? -ne 0 ] || [ -z "$RESPONSE" ]; then
    echo '{"error": "Failed to connect to LLM server", "parallel_groups": []}' >&2
    exit 1
fi

# Extract content - handle both standard and reasoning model formats
# Priority: content > reasoning_content (for reasoning models where content may be empty)
CONTENT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // empty')
REASONING=$(echo "$RESPONSE" | jq -r '.choices[0].message.reasoning_content // empty')

# If content is empty but reasoning exists, extract JSON from reasoning
if [ -z "$CONTENT" ] || [ "$CONTENT" = "null" ]; then
    if [ -n "$REASONING" ] && [ "$REASONING" != "null" ]; then
        # Try to extract JSON from reasoning_content
        # Look for the last JSON object in the reasoning
        CONTENT=$(echo "$REASONING" | grep -oE '\{[^{}]*"parallel_groups"[^{}]*\}' | tail -1)

        # If that didn't work, try to find any JSON block
        if [ -z "$CONTENT" ]; then
            CONTENT=$(echo "$REASONING" | sed -n '/^{/,/^}/p' | head -50)
        fi

        # If still empty, use the full reasoning
        if [ -z "$CONTENT" ]; then
            CONTENT="$REASONING"
        fi
    fi
fi

# Still no content - return error
if [ -z "$CONTENT" ] || [ "$CONTENT" = "null" ]; then
    ERROR=$(echo "$RESPONSE" | jq -r '.error.message // "Empty response from LLM"')
    echo "{\"error\": \"$ERROR\", \"parallel_groups\": [], \"raw_response\": $(echo "$RESPONSE" | jq -c '.')}" >&2
    exit 1
fi

# Try to extract JSON from response (handle markdown code blocks)
JSON_CONTENT=""

# Try ```json blocks first
if echo "$CONTENT" | grep -q '```json'; then
    JSON_CONTENT=$(echo "$CONTENT" | sed -n '/```json/,/```/p' | sed '1d;$d')
fi

# Try ``` blocks
if [ -z "$JSON_CONTENT" ] && echo "$CONTENT" | grep -q '```'; then
    JSON_CONTENT=$(echo "$CONTENT" | sed -n '/```/,/```/p' | sed '1d;$d')
fi

# Try the whole content as-is (most likely case with JSON-first prompt)
if [ -z "$JSON_CONTENT" ]; then
    JSON_CONTENT="$CONTENT"
fi

# If content starts with {, it's likely raw JSON - clean any trailing text
if [[ "$JSON_CONTENT" == "{"* ]]; then
    # Use jq to extract valid JSON even if there's trailing garbage
    JSON_CONTENT=$(echo "$JSON_CONTENT" | jq -c '.' 2>/dev/null || echo "$JSON_CONTENT")
fi

# JSON repair function for common LLM malformations
repair_json() {
    local json="$1"
    
    # Fix 1: Remove stray quotes before closing brackets like }"] -> }]
    json=$(echo "$json" | sed 's/}"\]/}]/g')
    
    # Fix 2: Remove trailing newlines from strings that break JSON
    json=$(echo "$json" | tr '\n' ' ')
    
    # Fix 3: Ensure proper closing if truncated
    # Count open vs close braces/brackets
    local open_braces=$(echo "$json" | tr -cd '{' | wc -c)
    local close_braces=$(echo "$json" | tr -cd '}' | wc -c)
    local open_brackets=$(echo "$json" | tr -cd '[' | wc -c)
    local close_brackets=$(echo "$json" | tr -cd ']' | wc -c)
    
    # Add missing closing brackets/braces
    while [ "$close_brackets" -lt "$open_brackets" ]; do
        json="${json}]"
        close_brackets=$((close_brackets + 1))
    done
    while [ "$close_braces" -lt "$open_braces" ]; do
        json="${json}}"
        close_braces=$((close_braces + 1))
    done
    
    echo "$json"
}

# Validate and output JSON
if echo "$JSON_CONTENT" | jq -e '.' >/dev/null 2>&1; then
    # Valid JSON - output it
    echo "$JSON_CONTENT" | jq -c '.'
else
    # Try to repair common JSON issues
    REPAIRED=$(repair_json "$JSON_CONTENT")
    if echo "$REPAIRED" | jq -e '.' >/dev/null 2>&1; then
        echo "[JSON-REPAIR] Fixed malformed JSON" >&2
        echo "$REPAIRED" | jq -c '.'
    else
        # Invalid JSON - wrap in error with raw content for debugging
        echo "{\"error\": \"Failed to parse JSON from LLM response\", \"parallel_groups\": [], \"raw_content\": $(echo "$CONTENT" | jq -Rs .)}" >&2
        exit 1
    fi
fi
