#!/usr/bin/env bash

build_js() {
    # --- Concatenate JS files ---
    echo "Merging JS files..."

    # Use provided TEMP_FOLDER, or default to current directory
    local TEMP_FOLDER="${1:-${TEMP_FOLDER:-.}}"
    
    # Use provided REMOVE_FILES flag, default to false (keep files)
    local REMOVE_FILES="${2:-false}"

    local WEBMAN_DIR="$TEMP_FOLDER/webman"
    local FINAL_FILENAME="mountfix.js"

    local JS_FILES=(
        "mf_actions.js"
        "mf_core.js"
        "mf_main.js"
    )

    > "$WEBMAN_DIR/$FINAL_FILENAME"

    for FILE in "${JS_FILES[@]}"; do
        if [ -f "$WEBMAN_DIR/$FILE" ]; then
            echo "Adding $FILE..."
            cat "$WEBMAN_DIR/$FILE" >> "$WEBMAN_DIR/$FINAL_FILENAME"
            echo -e "\n" >> "$WEBMAN_DIR/$FINAL_FILENAME"
            
            # Remove file only if REMOVE_FILES is true
            if [ "$REMOVE_FILES" = "true" ] || [ "$REMOVE_FILES" = "1" ]; then
                rm "$WEBMAN_DIR/$FILE"
            fi
        else
            echo "Warning: File $FILE not found, skipping."
        fi
    done

    echo "Success: All files merged into $FINAL_FILENAME"
}

# If script is executed directly (not sourced), run the function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    build_js "$@"
fi