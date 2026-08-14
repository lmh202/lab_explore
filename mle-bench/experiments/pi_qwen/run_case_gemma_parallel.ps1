[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CompetitionId,

    [Parameter(Mandatory = $true)]
    [ValidateSet("baseline", "policy_v1")]
    [string]$Variant,

    [ValidateRange(0.01, 24.0)]
    [double]$TimeLimitHours = 6,

    [int]$Seed = 42,
    [ValidateRange(1, 63)]
    [int]$MaxCpuThreads = 4,
    [int]$CoreOffset = 0,
    [ValidateRange(1, 5)]
    [int]$MaxPiAttempts = 3,
    [ValidateRange(30, 1800)]
    [int]$MinRetrySeconds = 180,
    [string]$RepoRoot,
    [string]$DataDir,
    [string]$RunsDir,
    [string]$PythonExe,
    [string]$PiExe,
    [string]$PolicyAddendum
)

# Copy of run_case_gemma.ps1 for running several candidates truly in
# parallel: instead of dot-sourcing process_control.ps1's
# Set-ExperimentResourceLimits (which always pins to logical cores 0..N-1),
# this shifts the affinity mask by CoreOffset bits so each concurrent
# instance gets its own non-overlapping slice of the machine's 32 logical
# cores (e.g. offset 0 -> cores 0-3, offset 4 -> cores 4-7, ...).

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$LASTEXITCODE = 0
if ($env:PATHEXT -notmatch "(?i)(^|;)\.EXE(;|$)") {
    $env:PATHEXT = ".COM;.EXE;.BAT;.CMD;$env:PATHEXT"
}
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"

if (-not $RepoRoot) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}
if (-not $DataDir) {
    $DataDir = Join-Path $RepoRoot "data"
}
if (-not $RunsDir) {
    $RunsDir = Join-Path $RepoRoot "runs\pi-qwen-gemma"
}
if (-not $PythonExe) {
    $PythonExe = Join-Path $RepoRoot ".venv\Scripts\python.exe"
}
if (-not $PiExe) {
    $PiExe = Join-Path (Split-Path $RepoRoot -Parent) "pi\pi.exe"
}

$ManifestPath = Join-Path $PSScriptRoot "candidates_gemma.json"
$ExperimentPy = Join-Path $PSScriptRoot "experiment.py"
$RuntimeGuard = Join-Path $PSScriptRoot "extensions\gemma_runtime_guard.ts"

# Inline resource limiting with a core offset (see header comment).
$effectiveThreads = [Math]::Min($MaxCpuThreads, [Environment]::ProcessorCount)
foreach ($name in @("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS", "NUMEXPR_NUM_THREADS", "VECLIB_MAXIMUM_THREADS", "BLIS_NUM_THREADS", "LOKY_MAX_CPU_COUNT")) {
    [Environment]::SetEnvironmentVariable($name, [string]$effectiveThreads, "Process")
}
[Environment]::SetEnvironmentVariable("TOKENIZERS_PARALLELISM", "false", "Process")
$mask = (([int64]1 -shl $effectiveThreads) - 1) -shl $CoreOffset
$currentProcess = [Diagnostics.Process]::GetCurrentProcess()
$currentProcess.ProcessorAffinity = [IntPtr]$mask
$currentProcess.PriorityClass = [Diagnostics.ProcessPriorityClass]::BelowNormal
$resourceLimits = [pscustomobject]@{
    max_cpu_threads = $effectiveThreads
    affinity_mask = ("0x{0:X}" -f $mask)
    core_offset = $CoreOffset
    priority = [string]$currentProcess.PriorityClass
    child_windows_hidden = $true
}

function Get-PiVersion {
    param([string]$Path)
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Path
    $startInfo.Arguments = "--version"
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $versionProcess = [Diagnostics.Process]::new()
    $versionProcess.StartInfo = $startInfo
    [void]$versionProcess.Start()
    $stdout = $versionProcess.StandardOutput.ReadToEnd()
    $stderr = $versionProcess.StandardError.ReadToEnd()
    $versionProcess.WaitForExit()
    if ($versionProcess.ExitCode -ne 0) {
        throw "Pi version check failed: $stderr"
    }
    return $stdout.Trim()
}

