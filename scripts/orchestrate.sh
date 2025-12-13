#!/bin/bash
# Main Orchestration Pipeline
# Coordinates the full local-agents workflow:
# 1. Health check → 2. Decompose → 3. Map → 4. Execute → 5. Quality Gate → 6. Synthesize
#
# Supports CPU/GPU orchestrator detection:
# - GPU orchestrator (>30 t/s): Use for decomposition directly
# - CPU orchestrator (<30 t/s): Route decomposition to GPU worker, use orchestrator for quality review
#
# Usage: orchestrate.sh <task_description> [max_slots]
# Output: Final synthesis JSON to stdout, progress to stderr

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASK_INPUT="$1"
MAX_SLOTS="${2:-6}"

# Smart detection: Is $1 a file path or raw text?
# This enables token-efficient mode where Claude writes large specs to a file
# instead of passing 50KB+ inline (saves 95%+ tokens on large tasks)
if [[ -f "$TASK_INPUT" ]]; then
    # File mode: read task from file
    TASK=$(<"$TASK_INPUT")
    echo -e "${GREEN}[INFO]${NC} Reading task from file: $TASK_INPUT" >&2
else
    # Inline mode: use argument directly (backward compatible)
    TASK="$TASK_INPUT"
fi
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
WORK_DIR="/tmp/local-agents-$TIMESTAMP"
LOG_FILE="$WORK_DIR/pipeline.log"
STATUS_FILE="/tmp/local-agents-status.json"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Structured logging function (Qwen3 recommendation: observability)
log_json() {
    local level="$1"
    local stage="$2"
    local message="$3"
    local extra="${4:-{}}"

    jq -n -c \
        --arg ts "$(date -Iseconds)" \
        --arg level "$level" \
        --arg stage "$stage" \
        --arg msg "$message" \
        --argjson extra "$extra" \
        '{timestamp: $ts, level: $level, stage: $stage, message: $msg} + $extra' >> "$LOG_FILE" 2>/dev/null || true
}

log_step() {
    echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} ${GREEN}$1${NC}" >&2
    log_json "info" "pipeline" "$1"
}

log_warn() {
    echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} ${YELLOW}$1${NC}" >&2
    log_json "warn" "pipeline" "$1"
}

log_error() {
    echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} ${RED}$1${NC}" >&2
    log_json "error" "pipeline" "$1"
}

log_routing() {
    echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} ${CYAN}[ROUTING]${NC} $1" >&2
    log_json "info" "routing" "$1"
}

# Validate input
if [ -z "$TASK" ]; then
    log_error "Usage: orchestrate.sh <task_description> [max_slots]"
    exit 1
fi

# Create working directory
mkdir -p "$WORK_DIR"
touch "$LOG_FILE"
log_step "Work directory: $WORK_DIR"

# ============================================================================
# STEP 1: Health Check with CPU/GPU Detection
# ============================================================================
log_step "Step 1/6: Health Check"

# Capture stdout (JSON) and stderr (status messages) separately
HEALTH_JSON=$("$SCRIPT_DIR/health-check.sh" 2>/dev/null) || {
    log_error "Health check failed"
    echo '{"error": "Health check failed - no LLM servers available"}' >&2
    exit 1
}

# Parse health status
if ! echo "$HEALTH_JSON" | jq -e '.' >/dev/null 2>&1; then
    # Fallback if health check didn't return JSON
    log_warn "Health check didn't return JSON, using defaults"
    HEALTH_JSON='{"worker":{"healthy":true,"port":"8081"},"orchestrator":{"healthy":false,"type":"none"},"decomposition_target":"worker","quality_review_target":"worker","ready":true}'
fi

# Save status for other scripts
echo "$HEALTH_JSON" > "$STATUS_FILE"

# Extract routing decisions
DECOMP_TARGET=$(echo "$HEALTH_JSON" | jq -r '.decomposition_target // "worker"')
QUALITY_TARGET=$(echo "$HEALTH_JSON" | jq -r '.quality_review_target // "worker"')
ORCH_TYPE=$(echo "$HEALTH_JSON" | jq -r '.orchestrator.type // "none"')
WORKER_PORT=$(echo "$HEALTH_JSON" | jq -r '.worker.port // "8081"')
ORCH_PORT=$(echo "$HEALTH_JSON" | jq -r '.orchestrator.port // "8085"')

log_routing "Orchestrator type: $ORCH_TYPE"
log_routing "Decomposition target: $DECOMP_TARGET"
log_routing "Quality review target: $QUALITY_TARGET"

# Export for child scripts
export DECOMP_TARGET
export QUALITY_TARGET
export WORKER_PORT
export ORCHESTRATOR_PORT="$ORCH_PORT"

# Parse available slots
AVAILABLE_SLOTS=$("$SCRIPT_DIR/slot-detector.sh" 2>/dev/null)
if [ -z "$AVAILABLE_SLOTS" ] || [ "$AVAILABLE_SLOTS" -eq 0 ] 2>/dev/null; then
    log_warn "No slots detected, using default: $MAX_SLOTS"
    AVAILABLE_SLOTS=$MAX_SLOTS
fi

log_step "Available slots: $AVAILABLE_SLOTS"

# ============================================================================
# STEP 2: Task Decomposition
# ============================================================================
log_step "Step 2/6: Task Decomposition"

