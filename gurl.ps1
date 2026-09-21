# gurl.ps1

# Default values
$DEFAULT_MODEL = "gemini-1.5-pro"
$CONFIG_DIR = Join-Path $HOME ".config" "gemini"
$CONFIG_FILE = Join-Path $CONFIG_DIR "config"
$LOG_FILE = Join-Path $CONFIG_DIR "conversation_history.json"

# Function to display help message
function Show-Help {
    Write-Host "`nUsage: pwsh ./gurl.ps1 [-m <model>] [-l] [-c] [-v] [-h] <prompt>" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  -m, --model <model>  Specify the Gemini model to use (default: $DEFAULT_MODEL)" -ForegroundColor Green
    Write-Host "  -l, --list-models    List available Gemini models" -ForegroundColor Green
    Write-Host "  -c, --clear-log      Clear the conversation history log" -ForegroundColor Green
    Write-Host "  -v, --view-log       View the conversation history log" -ForegroundColor Green
    Write-Host "  -h, --help           Display this help message" -ForegroundColor Green
    Write-Host ""
    Write-Host "  <prompt>             The text prompt to send to the Gemini API" -ForegroundColor Green
    Write-Host ""
    Write-Host "Examples:" -ForegroundColor DarkCyan
    Write-Host "  pwsh ./gurl.ps1 \"Tell me a joke.\"" -ForegroundColor DarkGray
    Write-Host "  pwsh ./gurl.ps1 -m gemini-1.5-flash \"Summarize this article.\"" -ForegroundColor DarkGray
    Write-Host "  pwsh ./gurl.ps1 -v" -ForegroundColor DarkGray
    exit 0
}

# Load API key from config file
function Load-ApiKey {
    if (Test-Path $CONFIG_FILE) {
        try {
            # Source the config file to load API_KEY variable
            . $CONFIG_FILE
            if (-not $API_KEY) {
                Write-Error "Error: API_KEY not found in $CONFIG_FILE"
                Write-Host "Please ensure the config file contains '`$API_KEY=\"YOUR_API_KEY\"'"
                exit 1
            }
        } catch {
            Write-Error "Error loading config file: $_"
            exit 1
        }
    } else {
        Write-Error "Error: Config file not found at $CONFIG_FILE"
        Write-Host "Please create the config file with your API key:"
        Write-Host "mkdir -p $CONFIG_DIR"
        Write-Host "Set-Content -Path $CONFIG_FILE -Value '`$API_KEY=\"YOUR_API_KEY\"'"
        Write-Host "(Get-Item $CONFIG_FILE).SetAccessControl((New-Object System.Security.AccessControl.FileSecurity).SetOwner((New-Object System.Security.Principal.NTAccount((whoami).Split('\')[-1]))).SetAccessRuleProtection(\$true,\$false))"
        Write-Host "Important: Secure your API key by setting appropriate permissions."
        exit 1
    }
}
Load-ApiKey

$ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/models"

# Initialize log file if it doesn't exist
function Initialize-LogFile {
    if (-not (Test-Path $LOG_FILE)) {
        New-Item -Path (Split-Path $LOG_FILE) -ItemType Directory -Force | Out-Null
        Set-Content -Path $LOG_FILE -Value "[]"
        # Set permissions for the log file (Windows equivalent of chmod 600)
        # Get-Acl $LOG_FILE | Set-Acl $LOG_FILE -Permission (Get-Acl $LOG_FILE).Access -RemoveAllAccessRights | Out-Null
        # (Get-Item $LOG_FILE).SetAccessControl((New-Object System.Security.AccessControl.FileSecurity).SetOwner((New-Object System.Security.Principal.NTAccount((whoami).Split('\')[-1]))).SetAccessRuleProtection($true,$false))
    } else {
        # Validate existing log file
        try {
            Get-Content $LOG_FILE | ConvertFrom-Json | Out-Null
        } catch {
            Write-Warning "Log file is corrupted, resetting..."
            Set-Content -Path $LOG_FILE -Value "[]"
        }
    }
}
Initialize-LogFile