$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$candidateIds = @($manifest.candidates.competition_id)
$smokeId = [string]$manifest.smoke.competition_id
if (($candidateIds -notcontains $CompetitionId) -and $CompetitionId -ne $smokeId) {
    throw "Competition '$CompetitionId' is not in the fixed experiment manifest."
}
if (-not (Test-Path -LiteralPath $PythonExe -PathType Leaf)) {
    throw "Experiment Python is missing: $PythonExe"
}
if (-not (Test-Path -LiteralPath $PiExe -PathType Leaf)) {
    throw "Pi executable is missing: $PiExe"
}
if (-not (Test-Path -LiteralPath $RuntimeGuard -PathType Leaf)) {
    throw "Gemma runtime guard is missing: $RuntimeGuard"
}
if (-not (Test-Path Env:\ANTHROPIC_AUTH_TOKEN) -or
    [string]::IsNullOrWhiteSpace($env:ANTHROPIC_AUTH_TOKEN)) {
    throw "ANTHROPIC_AUTH_TOKEN is not set in this PowerShell session. It must not be written to a file or passed on the command line."
}

$piVersion = Get-PiVersion -Path $PiExe
if ($piVersion -ne [string]$manifest.pi.expected_version) {
    throw "Expected Pi $($manifest.pi.expected_version), found $piVersion."
}
$settingsPath = Join-Path $HOME ".pi\agent\settings.json"
if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
    throw "Pi settings are missing: $settingsPath"
}
$settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
if (-not $settings.shellPath -or
    -not (Test-Path -LiteralPath ([string]$settings.shellPath) -PathType Leaf)) {
    throw "Pi shellPath must point to an existing Git Bash executable. See protocol.md."
}
$modelsPath = Join-Path $HOME ".pi\agent\models.json"
if (-not (Test-Path -LiteralPath $modelsPath -PathType Leaf)) {
    throw "Pi model configuration is missing: $modelsPath"
}
$models = Get-Content -LiteralPath $modelsPath -Raw | ConvertFrom-Json
$providerConfig = $models.providers."lum-llm"
if (-not $providerConfig -or
    @($providerConfig.models.id) -notcontains [string]$manifest.pi.model) {
    throw "lum-llm/$($manifest.pi.model) is not configured in Pi models.json."
}
if ([string]$providerConfig.apiKey -ne '$ANTHROPIC_AUTH_TOKEN') {
    throw "lum-llm apiKey must reference ANTHROPIC_AUTH_TOKEN instead of storing a credential."
}

$leaderboard = Join-Path $RepoRoot "mlebench\competitions\$CompetitionId\leaderboard.csv"
if (-not (Test-Path -LiteralPath $leaderboard -PathType Leaf)) {
    throw "Leaderboard threshold file is missing: $leaderboard"
}
$leaderboardFirstLine = Get-Content -LiteralPath $leaderboard -TotalCount 1
if ($leaderboardFirstLine -eq "version https://git-lfs.github.com/spec/v1") {
    throw "Leaderboard is still a Git LFS pointer. Run setup_experiment.ps1 -PullLfs."
}

$timestamp = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssfffZ")
$runRoot = Join-Path $RunsDir "$CompetitionId\$Variant\$timestamp"
$workspace = Join-Path $runRoot "workspace"
$hostLogs = Join-Path $runRoot "host-logs"
New-Item -ItemType Directory -Path $hostLogs -Force | Out-Null

