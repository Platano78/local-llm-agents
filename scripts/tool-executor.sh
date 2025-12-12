#!/bin/bash
# Execute tool requests from ReAct agents
# Usage: tool-executor.sh <tool_name> <json_args>

TOOL="$1"
ARGS="$2"

# Safety: limit file operations to allowed directories
ALLOWED_PATHS=("$HOME" "/tmp")

is_path_allowed() {
    local path="$1"
    # Resolve to absolute path
    local abs_path=$(realpath -m "$path" 2>/dev/null || echo "$path")

    for allowed in "${ALLOWED_PATHS[@]}"; do
        if [[ "$abs_path" == "$allowed"* ]]; then
            return 0
        fi
    done
    return 1
}

case "$TOOL" in
    "read_file")
        FILE=$(echo "$ARGS" | jq -r '.path // empty')
        if [ -z "$FILE" ]; then
            echo "ERROR: Missing 'path' parameter"
            exit 1
        fi
        if ! is_path_allowed "$FILE"; then
            echo "ERROR: Access denied - path not in allowed directories"
            exit 1
        fi
        if [ -f "$FILE" ]; then
            # Limit output to prevent context overflow
            head -c 50000 "$FILE"
            if [ $(wc -c < "$FILE") -gt 50000 ]; then
                echo -e "\n\n[TRUNCATED - file exceeds 50KB]"
            fi
        else
            echo "ERROR: File not found: $FILE"
            exit 1
        fi
        ;;

    "write_file")
        FILE=$(echo "$ARGS" | jq -r '.path // empty')
        CONTENT=$(echo "$ARGS" | jq -r '.content // empty')
        if [ -z "$FILE" ]; then
            echo "ERROR: Missing 'path' parameter"
            exit 1
        fi
        if ! is_path_allowed "$FILE"; then
            echo "ERROR: Access denied - path not in allowed directories"
            exit 1
        fi
        # Create directory if needed
        mkdir -p "$(dirname "$FILE")"
        echo "$CONTENT" > "$FILE"
        echo "SUCCESS: Wrote $(echo "$CONTENT" | wc -c) bytes to $FILE"
        ;;

    "append_file")
        FILE=$(echo "$ARGS" | jq -r '.path // empty')
        CONTENT=$(echo "$ARGS" | jq -r '.content // empty')
        if [ -z "$FILE" ]; then
            echo "ERROR: Missing 'path' parameter"
            exit 1
        fi
        if ! is_path_allowed "$FILE"; then
            echo "ERROR: Access denied - path not in allowed directories"
            exit 1
        fi
        if [ ! -f "$FILE" ]; then
            echo "ERROR: File not found: $FILE"
            exit 1
        fi
        echo "$CONTENT" >> "$FILE"
        echo "SUCCESS: Appended $(echo "$CONTENT" | wc -c) bytes to $FILE"
        ;;

    "list_dir")
        DIR=$(echo "$ARGS" | jq -r '.path // "."')
        if ! is_path_allowed "$DIR"; then
            echo "ERROR: Access denied - path not in allowed directories"
            exit 1
        fi
        if [ -d "$DIR" ]; then
            ls -la "$DIR" | head -100
            TOTAL=$(ls -1 "$DIR" 2>/dev/null | wc -l)
            if [ "$TOTAL" -gt 100 ]; then
                echo "[TRUNCATED - showing 100 of $TOTAL entries]"
            fi
        else
            echo "ERROR: Directory not found: $DIR"
            exit 1
        fi
        ;;

    "search")
        PATTERN=$(echo "$ARGS" | jq -r '.pattern // empty')
        DIR=$(echo "$ARGS" | jq -r '.path // "."')
        if [ -z "$PATTERN" ]; then
            echo "ERROR: Missing 'pattern' parameter"
            exit 1
        fi
        if ! is_path_allowed "$DIR"; then
            echo "ERROR: Access denied - path not in allowed directories"
            exit 1
        fi
        # Search with timeout and limits
        timeout 10 grep -r --include='*' -n "$PATTERN" "$DIR" 2>/dev/null | head -50
        TOTAL=$(timeout 10 grep -r --include='*' -c "$PATTERN" "$DIR" 2>/dev/null | awk -F: '{sum+=$2} END {print sum}')
        if [ -n "$TOTAL" ] && [ "$TOTAL" -gt 50 ]; then
            echo "[TRUNCATED - showing 50 of $TOTAL matches]"
        fi
        ;;

    *)
        echo "ERROR: Unknown tool: $TOOL"
        echo "Available tools: read_file, write_file, append_file, list_dir, search"
        exit 1
        ;;
esac
