#!/bin/bash
# Health check for local LLM servers
# Verifies that worker (8081) and orchestrator (8085) are running
# Detects CPU vs GPU orchestrator via inference speed test
# Detects available model presets from llama.cpp router
#
# Output: JSON status to stdout for parsing by other scripts

set -e

WORKER_PORT="${WORKER_PORT:-8081}"
ORCHESTRATOR_PORT="${ORCHESTRATOR_PORT:-8083}"
TIMEOUT=3
STATUS_FILE="/tmp/local-agents-status.json"

# Get available model presets from router
get_available_models() {
    local port="$1"
    curl -s --max-time "$TIMEOUT" "http://localhost:$port/v1/models" 2>/dev/null | \
        jq -r '.data[]?.id // empty' 2>/dev/null | sort || echo ""
}

# Select best model for a role based on available models
# Priority for decomposition: agents-seed-coder > coding-seed-coder > agents-* > first available
# Priority for quality: agents-qwen3-14b > agents-nemotron > agents-* > first available
select_model_for_role() {
    local role="$1"
    local available_models="$2"

    if [ -z "$available_models" ]; then
        echo ""
        return
    fi

    if [ "$role" = "decomposition" ]; then
        # Prefer fast, structured-output models
        echo "$available_models" | grep -m1 '^agents-seed-coder$' || \
        echo "$available_models" | grep -m1 '^coding-seed-coder$' || \
        echo "$available_models" | grep -m1 '^agents-' || \
        echo "$available_models" | head -1
    elif [ "$role" = "quality" ]; then
        # Prefer reasoning models
        echo "$available_models" | grep -m1 '^agents-qwen3-14b$' || \
        echo "$available_models" | grep -m1 '^agents-nemotron$' || \
        echo "$available_models" | grep -m1 '^agents-' || \
        echo "$available_models" | head -1
    else
        echo "$available_models" | head -1
    fi
}

check_server() {
    local port="$1"
    local name="$2"

    if curl -s --max-time "$TIMEOUT" "http://localhost:$port/health" | grep -q "ok"; then
        echo "  $name (port $port): HEALTHY" >&2
        return 0
    else
        echo "  $name (port $port): DOWN" >&2
        return 1
    fi
}

# Test inference speed to detect CPU vs GPU
# GPU: >50 t/s, CPU: <15 t/s
detect_orchestrator_type() {
    local port="$1"
    local model_id="${2:-orchestrator}"  # Use provided model or fallback

    # Quick inference test
    START=$(date +%s%3N)
    RESPONSE=$(curl -s --max-time 10 "http://localhost:$port/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"$model_id\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello\"}],\"max_tokens\":50}" 2>/dev/null)
    END=$(date +%s%3N)

    if [ -z "$RESPONSE" ]; then
        echo "unknown"
        return
    fi

    # Extract tokens and calculate speed
    TOKENS=$(echo "$RESPONSE" | jq -r '.usage.completion_tokens // 0' 2>/dev/null)
    ELAPSED_MS=$((END - START))

    if [ "$TOKENS" -gt 0 ] && [ "$ELAPSED_MS" -gt 0 ]; then
        # tokens per second = tokens / (elapsed_ms / 1000)
        TPS=$((TOKENS * 1000 / ELAPSED_MS))
        echo "  Orchestrator speed: ~${TPS} t/s" >&2

        if [ "$TPS" -gt 30 ]; then
            echo "gpu"
        else
            echo "cpu"
        fi
    else
        echo "unknown"
    fi
}

echo "=== Local LLM Health Check ===" >&2
echo "" >&2

WORKER_OK=0
ORCH_OK=0
ORCH_TYPE="none"
WORKER_SLOTS=0
WORKER_MODEL_ID=""
ORCH_MODEL_ID=""

# Check worker (GPU)
if check_server "$WORKER_PORT" "Worker (GPU)"; then
    WORKER_OK=1
    # Get slot info
    SLOTS=$(curl -s --max-time "$TIMEOUT" "http://localhost:$WORKER_PORT/slots" 2>/dev/null || echo "[]")
    TOTAL=$(echo "$SLOTS" | jq 'length' 2>/dev/null || echo "0")
    AVAILABLE=$(echo "$SLOTS" | jq '[.[] | select(.is_processing == false)] | length' 2>/dev/null || echo "0")
    WORKER_SLOTS=$AVAILABLE
    echo "    Slots: $AVAILABLE/$TOTAL available" >&2

    # Get available models
    echo "  Detecting available models..." >&2
    WORKER_MODELS=$(get_available_models "$WORKER_PORT")
    if [ -n "$WORKER_MODELS" ]; then
        MODEL_COUNT=$(echo "$WORKER_MODELS" | wc -l)
        echo "    Models: $MODEL_COUNT presets available" >&2
        WORKER_MODEL_ID=$(select_model_for_role "decomposition" "$WORKER_MODELS")
        if [ -n "$WORKER_MODEL_ID" ]; then
            echo "    Selected for decomposition: $WORKER_MODEL_ID" >&2
        fi
    fi
