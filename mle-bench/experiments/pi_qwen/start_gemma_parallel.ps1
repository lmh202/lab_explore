[CmdletBinding()]
param(
    [ValidateRange(0.01, 24.0)]
    [double]$TimeLimitHours = 6,

    [int]$Seed = 42,

    [ValidateRange(1, 16)]
    [int]$MaxCpuThreads = 4,

    [ValidateRange(60, 1800)]
    [int]$StatusIntervalSeconds = 300,

    [string]$RepoRoot,
    [string]$RunsDir,
    [string]$PiExe
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$provider = "lum-llm"
$model = "nvidia/Gemma-4-26B-A4B-NVFP4"
$firstCpuOffset = 4
if (-not $RepoRoot) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}
if (-not $RunsDir) {
    $RunsDir = Join-Path $RepoRoot "runs\pi-gemma-original"
}
if (-not $PiExe) {
    $PiExe = (Resolve-Path (Join-Path $RepoRoot "..\pi_backup_0.84.1_original\pi.exe")).Path
}
if (-not (Test-Path -LiteralPath $PiExe -PathType Leaf)) {
    throw "Original Pi executable is missing: $PiExe"
}

$activePath = Join-Path $RunsDir "gemma-active.json"
if (Test-Path -LiteralPath $activePath -PathType Leaf) {
    try {
        $active = Get-Content -LiteralPath $activePath -Raw | ConvertFrom-Json
        $activeProcess = Get-Process -Id $active.supervisor_pid -ErrorAction SilentlyContinue
        if ($active.status -eq "running" -and $activeProcess) {
            throw "A Gemma suite is already active (supervisor PID $($active.supervisor_pid)): $($active.suite_json)"
        }
    }
    catch {
        if ($_.Exception.Message -like "A Gemma suite is already active*") {
            throw
        }
    }
}

$hadToken = (Test-Path Env:\ANTHROPIC_AUTH_TOKEN) -and
    -not [string]::IsNullOrWhiteSpace($env:ANTHROPIC_AUTH_TOKEN)
$tokenPointer = [IntPtr]::Zero
if (-not $hadToken) {
    $secureToken = Read-Host "Enter the existing lum.id API token (input is hidden and is not saved)" -AsSecureString
    $tokenPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
    $env:ANTHROPIC_AUTH_TOKEN = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($tokenPointer)
}

$suiteId = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssfffZ") + "-" +
    [guid]::NewGuid().ToString("N").Substring(0, 6)
$suiteRoot = Join-Path $RunsDir "supervisor\$suiteId"
New-Item -ItemType Directory -Path $suiteRoot -Force | Out-Null
$preflightPath = Join-Path $suiteRoot "gemma-preflight.json"
$preflightStdout = Join-Path $suiteRoot "gemma-preflight.stdout.log"
$preflightStderr = Join-Path $suiteRoot "gemma-preflight.stderr.log"
$supervisorStdout = Join-Path $suiteRoot "supervisor.stdout.log"
$supervisorStderr = Join-Path $suiteRoot "supervisor.stderr.log"

try {
    $versionInfo = [Diagnostics.ProcessStartInfo]::new()
    $versionInfo.FileName = $PiExe
    $versionInfo.Arguments = "--version"
    $versionInfo.UseShellExecute = $false
    $versionInfo.RedirectStandardOutput = $true
    $versionInfo.RedirectStandardError = $true
    $versionProcess = [Diagnostics.Process]::new()
    $versionProcess.StartInfo = $versionInfo
    [void]$versionProcess.Start()
    $piVersion = $versionProcess.StandardOutput.ReadToEnd().Trim()
    $versionError = $versionProcess.StandardError.ReadToEnd()
    $versionProcess.WaitForExit()
    if ($versionProcess.ExitCode -ne 0 -or $piVersion -ne "0.84.1") {
        throw "Expected original Pi 0.84.1, found '$piVersion'. $versionError"
    }

    $modelsPath = Join-Path $HOME ".pi\agent\models.json"
    $models = Get-Content -LiteralPath $modelsPath -Raw | ConvertFrom-Json
    $providerConfig = $models.providers.$provider
    if (-not $providerConfig -or @($providerConfig.models.id) -notcontains $model) {
        throw "$provider/$model is not configured in Pi models.json."
    }
    if ([string]$providerConfig.apiKey -ne '$ANTHROPIC_AUTH_TOKEN') {
        throw "The provider must reference ANTHROPIC_AUTH_TOKEN instead of storing a credential."
    }

    $preflightProcess = Start-Process `
        -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList @(
            "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
            "-File", (Join-Path $PSScriptRoot "verify_gemma.ps1"),
            "-PiExe", $PiExe,
            "-ResultPath", $preflightPath
        ) `
        -RedirectStandardOutput $preflightStdout `
        -RedirectStandardError $preflightStderr `
        -WindowStyle Hidden `
        -Wait `
        -PassThru
    if (-not (Test-Path -LiteralPath $preflightPath -PathType Leaf)) {
        throw "Gemma preflight did not produce a result. See $preflightStderr"
    }
    $preflight = Get-Content -LiteralPath $preflightPath -Raw | ConvertFrom-Json
    if (-not $preflight.available) {
        throw "Gemma failed authenticated inference/tool preflight. See $preflightPath"
    }

    $supervisorProcess = Start-Process `
        -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList @(
            "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
            "-File", (Join-Path $PSScriptRoot "supervise_gemma_parallel.ps1"),
            "-SuiteId", $suiteId,
            "-TimeLimitHours", ([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0}", $TimeLimitHours)),
            "-Seed", [string]$Seed,
            "-MaxCpuThreads", [string]$MaxCpuThreads,
            "-FirstCpuOffset", [string]$firstCpuOffset,
            "-StatusIntervalSeconds", [string]$StatusIntervalSeconds,
            "-RepoRoot", $RepoRoot,
            "-RunsDir", $RunsDir,
            "-PiExe", $PiExe,
            "-Provider", $provider,
            "-Model", $model
        ) `
        -RedirectStandardOutput $supervisorStdout `
        -RedirectStandardError $supervisorStderr `
        -WindowStyle Hidden `
        -PassThru

    $launch = [ordered]@{
        schema_version = 1
        suite_id = $suiteId
        launched_at_utc = [DateTime]::UtcNow.ToString("o")
        supervisor_pid = $supervisorProcess.Id
        pi_version = $piVersion
        pi_executable = $PiExe
        provider = $provider
        model = $model
        competition_count = 6
        parallel = $true
        time_limit_hours_per_case = $TimeLimitHours
        max_cpu_threads_per_case = $MaxCpuThreads
        first_cpu_offset = $firstCpuOffset
        status_interval_seconds = $StatusIntervalSeconds
        suite_json = (Join-Path $suiteRoot "suite.json")
        status_history = (Join-Path $suiteRoot "status.jsonl")
        preflight = $preflightPath
        supervisor_stdout = $supervisorStdout
        supervisor_stderr = $supervisorStderr
    }
    $launchPath = Join-Path $suiteRoot "launch.json"
    [IO.File]::WriteAllText(
        $launchPath,
        ($launch | ConvertTo-Json -Depth 8),
        [Text.UTF8Encoding]::new($false)
    )
    $launch | ConvertTo-Json -Depth 8
}
finally {
    if (-not $hadToken) {
        Remove-Item Env:\ANTHROPIC_AUTH_TOKEN -ErrorAction SilentlyContinue
    }
    if ($tokenPointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($tokenPointer)
    }
}
