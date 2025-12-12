#!/bin/bash
# Execute Agents - Slot-aware Parallel Execution
# Takes mapped batches and executes tasks using ReAct loop
# Respects slot limits and waits for batches to complete
#
# Usage: execute-agents.sh <mapped_json_file> <output_dir>
# Output: Results written to output_dir/task_id.json

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAPPED_FILE="$1"
OUTPUT_DIR="${2:-/tmp/local-agents-output}"
WORKER_PORT="${WORKER_PORT:-8081}"
# Working directory for agents to use (default to current directory)
AGENT_WORK_DIR="${AGENT_WORK_DIR:-$(pwd)}"

# Validate input
if [ ! -f "$MAPPED_FILE" ]; then
    echo '{"error": "Mapped JSON file not found"}' >&2
    exit 1
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Read mapped tasks
MAPPED=$(cat "$MAPPED_FILE")
if ! echo "$MAPPED" | jq -e '.' >/dev/null 2>&1; then
    echo '{"error": "Invalid JSON in mapped file"}' >&2
    exit 1
fi

# Check for errors
if echo "$MAPPED" | jq -e '.error' >/dev/null 2>&1; then
    echo "$MAPPED" >&2
    exit 1
fi

# Get batches
BATCHES=$(echo "$MAPPED" | jq -r '.batches')
NUM_BATCHES=$(echo "$BATCHES" | jq 'length')

echo "Executing $NUM_BATCHES batch(es)..." >&2

# Track all results
ALL_RESULTS='{"batches": [], "status": "running"}'
TOTAL_SUCCESS=0
TOTAL_FAILED=0

# Execute batches sequentially (tasks within batch run in parallel)
for batch_idx in $(seq 0 $((NUM_BATCHES - 1))); do
    BATCH=$(echo "$BATCHES" | jq ".[$batch_idx]")
    GROUP=$(echo "$BATCH" | jq -r '.group')
    DESC=$(echo "$BATCH" | jq -r '.description')

    echo "=== Batch $GROUP: $DESC ===" >&2

    # Get tasks in this batch
    TASKS=$(echo "$BATCH" | jq -r '.tasks')
    NUM_TASKS=$(echo "$TASKS" | jq 'length')

    # Array to track background PIDs
    declare -a PIDS=()
    declare -a TASK_IDS=()

    # Launch tasks in parallel (up to slot limit)
    for task_idx in $(seq 0 $((NUM_TASKS - 1))); do
        TASK=$(echo "$TASKS" | jq ".[$task_idx]")
        TASK_ID=$(echo "$TASK" | jq -r '.task_id')
        AGENT=$(echo "$TASK" | jq -r '.agent')
        PHASE=$(echo "$TASK" | jq -r '.phase')
        TASK_DESC=$(echo "$TASK" | jq -r '.task')
        FILES=$(echo "$TASK" | jq -c '.files // []')
        SLOT=$(echo "$TASK" | jq -r '.slot')

        echo "  [$TASK_ID] Slot $SLOT: $AGENT ($PHASE)" >&2

        # Build task description for ReAct executor with working directory context
        TASK_FOR_REACT="[Phase: $PHASE] [WorkDir: $AGENT_WORK_DIR] $TASK_DESC

