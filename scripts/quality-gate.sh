#!/bin/bash
# Quality Gate
# Reviews execution results via Orchestrator and provides quality assessment
#
# Usage: quality-gate.sh <execution_results_file>
# Output: JSON quality assessment to stdout

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_FILE="$1"
ORCHESTRATOR_PORT="${ORCHESTRATOR_PORT:-8085}"
WORKER_PORT="${WORKER_PORT:-8081}"
TIMEOUT=60

# Validate input
if [ ! -f "$RESULTS_FILE" ]; then
    echo '{"error": "Execution results file not found", "status": "fail", "overall_score": 0}' >&2
    exit 1
fi

# Read results
RESULTS=$(cat "$RESULTS_FILE")
if ! echo "$RESULTS" | jq -e '.' >/dev/null 2>&1; then
    echo '{"error": "Invalid JSON in results file", "status": "fail", "overall_score": 0}' >&2
    exit 1
fi

# Load quality review prompt
QUALITY_PROMPT=$(cat "$SCRIPT_DIR/prompts/quality-review.txt")

# Determine which server to use (prefer orchestrator for review tasks)
PORT=""
MODEL=""

if curl -s --max-time 2 "http://localhost:$ORCHESTRATOR_PORT/health" | grep -q "ok"; then
    PORT=$ORCHESTRATOR_PORT
    MODEL="orchestrator"
    MAX_TOKENS=1024
elif curl -s --max-time 2 "http://localhost:$WORKER_PORT/health" | grep -q "ok"; then
    PORT=$WORKER_PORT
    MODEL="worker"
    MAX_TOKENS=2048
else
    echo '{"error": "No LLM server available", "status": "fail", "overall_score": 0}' >&2
    exit 1
fi

# Prepare results summary for review (truncate if too long)
RESULTS_SUMMARY=$(echo "$RESULTS" | jq -c '{
    status: .status,
    total_success: .total_success,
    total_failed: .total_failed,
    batches: [.batches[] | {
        group: .group,
        description: .description,
        success: .success,
        failed: .failed,
        results: [.results[] | {
            task_id: .task_id,
            agent: .agent,
            phase: .phase,
            task: .task,
            status: .status,
            result: (.result | if length > 1000 then (.[0:1000] + "... [truncated]") else . end)
        }]
    }]
}')

USER_MSG="Review the following execution results:

$RESULTS_SUMMARY

Provide a quality assessment in JSON format."

# Build JSON payload and write to temp file
TMPFILE=$(mktemp /tmp/quality-gate.XXXXXX.json)
trap "rm -f '$TMPFILE'" EXIT

jq -n \
    --arg model "$MODEL" \
    --arg system "$QUALITY_PROMPT" \
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

# Call LLM
RESPONSE=$(curl -s --max-time "$TIMEOUT" "http://localhost:$PORT/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "@$TMPFILE")

# Check for curl error
if [ $? -ne 0 ] || [ -z "$RESPONSE" ]; then
    echo '{"error": "Failed to connect to LLM server", "status": "fail", "overall_score": 0}' >&2
    exit 1
fi

# Extract content - handle both standard and reasoning model formats
CONTENT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // empty')
REASONING=$(echo "$RESPONSE" | jq -r '.choices[0].message.reasoning_content // empty')

# If content is empty but reasoning exists, extract JSON from reasoning
if [ -z "$CONTENT" ] || [ "$CONTENT" = "null" ]; then
    if [ -n "$REASONING" ] && [ "$REASONING" != "null" ]; then
        # Try to extract JSON from reasoning_content
        CONTENT=$(echo "$REASONING" | grep -oE '\{[^{}]*"overall_score"[^{}]*\}' | tail -1)

        if [ -z "$CONTENT" ]; then
            CONTENT=$(echo "$REASONING" | sed -n '/^{/,/^}/p' | head -50)
        fi

        if [ -z "$CONTENT" ]; then
            CONTENT="$REASONING"
        fi
    fi
fi

# Still no content - return error
if [ -z "$CONTENT" ] || [ "$CONTENT" = "null" ]; then
    ERROR=$(echo "$RESPONSE" | jq -r '.error.message // "Empty response from LLM"')
    echo "{\"error\": \"$ERROR\", \"status\": \"fail\", \"overall_score\": 0}" >&2
    exit 1
fi

# Try to extract JSON from response
JSON_CONTENT=""

# First, try direct jq parsing of the whole content (most reliable)
if echo "$CONTENT" | jq -e '.' >/dev/null 2>&1; then
    JSON_CONTENT="$CONTENT"
fi

# Try ```json blocks
if [ -z "$JSON_CONTENT" ] && echo "$CONTENT" | grep -q '```json'; then
    JSON_CONTENT=$(echo "$CONTENT" | sed -n '/```json/,/```/p' | sed '1d;$d')
fi

# Try ``` blocks
if [ -z "$JSON_CONTENT" ] && echo "$CONTENT" | grep -q '```'; then
    JSON_CONTENT=$(echo "$CONTENT" | sed -n '/```/,/```/p' | sed '1d;$d')
fi

# Try to find JSON by looking for opening brace to closing brace
if [ -z "$JSON_CONTENT" ] || ! echo "$JSON_CONTENT" | jq -e '.' >/dev/null 2>&1; then
    # Extract from first { to last }
    EXTRACTED=$(echo "$CONTENT" | awk '/^\{/,/^\}/ {print}')
    if echo "$EXTRACTED" | jq -e '.' >/dev/null 2>&1; then
        JSON_CONTENT="$EXTRACTED"
    fi
fi

# Validate and output JSON
if [ -n "$JSON_CONTENT" ] && echo "$JSON_CONTENT" | jq -e '.' >/dev/null 2>&1; then
    # Valid JSON - output it
    echo "$JSON_CONTENT" | jq -c '.'
else
    # Invalid JSON - wrap in error
    echo "{\"error\": \"Failed to parse JSON from quality review\", \"status\": \"needs_review\", \"overall_score\": 50, \"raw_content\": $(echo "$CONTENT" | jq -Rs .)}" >&2
    exit 1
fi
