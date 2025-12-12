#!/bin/bash
# Result Synthesizer
# Aggregates execution results and quality review into final output
#
# Usage: synthesize.sh <execution_results_file> <quality_review_file>
# Output: JSON synthesis to stdout

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_FILE="$1"
QUALITY_FILE="$2"
ORCHESTRATOR_PORT="${ORCHESTRATOR_PORT:-8085}"
WORKER_PORT="${WORKER_PORT:-8081}"
TIMEOUT=60

# Validate inputs
if [ ! -f "$RESULTS_FILE" ]; then
    echo '{"error": "Execution results file not found"}' >&2
    exit 1
fi

if [ ! -f "$QUALITY_FILE" ]; then
    echo '{"error": "Quality review file not found"}' >&2
    exit 1
fi

# Read files
RESULTS=$(cat "$RESULTS_FILE")
QUALITY=$(cat "$QUALITY_FILE")

# Validate JSON
if ! echo "$RESULTS" | jq -e '.' >/dev/null 2>&1; then
    echo '{"error": "Invalid JSON in results file"}' >&2
    exit 1
fi

if ! echo "$QUALITY" | jq -e '.' >/dev/null 2>&1; then
    echo '{"error": "Invalid JSON in quality file"}' >&2
    exit 1
fi

# Load synthesize prompt
SYNTH_PROMPT=$(cat "$SCRIPT_DIR/prompts/synthesize.txt")

# Determine which server to use
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
    echo '{"error": "No LLM server available"}' >&2
    exit 1
fi

# Prepare combined input (truncate individual results if too long)
COMBINED_INPUT=$(jq -n \
    --argjson results "$RESULTS" \
    --argjson quality "$QUALITY" \
    '{
        execution: {
            status: $results.status,
            total_success: $results.total_success,
            total_failed: $results.total_failed,
            batches: [$results.batches[] | {
                group: .group,
                description: .description,
                success: .success,
                failed: .failed,
                task_summaries: [.results[] | {
                    task_id: .task_id,
                    agent: .agent,
                    task: .task,
                    status: .status
                }]
            }]
        },
        quality_review: $quality
    }')

USER_MSG="Synthesize the following execution results and quality review:

$COMBINED_INPUT

Produce a final synthesis in JSON format."

# Build JSON payload and write to temp file
TMPFILE=$(mktemp /tmp/synthesize.XXXXXX.json)
trap "rm -f '$TMPFILE'" EXIT

jq -n \
    --arg model "$MODEL" \
    --arg system "$SYNTH_PROMPT" \
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
    echo '{"error": "Failed to connect to LLM server"}' >&2
    exit 1
fi

# Extract content - handle both standard and reasoning model formats
CONTENT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // empty')
REASONING=$(echo "$RESPONSE" | jq -r '.choices[0].message.reasoning_content // empty')

# If content is empty but reasoning exists, extract JSON from reasoning
if [ -z "$CONTENT" ] || [ "$CONTENT" = "null" ]; then
    if [ -n "$REASONING" ] && [ "$REASONING" != "null" ]; then
        CONTENT=$(echo "$REASONING" | grep -oE '\{[^{}]*"summary"[^{}]*\}' | tail -1)

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
    echo "{\"error\": \"$ERROR\"}" >&2
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
    EXTRACTED=$(echo "$CONTENT" | awk '/^\{/,/^\}/ {print}')
    if echo "$EXTRACTED" | jq -e '.' >/dev/null 2>&1; then
        JSON_CONTENT="$EXTRACTED"
    fi
fi

# Validate and output JSON
if [ -n "$JSON_CONTENT" ] && echo "$JSON_CONTENT" | jq -e '.' >/dev/null 2>&1; then
    echo "$JSON_CONTENT" | jq -c '.'
else
    echo "{\"error\": \"Failed to parse synthesis JSON\", \"raw_content\": $(echo "$CONTENT" | jq -Rs .)}" >&2
    exit 1
fi
