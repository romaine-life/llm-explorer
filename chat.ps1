param(
    [string]$Model
)

$API_BASE = "https://llm-explorer.romaine.life/llm"

# --- auth.romaine.life token ---
# Reuses the token the 'at' tool stores (single sign-in across romaine.life
# CLI tools). Refresh it with the authromaine flow when it expires. The
# legacy HS256 mint-from-keyring path was removed in the auth.romaine.life
# migration.

function Get-AuthToken {
    $tokenFile = Join-Path $env:USERPROFILE '.fzt-automate\auth-token.json'
    if (-not (Test-Path $tokenFile)) {
        Write-Host "Not signed in — run the authromaine flow to get an auth.romaine.life token" -ForegroundColor Red
        return $null
    }
    try {
        $raw = (Get-Content -Raw $tokenFile).TrimStart([char]0xFEFF)
        return ($raw | ConvertFrom-Json).token
    } catch {
        Write-Host "auth token file is unreadable — refresh it via the authromaine flow" -ForegroundColor Red
        return $null
    }
}

function API-Call($method, $path, $body) {
    $token = Get-AuthToken
    if (-not $token) { return $null }
    $headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
    $uri = "$API_BASE$path"
    try {
        if ($body) {
            $json = $body | ConvertTo-Json -Depth 10
            Invoke-RestMethod -Uri $uri -Method $method -Headers $headers -Body $json
        } else {
            Invoke-RestMethod -Uri $uri -Method $method -Headers $headers
        }
    } catch {
        Write-Host "API error: $_" -ForegroundColor DarkYellow
        $null
    }
}

# --- Model selection ---

if (-not $Model) {
    $models = ollama list 2>$null | Select-Object -Skip 1 | ForEach-Object { ($_ -split '\s+')[0] }
    if (-not $models) { Write-Host "No models installed. Run: ollama pull llama3.1:8b"; return }
    $Model = $models | fzf --height 40% --layout reverse --border --prompt="Model: "
    if (-not $Model) { return }
}

# --- Session setup ---

$sessionId = (Get-Date -Format 'yyyyMMdd-HHmmss') + "-" + ($Model -replace '[:/]', '-')

# Create session in cloud
$createResp = API-Call "Post" "/api/sessions" @{ sessionId = $sessionId; model = $Model }
if ($createResp) {
    Write-Host "Session: $sessionId" -ForegroundColor DarkGray
    Write-Host "Cloud logging active" -ForegroundColor DarkGray
} else {
    Write-Host "Session: $sessionId (local only)" -ForegroundColor DarkYellow
}

Write-Host "Chatting with $Model" -ForegroundColor Cyan
Write-Host "Type /bye to exit`n" -ForegroundColor DarkGray

$messages = @()

while ($true) {
    Write-Host "you> " -NoNewline -ForegroundColor Green
    $userInput = Read-Host
    if ($userInput -eq '/bye' -or $userInput -eq '') { break }

    $messages += @{ role = 'user'; content = $userInput }

    $body = @{
        model = $Model
        messages = $messages
        stream = $false
    } | ConvertTo-Json -Depth 10

    try {
        $resp = Invoke-RestMethod -Uri 'http://localhost:11434/api/chat' -Method Post -Body $body -ContentType 'application/json'
        $reply = $resp.message.content
        $messages += @{ role = 'assistant'; content = $reply }

        Write-Host "`n$reply`n" -ForegroundColor White

        # Push exchange to cloud
        $exchange = @{
            message = @{
                user = $userInput
                assistant = $reply
                timestamp = (Get-Date).ToString('o')
                eval_duration_ms = if ($resp.eval_duration) { [math]::Round($resp.eval_duration / 1e6) } else { $null }
                total_duration_ms = if ($resp.total_duration) { [math]::Round($resp.total_duration / 1e6) } else { $null }
            }
        }
        API-Call "Put" "/api/sessions/$sessionId" $exchange | Out-Null
    }
    catch {
        Write-Host "Error: $_" -ForegroundColor Red
    }
}

# Mark session ended
API-Call "Patch" "/api/sessions/$sessionId/end" $null | Out-Null
Write-Host "`nSession ended: $sessionId" -ForegroundColor DarkGray
