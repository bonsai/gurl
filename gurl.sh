#!/bin/bash

# Default values
DEFAULT_MODEL="gemini-1.5-pro"
CONFIG_FILE="$HOME/.config/gemini/config"
LOG_FILE="$HOME/.config/gemini/conversation_history.json"

# Load API key from config file
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
else
    echo "Error: Config file not found at $CONFIG_FILE"
    echo "Please create the config file with your API key:"
    echo "mkdir -p ~/.config/gemini"
    echo "echo 'API_KEY=\"YOUR_API_KEY\"' > $CONFIG_FILE"
    echo "chmod 600 $CONFIG_FILE"
    exit 1
fi

ENDPOINT="https://generativelanguage.googleapis.com/v1beta/models"

# Initialize log file if it doesn't exist
initialize_log_file() {
    if [ ! -f "$LOG_FILE" ]; then
        mkdir -p "$(dirname "$LOG_FILE")"
        echo '[]' > "$LOG_FILE"
        chmod 600 "$LOG_FILE"
    else
        # Validate existing log file
        if ! jq . "$LOG_FILE" >/dev/null 2>&1; then
            echo "Warning: Log file is corrupted, resetting..." >&2
            echo '[]' > "$LOG_FILE"
        fi
    fi
}
initialize_log_file

# Function to add to log (prepend to keep newest first)
add_to_log() {
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local model="$1"
    local prompt="$2"
    local response="$3"
    
    # Create a temporary file for the new entry
    local temp_file=$(mktemp)
    
    # Create a temporary file for the response
    local temp_response_file=$(mktemp)
    echo "$response" > "$temp_response_file"
    
    # Check if the response is valid JSON
    if jq -e . "$temp_response_file" >/dev/null 2>&1; then
        # Response is valid JSON, use it directly
        jq --arg timestamp "$timestamp" \
           --arg model "$model" \
           --arg prompt "$prompt" \
           --slurpfile response "$temp_response_file" \
           '[
             {
               "timestamp": $timestamp,
               "model": $model,
               "prompt": $prompt,
               "full_response": $response[0],
               "text_response": ($response[0].candidates[0].content.parts[0].text // "")
             }
           ] + .' "$LOG_FILE" > "$temp_file"
    else
        # Response is not valid JSON, store as text
        local text_response=""
        if [ -n "$response" ]; then
            text_response=$(echo "$response" | head -c 1000 | tr -d '\0')
        fi
        
        jq --arg timestamp "$timestamp" \
           --arg model "$model" \
           --arg prompt "$prompt" \
           --arg response "$response" \
           --arg text_response "$text_response" \
           '[
             {
               "timestamp": $timestamp,
               "model": $model,
               "prompt": $prompt,
               "full_response": $response,
               "text_response": $text_response
             }
           ] + .' --null-input > "$temp_file"
    fi
    
    # Only update the log file if jq succeeded
    if [ $? -eq 0 ]; then
        # Limit the log file to 50 entries to prevent it from growing too large
        jq '.[0:50]' "$temp_file" > "${temp_file}.tmp" && mv "${temp_file}.tmp" "$LOG_FILE"
    else
        echo "Warning: Failed to update conversation history" >&2
    fi
    
    # Clean up temporary files
    rm -f "$temp_file" "$temp_response_file" "${temp_file}.tmp" 2>/dev/null
}

