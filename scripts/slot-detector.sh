#!/bin/bash
# Detect available slots on llama-server
# Returns count of slots NOT currently processing

PORT="${1:-8081}"
TIMEOUT=3

# Try /slots endpoint first
SLOTS=$(curl -s --max-time "$TIMEOUT" "http://localhost:$PORT/slots" 2>/dev/null)

if [ -n "$SLOTS" ] && echo "$SLOTS" | jq -e '.' >/dev/null 2>&1; then
    # Count available (not processing) slots
    AVAILABLE=$(echo "$SLOTS" | jq '[.[] | select(.is_processing == false)] | length')
    TOTAL=$(echo "$SLOTS" | jq 'length')

    # Output format: available/total
    if [ "$2" = "-v" ]; then
        echo "Slots: $AVAILABLE/$TOTAL available"
    else
        echo "$AVAILABLE"
    fi
else
    # Fallback to environment variable or default
    FALLBACK="${LLM_SLOTS:-6}"
    if [ "$2" = "-v" ]; then
        echo "Slots: $FALLBACK (fallback, server not responding)"
    else
        echo "$FALLBACK"
    fi
fi