IMPORTANT: Use absolute paths starting with $AGENT_WORK_DIR for all file operations.
Output directory: $OUTPUT_DIR"

        # Launch ReAct executor in background
        (
            OUTPUT_FILE="$OUTPUT_DIR/${TASK_ID}.json"
            AGENT_OUTPUT_FILE="/tmp/agent_${AGENT}.txt"

            # Call react-executor.sh with agent name, task, iterations, port, and task_id
            # react-executor.sh expects: <agent_name> <task> [max_iterations] [port] [task_id]
            STDERR_OUTPUT=$("$SCRIPT_DIR/react-executor.sh" "$AGENT" "$TASK_FOR_REACT" 5 "$WORKER_PORT" "$TASK_ID" 2>&1)
            EXIT_CODE=$?

            # Read the actual output from agent output file (react-executor writes final answer here)
            if [ -f "$AGENT_OUTPUT_FILE" ]; then
                RESULT=$(cat "$AGENT_OUTPUT_FILE")
            else
                RESULT="$STDERR_OUTPUT"
            fi

            # Truncate result if too long (keep first 4000 chars)
            if [ ${#RESULT} -gt 4000 ]; then
                RESULT="${RESULT:0:4000}... [truncated]"
            fi

            # Write result
            jq -n \
                --arg task_id "$TASK_ID" \
                --arg agent "$AGENT" \
                --arg phase "$PHASE" \
                --arg task "$TASK_DESC" \
                --argjson exit_code "$EXIT_CODE" \
                --arg result "$RESULT" \
                '{
                    task_id: $task_id,
                    agent: $agent,
                    phase: $phase,
                    task: $task,
                    exit_code: $exit_code,
                    result: $result,
                    status: (if $exit_code == 0 then "success" else "failed" end)
                }' > "$OUTPUT_FILE"
        ) &

        PIDS+=($!)
        TASK_IDS+=("$TASK_ID")
    done

    # Wait for all tasks in this batch to complete
    echo "  Waiting for ${#PIDS[@]} task(s) to complete..." >&2

    BATCH_SUCCESS=0
    BATCH_FAILED=0
    BATCH_RESULTS='[]'

    for i in "${!PIDS[@]}"; do
        wait "${PIDS[$i]}"
        EXIT_CODE=$?
        TASK_ID="${TASK_IDS[$i]}"

        # Read result file
        RESULT_FILE="$OUTPUT_DIR/${TASK_ID}.json"
        if [ -f "$RESULT_FILE" ]; then
            TASK_RESULT=$(cat "$RESULT_FILE")
            BATCH_RESULTS=$(echo "$BATCH_RESULTS" | jq --argjson result "$TASK_RESULT" '. + [$result]')

            STATUS=$(echo "$TASK_RESULT" | jq -r '.status')
            if [ "$STATUS" = "success" ]; then
                ((BATCH_SUCCESS++))
                echo "    [$TASK_ID] ✓ Completed" >&2
            else
                ((BATCH_FAILED++))
                echo "    [$TASK_ID] ✗ Failed" >&2
            fi
        else
            ((BATCH_FAILED++))
            echo "    [$TASK_ID] ✗ No result file" >&2
        fi
    done

    echo "  Batch $GROUP complete: $BATCH_SUCCESS success, $BATCH_FAILED failed" >&2

    # Add batch results to overall
    BATCH_SUMMARY=$(jq -n \
        --argjson group "$GROUP" \
        --arg desc "$DESC" \
        --argjson success "$BATCH_SUCCESS" \
        --argjson failed "$BATCH_FAILED" \
        --argjson results "$BATCH_RESULTS" \
        '{
            group: $group,
            description: $desc,
            success: $success,
            failed: $failed,
            results: $results
        }')

    ALL_RESULTS=$(echo "$ALL_RESULTS" | jq --argjson batch "$BATCH_SUMMARY" '.batches += [$batch]')

    TOTAL_SUCCESS=$((TOTAL_SUCCESS + BATCH_SUCCESS))
    TOTAL_FAILED=$((TOTAL_FAILED + BATCH_FAILED))

    # Clean up arrays
    unset PIDS
    unset TASK_IDS
done

# Final summary
FINAL_STATUS="success"
[ "$TOTAL_FAILED" -gt 0 ] && FINAL_STATUS="partial"
[ "$TOTAL_SUCCESS" -eq 0 ] && FINAL_STATUS="failed"

ALL_RESULTS=$(echo "$ALL_RESULTS" | jq \
    --arg status "$FINAL_STATUS" \
    --argjson success "$TOTAL_SUCCESS" \
    --argjson failed "$TOTAL_FAILED" \
    '. + {
        status: $status,
        total_success: $success,
        total_failed: $failed,
        output_dir: "'"$OUTPUT_DIR"'"
    }')

echo "$ALL_RESULTS" | jq '.'