# Function to view conversation history
view_log() {
    if [ ! -f "$LOG_FILE" ] || [ ! -s "$LOG_FILE" ]; then
        echo "No conversation history found."
        exit 0
    fi
    
    echo -e "\n\033[1;36m=== Conversation History (Newest First) ===\033[0m\n"
    
    # Read and display each entry with enhanced formatting
    local count=1
    jq -r '.[] | @base64' "$LOG_FILE" | while read -r entry; do
        # Decode the base64 entry
        local decoded=$(echo "$entry" | base64 -d)
        
        local timestamp=$(echo "$decoded" | jq -r '.timestamp')
        local model=$(echo "$decoded" | jq -r '.model')
        local prompt=$(echo "$decoded" | jq -r '.prompt')
        local full_response=$(echo "$decoded" | jq -r '.full_response // .response')
        local text_response=$(echo "$decoded" | jq -r '.text_response // empty')
        
        echo -e "\033[1;35m[$count]\033[0m \033[1;33m$timestamp\033[0m | \033[1;32m$model\033[0m"
        echo -e "\033[1;34m❓ Prompt:\033[0m"
        echo -e "   \033[0;37m$prompt\033[0m"
        
        # Display text response first
        if [ -n "$text_response" ] && [ "$text_response" != "null" ] && [ "$text_response" != "empty" ]; then
            echo -e "\033[1;32m💬 Text Response:\033[0m"
            echo -e "\033[1;37m┌─────────────────────────────────────────────────────────────────┐\033[0m"
            echo "$text_response" | fold -w 65 -s | sed 's/^/│ /' | sed 's/$/\033[1;37m │\033[0m/'
            echo -e "\033[1;37m└─────────────────────────────────────────────────────────────────┘\033[0m"
        fi
        
        # Display formatted full JSON response (now stored as JSON object)
        echo -e "\033[1;34m🔧 Full API Response:\033[0m"
        if echo "$full_response" | jq . >/dev/null 2>&1; then
            echo "$full_response" | jq -C --indent 2 .
            
            # Display token usage if available
            local prompt_tokens=$(echo "$full_response" | jq -r '.usageMetadata.promptTokenCount // empty' 2>/dev/null)
            local response_tokens=$(echo "$full_response" | jq -r '.usageMetadata.candidatesTokenCount // empty' 2>/dev/null)
            local total_tokens=$(echo "$full_response" | jq -r '.usageMetadata.totalTokenCount // empty' 2>/dev/null)
            
            if [ -n "$prompt_tokens" ] && [ "$prompt_tokens" != "empty" ]; then
                echo -e "\033[1;33m📊 Token Usage:\033[0m Prompt: $prompt_tokens | Response: $response_tokens | Total: $total_tokens"
            fi
        else
            echo -e "   \033[0;37m$full_response\033[0m"
        fi
        
        echo -e "\033[0;90m─────────────────────────────────────────────────────────────────\033[0m\n"
        count=$((count + 1))
    done
}

# Function to display only text response (for main execution)
display_text_response() {
    local response="$1"
    
    # Extract and display only the text response
    if echo "$response" | jq . >/dev/null 2>&1; then
        local text_response=$(echo "$response" | jq -r '.candidates[0].content.parts[0].text // empty' 2>/dev/null)
        if [ -n "$text_response" ] && [ "$text_response" != "null" ]; then
            echo "$text_response"
        else
            echo "No text response found in API response"
        fi
    else
        echo "Invalid JSON response from API"
    fi
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--model)
            MODEL="$2"
            shift 2
            ;;
        -l|--list-models)
            echo "Available models:"
            echo "  gemini-1.5-pro     - Most capable model (default)"
            echo "  gemini-1.5-flash   - Faster, more efficient model"
            echo "  gemini-1.0-pro     - Legacy model"
            exit 0
            ;;
        -c|--clear-log)
            echo "[]" > "$LOG_FILE"
            echo "Conversation history cleared."
            exit 0
            ;;
        -v|--view-log)
            view_log
            exit 0
            ;;
        -h|--help)
            show_help
            ;;
        *)
            PROMPT="$1"
            shift
            ;;
    esac
done

# Set default model if not specified
MODEL=${MODEL:-$DEFAULT_MODEL}

# Check if prompt is provided
if [ -z "$PROMPT" ]; then
    echo "Error: No prompt provided"
    show_help
    exit 1
fi

# Escape special characters in prompt for JSON
ESCAPED_PROMPT=$(echo "$PROMPT" | jq -R .)

# Create a temporary file for the JSON payload
TEMP_JSON=$(mktemp)
cat > "$TEMP_JSON" <<EOF
{
  "contents": [{
    "parts": [{"text": $ESCAPED_PROMPT}]
  }]
}
EOF

# Make the API call and capture the response
echo -e "\033[1;34mUsing model:\033[0m \033[1;32m$MODEL\033[0m"
echo -e "\033[1;34mSending request...\033[0m"
echo ""

RESPONSE=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  -d @"$TEMP_JSON" \
  "${ENDPOINT}/${MODEL}:generateContent?key=${API_KEY}")

# Check if curl was successful
if [ $? -ne 0 ]; then
    echo -e "\033[1;31mError: Failed to make API request\033[0m"
    rm -f "$TEMP_JSON"
    exit 1
fi

# Check if response is empty
if [ -z "$RESPONSE" ]; then
    echo -e "\033[1;31mError: Empty response from API\033[0m"
    rm -f "$TEMP_JSON"
    exit 1
fi

# Check for API errors in response
if echo "$RESPONSE" | jq -e '.error' >/dev/null 2>&1; then
    echo -e "\033[1;31m=== API Error Response ===\033[0m"
    echo "$RESPONSE" | jq -C --indent 2 '.error'
    rm -f "$TEMP_JSON"
    exit 1
fi

# Add to conversation log (store formatted JSON response)
add_to_log "$MODEL" "$PROMPT" "$RESPONSE"

# Format and display the response
display_text_response "$RESPONSE"

# Clean up
rm -f "$TEMP_JSON"

# Copy to Google Drive (optional - keep if you need this)
cp "$LOG_FILE" "/mnt/g/my drive" 2>/dev/null || true
