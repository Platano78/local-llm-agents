#!/bin/bash
# ReAct tool loop executor for local LLM agents
# Implements: Thought → Action → Observation → repeat until final answer
#
# Qwen3 Recommendations Implemented:
# - Timeout wrapper with SIGALRM
# - Retry logic with validation feedback
# - Explicit JSON output constraints in prompts
#
# Usage: react-executor.sh <agent_name> <task> [max_iterations] [port] [task_id]
# Output: Final answer written to /tmp/agent_<agent_name>.txt

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT="$1"
TASK="$2"
MAX_ITERATIONS="${3:-5}"
PORT="${4:-8081}"
TASK_ID="${5:-$(date +%s)}"  # Unique ID for temp files, default to timestamp
LLM_TIMEOUT=45  # Per-request timeout
TOTAL_TIMEOUT=180  # Total execution timeout (3 min)
MAX_RETRIES=2  # Retries on empty response

# Read model ID from status file based on port
STATUS_FILE="${STATUS_FILE:-/tmp/local-agents-status.json}"
MODEL_ID="worker"  # Default fallback
if [ -f "$STATUS_FILE" ]; then
    WORKER_PORT=$(jq -r '.worker.port // "8081"' "$STATUS_FILE" 2>/dev/null)
    ORCH_PORT=$(jq -r '.orchestrator.port // "8083"' "$STATUS_FILE" 2>/dev/null)
    if [ "$PORT" = "$ORCH_PORT" ]; then
        MODEL_ID=$(jq -r '.orchestrator.model_id // "orchestrator"' "$STATUS_FILE" 2>/dev/null)
    else
        MODEL_ID=$(jq -r '.worker.model_id // "worker"' "$STATUS_FILE" 2>/dev/null)
    fi
fi

# Output file
OUTPUT_FILE="/tmp/agent_${AGENT}.txt"
LOG_FILE="/tmp/agent_${AGENT}.log"
JSON_LOG="/tmp/agent_${AGENT}.jsonl"  # Structured logging

# Clear previous output
> "$OUTPUT_FILE"
> "$LOG_FILE"
> "$JSON_LOG"

log() {
    echo "[$(date '+%H:%M:%S')] $*" >> "$LOG_FILE"
}

# Structured JSON logging (Qwen3 recommendation: observability)
log_json() {
    local event="$1"
    local data="${2:-{}}"
    # Use --arg for data to avoid JSON parsing issues with special characters
    jq -n -c \
        --arg ts "$(date -Iseconds)" \
        --arg agent "$AGENT" \
        --arg event "$event" \
        --arg data "$data" \
        '{timestamp: $ts, agent: $agent, event: $event, data_raw: $data}' >> "$JSON_LOG" 2>/dev/null || true
}

log "Starting ReAct loop for agent: $AGENT"
log "Task: $TASK"
log "Max iterations: $MAX_ITERATIONS"
log "Port: $PORT"
log "Total timeout: ${TOTAL_TIMEOUT}s"

log_json "start" "{\"task\":$(echo "$TASK" | jq -Rs .)}"

# Setup total timeout trap (Qwen3 recommendation: timeout wrapper)
TIMEOUT_REACHED=0
trap 'TIMEOUT_REACHED=1; log "TIMEOUT: Total execution time exceeded"; log_json "timeout" "{\"after_seconds\": $TOTAL_TIMEOUT}"' ALRM
( sleep $TOTAL_TIMEOUT && kill -ALRM $$ 2>/dev/null ) &
TIMEOUT_PID=$!

# Load agent prompt (skip YAML frontmatter between --- markers)
AGENT_FILE="$HOME/.claude/agents/${AGENT}.md"
if [ ! -f "$AGENT_FILE" ]; then
    echo "ERROR: Agent file not found: $AGENT_FILE" | tee "$OUTPUT_FILE"
    exit 1
fi