# Function to add to log (prepend to keep newest first)
function Add-ToLog {
    param (
        [string]$Model,
        [string]$Prompt,
        [string]$Response
    )

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

    # Attempt to parse response as JSON
    try {
        $jsonResponse = $Response | ConvertFrom-Json -ErrorAction Stop
        $isJsonResponse = $true
    } catch {
        $isJsonResponse = $false
        Write-Warning "Response is not valid JSON, storing as plain text."
    }

    $entry = [PSCustomObject]@{
        timestamp = $timestamp
        model     = $Model
        prompt    = $Prompt
    }

    if ($isJsonResponse) {
        $entry | Add-Member -MemberType NoteProperty -Name "full_response" -Value $jsonResponse
        $entry | Add-Member -MemberType NoteProperty -Name "text_response" -Value ($jsonResponse.candidates[0].content.parts[0].text | Out-String).Trim()
    } else {
        $entry | Add-Member -MemberType NoteProperty -Name "full_response" -Value $Response
        $entry | Add-Member -MemberType NoteProperty -Name "text_response" -Value ($Response | Select-Object -First 1000) # Limit to 1000 chars for text_response
    }

    $logContent = @()
    if (Test-Path $LOG_FILE) {
        try {
            $logContent = (Get-Content $LOG_FILE | ConvertFrom-Json)
        } catch {
            Write-Warning "Could not read existing log content, starting new log."
            $logContent = @()
        }
    }
    
    # Prepend new entry and limit to 50 entries
    $newLogContent = @($entry) + $logContent | Select-Object -First 50

    try {
        $newLogContent | ConvertTo-Json -Depth 5 -Compress | Set-Content -Path $LOG_FILE -Force
    } catch {
        Write-Warning "Failed to update conversation history: $_"
    }
}

# Function to view conversation history
function View-Log {
    if (-not (Test-Path $LOG_FILE) -or (Get-Item $LOG_FILE).Length -eq 0) {
        Write-Host "No conversation history found." -ForegroundColor DarkYellow
        exit 0
    }

    Write-Host "`n`e[1;36m=== Conversation History (Newest First) ===`e[0m`n"

    $logEntries = Get-Content $LOG_FILE | ConvertFrom-Json

    $count = 1
    foreach ($entry in $logEntries) {
        Write-Host "`e[1;35m[$count]`e[0m `e[1;33m$($entry.timestamp)`e[0m | `e[1;32m$($entry.model)`e[0m"
        Write-Host "`e[1;34m❓ Prompt:`e[0m"
        Write-Host "   `e[0;37m$($entry.prompt)`e[0m"

        if (-not [string]::IsNullOrWhiteSpace($entry.text_response) -and $entry.text_response -ne "null" -and $entry.text_response -ne "empty") {
            Write-Host "`e[1;32m💬 Text Response:`e[0m"
            Write-Host "`e[1;37m┌─────────────────────────────────────────────────────────────────┐`e[0m"
            $entry.text_response | Out-String -Stream | ForEach-Object {
                Write-Host ("│ {0,-65} │" -f $_) -ForegroundColor White
            }
            Write-Host "`e[1;37m└─────────────────────────────────────────────────────────────────┘`e[0m"
        }

        Write-Host "`e[1;34m🔧 Full API Response:`e[0m"
        if ($entry.full_response -is [PSCustomObject]) {
            $entry.full_response | ConvertTo-Json -Depth 5 | ForEach-Object { Write-Host "   $_" }

            $promptTokens = $entry.full_response.usageMetadata.promptTokenCount
            $responseTokens = $entry.full_response.usageMetadata.candidatesTokenCount
            $totalTokens = $entry.full_response.usageMetadata.totalTokenCount

            if ($promptTokens) {
                Write-Host "`e[1;33m📊 Token Usage:`e[0m Prompt: $promptTokens | Response: $responseTokens | Total: $totalTokens"
            }
        } else {
            Write-Host "   `e[0;37m$($entry.full_response)`e[0m"
        }
        
        Write-Host "`e[0;90m─────────────────────────────────────────────────────────────────`e[0m`n"
        $count++
    }
}

# Function to display only text response (for main execution)
function Display-TextResponse {
    param (
        [string]$Response
    )

    try {
        $jsonResponse = $Response | ConvertFrom-Json -ErrorAction Stop
        $textResponse = ($jsonResponse.candidates[0].content.parts[0].text | Out-String).Trim()
        if (-not [string]::IsNullOrWhiteSpace($textResponse)) {
            Write-Host $textResponse
        } else {
            Write-Host "No text response found in API response" -ForegroundColor Red
        }
    } catch {
        Write-Host "Invalid JSON response from API" -ForegroundColor Red
    }
}

# Parse command line arguments
$argsParsed = $false
$MODEL = $DEFAULT_MODEL
$PROMPT = ""