$prepareArgs = @(
    $ExperimentPy, "prepare-workspace",
    "--repo-root", $RepoRoot,
    "--data-dir", $DataDir,
    "--workspace", $workspace,
    "--competition-id", $CompetitionId,
    "--variant", $Variant,
    "--time-limit-hours", ([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0}", $TimeLimitHours)),
    "--seed", [string]$Seed
)
$prepareProcess = Start-Process `
    -FilePath $PythonExe `
    -ArgumentList $prepareArgs `
    -NoNewWindow `
    -Wait `
    -PassThru
if ($prepareProcess.ExitCode -ne 0) {
    throw "Workspace preparation failed."
}

$tracePath = Join-Path $hostLogs "pi-events.jsonl"
$stderrPath = Join-Path $hostLogs "pi-stderr.log"
$killLogPath = Join-Path $hostLogs "timeout-kill.log"
$retryLogPath = Join-Path $hostLogs "pi-attempts.json"
$traceHealthPath = Join-Path $hostLogs "trace-health.json"
$traceHealthStdoutPath = Join-Path $hostLogs "trace-health.stdout.log"
$validationPath = Join-Path $hostLogs "submission-validation.json"
$validationStderrPath = Join-Path $hostLogs "submission-validation.stderr.log"
$auditPath = Join-Path $hostLogs "integrity.json"
$auditStdoutPath = Join-Path $hostLogs "integrity.stdout.log"
$gradePath = Join-Path $hostLogs "grade.json"
$gradeStdoutPath = Join-Path $hostLogs "grade.stdout.log"
$submissionPath = Join-Path $workspace "submission\submission.csv"
$samplePath = Join-Path $workspace "data\sample_submission.csv"
$runJsonPath = Join-Path $runRoot "run.json"

$provider = [string]$manifest.pi.provider
$model = [string]$manifest.pi.model
$piArgs = @(
    "--mode", "json",
    "--no-session",
    "--provider", $provider,
    "--model", $model,
    "--no-extensions",
    "--extension", $RuntimeGuard,
    "--no-skills",
    "--no-prompt-templates",
    "--no-context-files",
    "--no-approve",
    "@task.md"
)
$started = [DateTime]::UtcNow
$initialRun = [ordered]@{
    schema_version = 1
    competition_id = $CompetitionId
    variant = $Variant
    pi = [ordered]@{
        version = $piVersion
        provider = $provider
        model = $model
        arguments = $piArgs
    }
    seed = $Seed
    time_limit_hours = $TimeLimitHours
    resource_limits = $resourceLimits
    reliability = [ordered]@{
        runtime_guard = $RuntimeGuard
        max_pi_attempts = $MaxPiAttempts
        min_retry_seconds = $MinRetrySeconds
        bounded_tool_result_chars = 6000
        proactive_compaction_tokens = 70000
    }
    started_at_utc = $started.ToString("o")
    status = "running"
    workspace = $workspace
}
[IO.File]::WriteAllText(
    $runJsonPath,
    ($initialRun | ConvertTo-Json -Depth 8),
    [Text.UTF8Encoding]::new($false)
)

$env:PYTHONHASHSEED = [string]$Seed
$venvScripts = Split-Path $PythonExe -Parent
$python3Exe = Join-Path $venvScripts "python3.exe"
if (-not (Test-Path -LiteralPath $python3Exe -PathType Leaf)) {
    try {
        New-Item -ItemType HardLink -Path $python3Exe -Target $PythonExe -ErrorAction Stop | Out-Null
    }
    catch {
        Copy-Item -LiteralPath $PythonExe -Destination $python3Exe -Force
    }
}
$env:Path = "$venvScripts;$env:Path"
$timeoutSeconds = [Math]::Max(1, [int][Math]::Ceiling($TimeLimitHours * 3600.0))
$deadline = $started.AddSeconds($timeoutSeconds)
$timedOut = $false
$exitCode = $null
$attempts = @()
$traceHealth = [pscustomobject]@{
    agent_settled = $false
    last_stop_reason = $null
    provider_error = $false
    malformed_tool_call = $false
    retryable_failure = $false
    error = ""
}
[IO.File]::WriteAllText($tracePath, "", [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($stderrPath, "", [Text.UTF8Encoding]::new($false))
$retryPromptPath = Join-Path $workspace "retry.md"
[IO.File]::WriteAllText(
    $retryPromptPath,
    "A prior Pi attempt did not finish cleanly. Continue from the files already present in this workspace. Do not inspect host logs or paths outside the workspace. Diagnose existing code before changing it, keep outputs bounded, preserve any valid submission, and finish only after submission/submission.csv passes the public validator.`n",
    [Text.UTF8Encoding]::new($false)
)