fi

# Check orchestrator and detect type
if check_server "$ORCHESTRATOR_PORT" "Orchestrator"; then
    ORCH_OK=1

    # Get available models first
    ORCH_MODELS=$(get_available_models "$ORCHESTRATOR_PORT")
    if [ -n "$ORCH_MODELS" ]; then
        MODEL_COUNT=$(echo "$ORCH_MODELS" | wc -l)
        echo "    Models: $MODEL_COUNT presets available" >&2
        ORCH_MODEL_ID=$(select_model_for_role "quality" "$ORCH_MODELS")
        if [ -n "$ORCH_MODEL_ID" ]; then
            echo "    Selected for quality review: $ORCH_MODEL_ID" >&2
        fi
    fi

    # Detect type using the selected model
    echo "  Detecting orchestrator type..." >&2
    ORCH_TYPE=$(detect_orchestrator_type "$ORCHESTRATOR_PORT" "$ORCH_MODEL_ID")
    echo "    Type: $ORCH_TYPE" >&2
fi

echo "" >&2

# Write status JSON
# Determine routing targets using shell logic first
# Per Qwen3 analysis: Orchestrator-8B is for ROUTING, not decomposition
# Seed-Coder (worker) is better for task decomposition (structured JSON output)
# Orchestrator is good for quality review (high-level reasoning)
if [ "$WORKER_OK" -eq 1 ]; then
    DECOMP_TARGET="worker"  # Always use coding model for decomposition
else
    DECOMP_TARGET="none"
fi

if [ "$ORCH_OK" -eq 1 ]; then
    QUALITY_TARGET="orchestrator"  # Use orchestrator for quality review
elif [ "$WORKER_OK" -eq 1 ]; then
    QUALITY_TARGET="worker"
else
    QUALITY_TARGET="none"
fi

if [ "$WORKER_OK" -eq 1 ]; then
    READY="true"
else
    READY="false"
fi

jq -n \
    --argjson worker_ok "$WORKER_OK" \
    --argjson orch_ok "$ORCH_OK" \
    --arg orch_type "$ORCH_TYPE" \
    --argjson worker_slots "$WORKER_SLOTS" \
    --arg worker_port "$WORKER_PORT" \
    --arg orch_port "$ORCHESTRATOR_PORT" \
    --arg worker_model "$WORKER_MODEL_ID" \
    --arg orch_model "$ORCH_MODEL_ID" \
    --arg decomp_target "$DECOMP_TARGET" \
    --arg quality_target "$QUALITY_TARGET" \
    --argjson ready "$READY" \
    '{
        worker: {
            healthy: ($worker_ok == 1),
            port: $worker_port,
            slots: $worker_slots,
            model_id: $worker_model
        },
        orchestrator: {
            healthy: ($orch_ok == 1),
            port: $orch_port,
            type: $orch_type,
            model_id: $orch_model
        },
        decomposition_target: $decomp_target,
        quality_review_target: $quality_target,
        ready: $ready
    }' > "$STATUS_FILE"

# Output JSON to stdout
cat "$STATUS_FILE"

# Summary to stderr - Updated architecture per Qwen3 analysis:
# Worker (Seed-Coder) = decomposition (good at structured JSON)
# Orchestrator = quality review (good at high-level reasoning)
if [ "$WORKER_OK" -eq 1 ]; then
    if [ "$ORCH_OK" -eq 1 ]; then
        echo "Status: READY (Worker: decomposition, Orchestrator: quality review)" >&2
        echo "  Routing: $ORCH_TYPE orchestrator available" >&2
        exit 0
    else
        echo "Status: READY (worker-only mode - no orchestrator for quality review)" >&2
        exit 0
    fi
else
    echo "Status: NOT READY (worker required for decomposition)" >&2
    echo "" >&2
    echo "Start the worker with:" >&2
    echo "  cd ~/project/llama-cpp-native && ./start-server-code-agents.sh" >&2
    exit 1
fi