# Extract content after YAML frontmatter
SYSTEM_PROMPT=$(awk '
    BEGIN { in_frontmatter=0; started=0 }
    /^---$/ {
        if (!started) { in_frontmatter=1; started=1; next }
        else { in_frontmatter=0; next }
    }
    !in_frontmatter { print }
' "$AGENT_FILE")

# Load tool instructions
TOOL_INSTRUCTIONS=$(cat "$SCRIPT_DIR/prompts/tool-instructions.txt")

# Combine system prompt
FULL_SYSTEM="$SYSTEM_PROMPT

$TOOL_INSTRUCTIONS"

# Initialize message history as JSON
# Using temporary files because bash can't handle large JSON well
MESSAGES_FILE="/tmp/agent_${TASK_ID}_${AGENT}_messages.json"

# Build initial messages
jq -n --arg sys "$FULL_SYSTEM" --arg task "$TASK" \
    '[{"role": "system", "content": $sys}, {"role": "user", "content": $task}]' \
    > "$MESSAGES_FILE"

# Function to call LLM with retry logic (Qwen3 recommendation: validation retries)
call_llm_with_retry() {
    local retry_count=0
    local response=""
    local content=""

    while [ $retry_count -lt $MAX_RETRIES ]; do
        # Check timeout
        if [ "$TIMEOUT_REACHED" -eq 1 ]; then
            echo ""
            return 1
        fi

        response=$(curl -s --max-time "$LLM_TIMEOUT" "http://localhost:$PORT/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d @- <<EOF
{
    "model": "$MODEL_ID",
    "messages": $(cat "$MESSAGES_FILE"),
    "max_tokens": 4096,
    "temperature": 0.3,
    "stop": ["Observation:", "\nObservation:"]
}
EOF
        )

        content=$(echo "$response" | jq -r '.choices[0].message.content // empty')

        if [ -n "$content" ] && [ "$content" != "null" ]; then
            echo "$content"
            return 0
        fi

        retry_count=$((retry_count + 1))
        log "Retry $retry_count/$MAX_RETRIES: Empty response from LLM"
        log_json "retry" "{\"attempt\": $retry_count, \"reason\": \"empty_response\"}"

        # Add feedback for retry (Qwen3 recommendation: auto-retry with feedback)
        if [ $retry_count -lt $MAX_RETRIES ]; then
            jq '. + [{"role": "user", "content": "Your previous response was empty. Please try again and provide a complete response."}]' \
                "$MESSAGES_FILE" > "${MESSAGES_FILE}.tmp" && mv "${MESSAGES_FILE}.tmp" "$MESSAGES_FILE"
        fi
    done

    echo ""
    return 1
}

# ReAct loop
for i in $(seq 1 $MAX_ITERATIONS); do
    # Check timeout
    if [ "$TIMEOUT_REACHED" -eq 1 ]; then
        log "Aborting due to timeout"
        break
    fi

    log "=== Iteration $i/$MAX_ITERATIONS ==="
    log_json "iteration_start" "{\"iteration\": $i}"

    # Call LLM with retry
    CONTENT=$(call_llm_with_retry)

    if [ -z "$CONTENT" ]; then
        log "ERROR: Empty response from LLM after $MAX_RETRIES retries"
        log_json "error" "{\"type\": \"empty_response\", \"retries\": $MAX_RETRIES}"
        echo "ERROR: LLM returned empty response after retries" | tee "$OUTPUT_FILE"
        kill $TIMEOUT_PID 2>/dev/null || true
        exit 1
    fi

    log "Response received (${#CONTENT} chars)"
    log_json "response" "{\"chars\": ${#CONTENT}}"

    # Check for tool call using XML tags
    if echo "$CONTENT" | grep -q "<tool>"; then
        # Extract tool name and args
        TOOL_NAME=$(echo "$CONTENT" | grep -oP '(?<=<tool>)[^<]+' | head -1 | tr -d '[:space:]')
        TOOL_ARGS=$(echo "$CONTENT" | grep -oP '(?<=<args>).*?(?=</args>)' | head -1)

        # If args extraction failed, try multiline
        if [ -z "$TOOL_ARGS" ]; then
            TOOL_ARGS=$(echo "$CONTENT" | sed -n '/<args>/,/<\/args>/p' | sed '1d;$d')
        fi

        log "Tool call: $TOOL_NAME"
        log "Args: $TOOL_ARGS"
        log_json "tool_call" "{\"tool\": \"$TOOL_NAME\", \"iteration\": $i}"

        # Execute tool with timeout - preserve actual error message
        TOOL_OUTPUT=$(timeout 30 "$SCRIPT_DIR/tool-executor.sh" "$TOOL_NAME" "$TOOL_ARGS" 2>&1)
        TOOL_EXIT=$?

        if [ $TOOL_EXIT -eq 0 ]; then
            OBSERVATION="$TOOL_OUTPUT"
        elif [ $TOOL_EXIT -eq 124 ]; then
            OBSERVATION="ERROR: Tool execution timed out after 30 seconds"
            log "Tool execution timed out"
            log_json "tool_error" "{\"tool\": \"$TOOL_NAME\", \"error\": \"timeout\"}"
        else
            # Preserve actual error message from tool
            OBSERVATION="ERROR: $TOOL_OUTPUT"
            log "Tool execution failed: $TOOL_OUTPUT"
            log_json "tool_error" "{\"tool\": \"$TOOL_NAME\", \"error\": \"exit_code_$TOOL_EXIT\"}"
        fi

        log "Observation received (${#OBSERVATION} chars)"

        # Add assistant message and observation to history
        jq --arg content "$CONTENT" \
           '. + [{"role": "assistant", "content": $content}]' \
           "$MESSAGES_FILE" > "${MESSAGES_FILE}.tmp" && mv "${MESSAGES_FILE}.tmp" "$MESSAGES_FILE"

        jq --arg obs "Observation: $OBSERVATION" \
           '. + [{"role": "user", "content": $obs}]' \
           "$MESSAGES_FILE" > "${MESSAGES_FILE}.tmp" && mv "${MESSAGES_FILE}.tmp" "$MESSAGES_FILE"

    else
        # No tool call - this is the final answer
        log "Final answer received"
        log_json "complete" "{\"iterations\": $i, \"status\": \"final_answer\"}"
        echo "$CONTENT" > "$OUTPUT_FILE"
        log "Output written to $OUTPUT_FILE"

        # Cleanup
        kill $TIMEOUT_PID 2>/dev/null || true
        rm -f "$MESSAGES_FILE"
        exit 0
    fi
done

# Max iterations reached
log "WARNING: Max iterations ($MAX_ITERATIONS) reached without final answer"
log_json "complete" "{\"iterations\": $MAX_ITERATIONS, \"status\": \"max_iterations\"}"
echo "WARNING: Agent did not complete within $MAX_ITERATIONS iterations. Last response:" > "$OUTPUT_FILE"
echo "$CONTENT" >> "$OUTPUT_FILE"

# Cleanup
kill $TIMEOUT_PID 2>/dev/null || true
rm -f "$MESSAGES_FILE"
exit 0