for ($attempt = 1; $attempt -le $MaxPiAttempts; $attempt++) {
    $remainingSeconds = [Math]::Max(0, [int][Math]::Floor(($deadline - [DateTime]::UtcNow).TotalSeconds))
    if ($remainingSeconds -le 0) {
        $timedOut = $true
        break
    }
    $attemptArgs = @($piArgs)
    if ($attempt -gt 1) {
        $attemptArgs += "@retry.md"
    }
    $piCommandValues = @($PiExe) + $attemptArgs
    foreach ($value in $piCommandValues) {
        if ([string]$value -match '[\r\n"%]') {
            throw "Pi executable and arguments may not contain quotes, percent signs, or newlines."
        }
    }
    $piCommand = (@($piCommandValues | ForEach-Object { '"' + [string]$_ + '"' }) -join " ")
    $piCommand += ' 1>>"' + $tracePath + '" 2>>"' + $stderrPath + '"'
    $piShellCommand = '"' + $piCommand + '"'
    $attemptStarted = [DateTime]::UtcNow
    $process = Start-Process `
        -FilePath $env:ComSpec `
        -ArgumentList @("/D", "/S", "/C", $piShellCommand) `
        -WorkingDirectory $workspace `
        -WindowStyle Hidden `
        -PassThru
    try {
        $exited = $process.WaitForExit($remainingSeconds * 1000)
    }
    catch {
        $exited = $false
    }
    $attemptTimedOut = -not $exited
    if ($attemptTimedOut) {
        Start-Process -FilePath "$env:SystemRoot\System32\taskkill.exe" -ArgumentList @("/PID", [string]$process.Id, "/T", "/F") `
            -RedirectStandardOutput $killLogPath -RedirectStandardError "$killLogPath.stderr.log" -NoNewWindow -Wait | Out-Null
        $process.WaitForExit(30000) | Out-Null
    }
    $process.Refresh()
    $exitCode = if ($process.HasExited) { $process.ExitCode } else { $null }

    $healthProcess = Start-Process -FilePath $PythonExe -ArgumentList @(
        $ExperimentPy, "trace-health", "--trace", $tracePath, "--output", $traceHealthPath
    ) -RedirectStandardOutput $traceHealthStdoutPath -NoNewWindow -Wait -PassThru
    if ($healthProcess.ExitCode -eq 0 -and (Test-Path -LiteralPath $traceHealthPath -PathType Leaf)) {
        $traceHealth = Get-Content -LiteralPath $traceHealthPath -Raw | ConvertFrom-Json
    }

    $attemptValidationPath = Join-Path $hostLogs ("attempt-{0}-submission-validation.json" -f $attempt)
    $submissionValid = $false
    if (Test-Path -LiteralPath $submissionPath -PathType Leaf) {
        $attemptValidation = Start-Process -FilePath $PythonExe -ArgumentList @(
            (Join-Path $workspace "validate_submission.py"), $submissionPath, "--sample", $samplePath
        ) -RedirectStandardOutput $attemptValidationPath -NoNewWindow -Wait -PassThru
        $submissionValid = $attemptValidation.ExitCode -eq 0
    }
    $attempts += [pscustomobject]@{
        attempt = $attempt
        started_at_utc = $attemptStarted.ToString("o")
        ended_at_utc = [DateTime]::UtcNow.ToString("o")
        exit_code = $exitCode
        timed_out = $attemptTimedOut
        submission_valid = $submissionValid
        trace_health = $traceHealth
    }
    [IO.File]::WriteAllText(
        $retryLogPath,
        ($attempts | ConvertTo-Json -Depth 8),
        [Text.UTF8Encoding]::new($false)
    )
    if ($attemptTimedOut) {
        $timedOut = $true
        break
    }
    $needsRetry = ($exitCode -ne 0) -or [bool]$traceHealth.retryable_failure -or -not $submissionValid
    $secondsAfterAttempt = [Math]::Max(0, [int][Math]::Floor(($deadline - [DateTime]::UtcNow).TotalSeconds))
    if (-not $needsRetry -or $attempt -ge $MaxPiAttempts -or $secondsAfterAttempt -lt $MinRetrySeconds) {
        break
    }
    Start-Sleep -Seconds ([Math]::Min(30, 5 * $attempt))
}
$ended = [DateTime]::UtcNow