DECOMPOSED_FILE="$WORK_DIR/decomposed.json"
"$SCRIPT_DIR/tdd-decomposer.sh" "$TASK" "$AVAILABLE_SLOTS" > "$DECOMPOSED_FILE"

# Check for decomposition errors
if ! jq -e '.parallel_groups' "$DECOMPOSED_FILE" >/dev/null 2>&1; then
    ERROR=$(jq -r '.error // "Decomposition failed"' "$DECOMPOSED_FILE" 2>/dev/null || cat "$DECOMPOSED_FILE")
    log_error "Decomposition failed: $ERROR"
    cat "$DECOMPOSED_FILE"
    exit 1
fi

NUM_TASKS=$(jq '[.parallel_groups[].tasks | length] | add' "$DECOMPOSED_FILE")
NUM_GROUPS=$(jq '.parallel_groups | length' "$DECOMPOSED_FILE")
log_step "Decomposed into $NUM_TASKS tasks across $NUM_GROUPS parallel groups"

# ============================================================================
# STEP 3: Agent Mapping
# ============================================================================
log_step "Step 3/6: Agent Mapping"

MAPPED_FILE="$WORK_DIR/mapped.json"
"$SCRIPT_DIR/agent-mapper.sh" "$DECOMPOSED_FILE" "$AVAILABLE_SLOTS" > "$MAPPED_FILE"

if ! jq -e '.batches' "$MAPPED_FILE" >/dev/null 2>&1; then
    log_error "Agent mapping failed"
    cat "$MAPPED_FILE" >&2
    exit 1
fi

log_step "Mapped tasks to $AVAILABLE_SLOTS worker slots"

# ============================================================================
# STEP 4: Execute Agents
# ============================================================================
log_step "Step 4/6: Executing Agents"

RESULTS_FILE="$WORK_DIR/results.json"
OUTPUT_DIR="$WORK_DIR/outputs"
mkdir -p "$OUTPUT_DIR"

"$SCRIPT_DIR/execute-agents.sh" "$MAPPED_FILE" "$OUTPUT_DIR" > "$RESULTS_FILE"

# Check execution results
EXEC_STATUS=$(jq -r '.status // "unknown"' "$RESULTS_FILE")
EXEC_SUCCESS=$(jq -r '.total_success // 0' "$RESULTS_FILE")
EXEC_FAILED=$(jq -r '.total_failed // 0' "$RESULTS_FILE")

log_step "Execution complete: $EXEC_SUCCESS succeeded, $EXEC_FAILED failed (status: $EXEC_STATUS)"

# ============================================================================
# STEP 5: Quality Gate
# ============================================================================
log_step "Step 5/6: Quality Gate Review"

QUALITY_FILE="$WORK_DIR/quality.json"

# Check if quality review target is available
if [ "$QUALITY_TARGET" = "none" ]; then
    log_warn "No LLM server available for quality review"
    log_warn "Claude fallback: Manual quality review required"
    
    # Create quality.json for manual review
    jq -n \
        --argjson results "$(cat "$RESULTS_FILE")" \
        '{
            status: "manual_review_required",
            overall_score: 0,
            message: "No local LLM server available. Quality review requires Claude Code manual inspection.",
            claude_fallback: true,
            execution_summary: $results
        }' > "$QUALITY_FILE"
else
    # Use local LLM for quality review (capture only stdout, stderr to logs)
    "$SCRIPT_DIR/quality-gate.sh" "$RESULTS_FILE" > "$QUALITY_FILE" 2>>"$LOG_FILE"
fi

# Check quality results
QUALITY_STATUS=$(jq -r '.status // "unknown"' "$QUALITY_FILE")
QUALITY_SCORE=$(jq -r '.overall_score // 0' "$QUALITY_FILE")

if [ "$QUALITY_STATUS" = "fail" ]; then
    log_warn "Quality gate: FAIL (score: $QUALITY_SCORE)"
elif [ "$QUALITY_STATUS" = "pass" ]; then
    log_step "Quality gate: PASS (score: $QUALITY_SCORE)"
else
    log_warn "Quality gate: NEEDS REVIEW (score: $QUALITY_SCORE)"
fi

# ============================================================================
# STEP 6: Synthesize Results
# ============================================================================
log_step "Step 6/6: Synthesizing Results"

SYNTHESIS_FILE="$WORK_DIR/synthesis.json"
"$SCRIPT_DIR/synthesize.sh" "$RESULTS_FILE" "$QUALITY_FILE" > "$SYNTHESIS_FILE" 2>&1

if ! jq -e '.' "$SYNTHESIS_FILE" >/dev/null 2>&1; then
    log_error "Synthesis failed"
    # Fall back to raw results
    jq -n \
        --argjson results "$(cat "$RESULTS_FILE")" \
        --argjson quality "$(cat "$QUALITY_FILE")" \
        '{
            error: "Synthesis failed, returning raw results",
            execution: $results,
            quality: $quality
        }' > "$SYNTHESIS_FILE"
fi

# ============================================================================
# Final Output
# ============================================================================
log_step "Pipeline complete"
log_step "Work directory: $WORK_DIR"
log_step "  - decomposed.json: Task decomposition"
log_step "  - mapped.json: Agent mapping"
log_step "  - results.json: Execution results"
log_step "  - quality.json: Quality review"
log_step "  - synthesis.json: Final synthesis"
log_step "  - outputs/: Individual task outputs"

# Output final synthesis
cat "$SYNTHESIS_FILE"