for ($i = 0; $i -lt $args.Length; $i++) {
    $arg = $args[$i]
    switch ($arg) {
        "-m" {
            if ($i + 1 -lt $args.Length) {
                $MODEL = $args[$i+1]
                $i++
            } else {
                Write-Error "Error: -m requires a model name."
                Show-Help
                exit 1
            }
            $argsParsed = $true
        }
        "--model" {
            if ($i + 1 -lt $args.Length) {
                $MODEL = $args[$i+1]
                $i++
            } else {
                Write-Error "Error: --model requires a model name."
                Show-Help
                exit 1
            }
            $argsParsed = $true
        }
        "-l" {
            Write-Host "Available models:" -ForegroundColor DarkYellow
            Write-Host "  gemini-1.5-pro     - Most capable model (default)" -ForegroundColor Green
            Write-Host "  gemini-1.5-flash   - Faster, more efficient model" -ForegroundColor Green
            Write-Host "  gemini-1.0-pro     - Legacy model" -ForegroundColor Green
            exit 0
        }
        "--list-models" {
            Write-Host "Available models:" -ForegroundColor DarkYellow
            Write-Host "  gemini-1.5-pro     - Most capable model (default)" -ForegroundColor Green
            Write-Host "  gemini-1.5-flash   - Faster, more efficient model" -ForegroundColor Green
            Write-Host "  gemini-1.0-pro     - Legacy model" -ForegroundColor Green
            exit 0
        }
        "-c" {
            Set-Content -Path $LOG_FILE -Value "[]"
            Write-Host "Conversation history cleared." -ForegroundColor Green
            exit 0
        }
        "--clear-log" {
            Set-Content -Path $LOG_FILE -Value "[]"
            Write-Host "Conversation history cleared." -ForegroundColor Green
            exit 0
        }
        "-v" {
            View-Log
            exit 0
        }
        "--view-log" {
            View-Log
            exit 0
        }
        "-h" {
            Show-Help
        }
        "--help" {
            Show-Help
        }
        default {
            # If not an option, assume it's the prompt
            if (-not $argsParsed) {
                $PROMPT = $arg
                $argsParsed = $true
            } else {
                # If we've already parsed options, and then encountered another positional arg,
                # it's likely part of a multi-word prompt.
                $PROMPT += " " + $arg
            }
        }
    }
}

# Check if prompt is provided
if ([string]::IsNullOrWhiteSpace($PROMPT)) {
    Write-Error "Error: No prompt provided"
    Show-Help
    exit 1
}

# Create a JSON payload
$payload = @{
    contents = @(
        @{
            parts = @(
                @{ text = $PROMPT }
            )
        }
    )
}

$jsonPayload = $payload | ConvertTo-Json -Depth 4

Write-Host "`e[1;34mUsing model:`e[0m `e[1;32m$MODEL`e[0m"
Write-Host "`e[1;34mSending request...`e[0m"
Write-Host ""

try {
    $RESPONSE = Invoke-RestMethod -Method Post `
        -Uri "$ENDPOINT/$MODEL`:generateContent?key=$API_KEY" `
        -ContentType "application/json" `
        -Body $jsonPayload `
        -TimeoutSec 30 # Add a timeout for the request

    # Convert the PSObject response back to JSON string for logging consistent with original script
    $RESPONSE_JSON_STRING = $RESPONSE | ConvertTo-Json -Depth 5 -Compress

    # Add to conversation log
    Add-ToLog $MODEL $PROMPT $RESPONSE_JSON_STRING

    # Format and display the response
    Display-TextResponse $RESPONSE_JSON_STRING

} catch {
    Write-Error "Error: Failed to make API request. Details: $_"
    if ($_.Exception.Response) {
        $errorResponse = $_.Exception.Response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($errorResponse)
        $responseBody = $reader.ReadToEnd()
        Write-Error "API Error Response: $responseBody"
    }
    exit 1
}

# Copy to Google Drive (optional - keep if you need this)
# Check if Google Drive path exists (e.g., if G: drive is mounted as Google Drive)
# This part assumes a specific Google Drive mount point which might vary.
# If you are on Windows, Google Drive File Stream often mounts to a drive letter (e.g., G: or D:).
# You might need to adjust '/mnt/g/my drive' to 'G:\My Drive' or similar depending on your setup.
$googleDrivePath = "G:\My Drive" # Example for Windows, adjust as needed
if (Test-Path $googleDrivePath -PathType Container) {
    try {
        Copy-Item -Path $LOG_FILE -Destination $googleDrivePath -Force -ErrorAction Stop
        # Write-Host "Log file copied to Google Drive." # Uncomment for confirmation
    } catch {
        Write-Warning "Could not copy log file to Google Drive: $_"
    }
} else {
    Write-Warning "Google Drive path '$googleDrivePath' not found. Skipping copy."
}