foreach ($logPath in @($tracePath, $stderrPath, $killLogPath)) {
    if (Test-Path -LiteralPath $logPath -PathType Leaf) {
        Start-Process -FilePath $PythonExe -ArgumentList @(
            $ExperimentPy, "redact-file", "--path", $logPath,
            "--environment-name", "ANTHROPIC_AUTH_TOKEN"
        ) -NoNewWindow -Wait | Out-Null
    }
}

$validationProcess = Start-Process `
    -FilePath $PythonExe `
    -ArgumentList @(
        (Join-Path $workspace "validate_submission.py"),
        $submissionPath, "--sample", $samplePath
    ) `
    -RedirectStandardOutput $validationPath `
    -RedirectStandardError $validationStderrPath `
    -NoNewWindow `
    -Wait `
    -PassThru
$validationExitCode = $validationProcess.ExitCode

$auditProcess = Start-Process `
    -FilePath $PythonExe `
    -ArgumentList @(
        $ExperimentPy, "audit", "--trace", $tracePath,
        "--workspace", $workspace, "--output", $auditPath,
        "--expected-provider", $provider, "--expected-model", $model
    ) `
    -RedirectStandardOutput $auditStdoutPath `
    -NoNewWindow `
    -Wait `
    -PassThru
$auditExitCode = $auditProcess.ExitCode

$gradeProcess = Start-Process `
    -FilePath $PythonExe `
    -ArgumentList @(
        $ExperimentPy, "grade", "--repo-root", $RepoRoot,
        "--data-dir", $DataDir, "--competition-id", $CompetitionId,
        "--submission", $submissionPath, "--output", $gradePath
    ) `
    -RedirectStandardOutput $gradeStdoutPath `
    -NoNewWindow `
    -Wait `
    -PassThru
$gradeExitCode = $gradeProcess.ExitCode

$validation = Get-Content -LiteralPath $validationPath -Raw | ConvertFrom-Json
$integrity = Get-Content -LiteralPath $auditPath -Raw | ConvertFrom-Json
$grade = Get-Content -LiteralPath $gradePath -Raw | ConvertFrom-Json

$status = "completed"
if (-not $integrity.clean) {
    $status = "integrity_violation"
} elseif ($timedOut) {
    $status = "timed_out"
} elseif ($exitCode -ne 0) {
    $status = "pi_failed"
} elseif ([bool]$traceHealth.provider_error -or [bool]$traceHealth.malformed_tool_call) {
    $status = "pi_failed"
} elseif (-not $validation.valid -or -not $grade.valid_submission) {
    $status = "invalid_submission"
}

$run = [ordered]@{
    schema_version = 1
    competition_id = $CompetitionId
    variant = $Variant
    pi = [ordered]@{
        version = $piVersion
        provider = $provider
        model = $model
        arguments = $piArgs
    }
    seed = $Seed
    time_limit_hours = $TimeLimitHours
    resource_limits = $resourceLimits
    reliability = [ordered]@{
        runtime_guard = $RuntimeGuard
        max_pi_attempts = $MaxPiAttempts
        min_retry_seconds = $MinRetrySeconds
        attempts = $attempts
        final_trace_health = $traceHealth
    }
    started_at_utc = $started.ToString("o")
    ended_at_utc = $ended.ToString("o")
    duration_seconds = [Math]::Round(($ended - $started).TotalSeconds, 3)
    exit_code = $exitCode
    timed_out = $timedOut
    status = $status
    public_submission_validation = $validation
    integrity = $integrity
    grade = $grade
    finalization_exit_codes = [ordered]@{
        public_validation = $validationExitCode
        integrity_audit = $auditExitCode
        official_grader = $gradeExitCode
    }
    artifacts = [ordered]@{
        workspace = $workspace
        task = (Join-Path $workspace "task.md")
        trace_jsonl = $tracePath
        stderr = $stderrPath
        attempt_log = $retryLogPath
        trace_health = $traceHealthPath
        runtime_guard = $RuntimeGuard
        code = (Join-Path $workspace "code")
        submission = $submissionPath
        public_validation = $validationPath
        grade = $gradePath
        integrity = $auditPath
    }
}
[IO.File]::WriteAllText(
    $runJsonPath,
    ($run | ConvertTo-Json -Depth 12),
    [Text.UTF8Encoding]::new($false)
)
$run | ConvertTo-Json -Depth 12

if ($status -ne "completed") {
    exit 2
}
