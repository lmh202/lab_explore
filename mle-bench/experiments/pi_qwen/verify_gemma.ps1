[CmdletBinding()]
param(
    [string]$PiExe,
    [string]$ResultPath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$LASTEXITCODE = 0

$provider = "lum-llm"
$model = "nvidia/Gemma-4-26B-A4B-NVFP4"

if (-not $PiExe) {
    $PiExe = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..\pi\pi.exe")).Path
}
if (-not $ResultPath) {
    $ResultPath = Join-Path $PSScriptRoot "gemma-verification.json"
}
if (-not (Test-Path -LiteralPath $PiExe -PathType Leaf)) {
    throw "Pi executable is missing: $PiExe"
}

$hadToken = (Test-Path Env:\ANTHROPIC_AUTH_TOKEN) -and
    -not [string]::IsNullOrWhiteSpace($env:ANTHROPIC_AUTH_TOKEN)
$tokenPointer = [IntPtr]::Zero

if (-not $hadToken) {
    $secureToken = Read-Host "Enter the existing lum.id API token (input is hidden and is not saved)" -AsSecureString
    $tokenPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
    $env:ANTHROPIC_AUTH_TOKEN = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($tokenPointer)
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("pi-gemma-verify-" + [guid]::NewGuid().ToString("N"))
$tracePath = Join-Path $tempRoot "events.jsonl"
$stderrPath = Join-Path $tempRoot "stderr.log"
$taskPath = Join-Path $tempRoot "task.md"

try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    @"
Use the bash tool exactly once to run this command:

    printf gemma-tool-ok

After you observe the tool output, reply with exactly: GEMMA_VERIFY_OK
"@ | Set-Content -LiteralPath $taskPath -Encoding utf8

    $piArgs = @(
        "--mode", "json",
        "--no-session",
        "--provider", $provider,
        "--model", $model,
        "--no-extensions",
        "--no-skills",
        "--no-prompt-templates",
        "--no-context-files",
        "--no-approve",
        "@task.md"
    )
    $commandValues = @($PiExe) + $piArgs
    foreach ($value in $commandValues) {
        if ([string]$value -match '[\r\n"%]') {
            throw "Pi executable and arguments may not contain quotes, percent signs, or newlines."
        }
    }
    $command = (@($commandValues | ForEach-Object { '"' + [string]$_ + '"' }) -join " ")
    $command += ' 1>"' + $tracePath + '" 2>"' + $stderrPath + '"'
    $shellCommand = '"' + $command + '"'
    $process = Start-Process `
        -FilePath $env:ComSpec `
        -ArgumentList @("/D", "/S", "/C", $shellCommand) `
        -WorkingDirectory $tempRoot `
        -WindowStyle Hidden `
        -Wait `
        -PassThru
    $exitCode = $process.ExitCode

    $events = @()
    foreach ($line in (Get-Content -LiteralPath $tracePath -Encoding utf8)) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            try {
                $events += $line | ConvertFrom-Json
            }
            catch {
                # A malformed event makes the corresponding checks fail without exposing the trace.
            }
        }
    }

    $modelSeen = @($events | Where-Object {
        $_.type -in @("message_start", "message_end") -and
        $_.message.role -eq "assistant" -and
        $_.message.provider -eq $provider -and
        $_.message.model -eq $model
    }).Count -gt 0

    $successfulToolCall = @($events | Where-Object {
        $_.type -eq "tool_execution_end" -and
        $_.toolName -eq "bash" -and
        -not $_.isError -and
        (($_.result.content | ForEach-Object { $_.text }) -join "`n") -match "gemma-tool-ok"
    }).Count -gt 0

    $finalResponse = @($events | Where-Object {
        $_.type -eq "message_end" -and $_.message.role -eq "assistant"
    } | ForEach-Object {
        ($_.message.content | Where-Object { $_.type -eq "text" } | ForEach-Object { $_.text }) -join "`n"
    }) -join "`n"
    $finalResponseConfirmed = $finalResponse -match "GEMMA_VERIFY_OK"

    [string]$stderr = ""
    if (Test-Path -LiteralPath $stderrPath) {
        $stderrContent = Get-Content -LiteralPath $stderrPath -Raw -Encoding utf8
        if ($null -ne $stderrContent) {
            $stderr = [string]$stderrContent
        }
    }
    if (-not [string]::IsNullOrEmpty($env:ANTHROPIC_AUTH_TOKEN)) {
        $stderr = $stderr.Replace($env:ANTHROPIC_AUTH_TOKEN, "<redacted>")
    }
    if ($stderr.Length -gt 2000) {
        $stderr = $stderr.Substring($stderr.Length - 2000)
    }

    $available = ($exitCode -eq 0) -and $modelSeen -and $successfulToolCall -and $finalResponseConfirmed
    $result = [ordered]@{
        timestamp_utc = [DateTime]::UtcNow.ToString("o")
        provider = $provider
        model = $model
        pi_executable = $PiExe
        exit_code = $exitCode
        model_identity_verified = $modelSeen
        bash_tool_verified = $successfulToolCall
        final_response_verified = $finalResponseConfirmed
        available = $available
        stderr_tail = $stderr.Trim()
    }
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ResultPath -Encoding utf8
    $result | ConvertTo-Json -Depth 6

    if (-not $available) {
        exit 1
    }
}
finally {
    if (-not $hadToken) {
        Remove-Item Env:\ANTHROPIC_AUTH_TOKEN -ErrorAction SilentlyContinue
    }
    if ($tokenPointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($tokenPointer)
    }
    if (Test-Path -LiteralPath $tempRoot -PathType Container) {
        try {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction Stop
        }
        catch {
            # Cleanup must not hide the verification result if Windows still has a transient handle open.
        }
    }
}
