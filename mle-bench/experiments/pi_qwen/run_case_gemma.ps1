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
    [string]$RepoRoot,
    [string]$DataDir,
    [string]$RunsDir,
    [string]$PythonExe,
    [string]$PiExe,
    [string]$PolicyAddendum
)

# Verbatim copy of run_case.ps1, with exactly one change: reads
# candidates_gemma.json instead of candidates.json, so it picks up
# nvidia/Gemma-4-26B-A4B-NVFP4 (262144 context) instead of qwen3.6-27b.
# Uses the ORIGINAL, unpatched pi.exe by default (PiExe defaults to
# ..\pi\pi.exe, same as run_case.ps1) -- extensions stay disabled, matching
# the real baseline protocol. Writes runs under runs\pi-qwen-gemma\ (via
# -RunsDir at call time) so this never collides with the qwen runs.

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
    $RunsDir = Join-Path $RepoRoot "runs\pi-qwen"
}
if (-not $PythonExe) {
    $PythonExe = Join-Path $RepoRoot ".venv\Scripts\python.exe"
}
if (-not $PiExe) {
    $PiExe = Join-Path (Split-Path $RepoRoot -Parent) "pi\pi.exe"
}

$ManifestPath = Join-Path $PSScriptRoot "candidates_gemma.json"
$ExperimentPy = Join-Path $PSScriptRoot "experiment.py"
. (Join-Path $PSScriptRoot "process_control.ps1")
$resourceLimits = Set-ExperimentResourceLimits -MaxCpuThreads $MaxCpuThreads

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
if ($CompetitionId -eq $smokeId -and $TimeLimitHours -gt (10.0 / 60.0 + 0.0001)) {
    throw "The smoke run must be limited to 10 minutes or less."
}
if (-not (Test-Path -LiteralPath $PythonExe -PathType Leaf)) {
    throw "Experiment Python is missing: $PythonExe"
}
if (-not (Test-Path -LiteralPath $PiExe -PathType Leaf)) {
    throw "Pi executable is missing: $PiExe"
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

if ($Variant -eq "policy_v1" -and -not $PolicyAddendum) {
    $PolicyAddendum = Join-Path $RunsDir "policy_addendum.md"
}
if ($Variant -eq "policy_v1" -and
    -not (Test-Path -LiteralPath $PolicyAddendum -PathType Leaf)) {
    throw "Policy addendum is missing. Complete baseline review and selection first: $PolicyAddendum"
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
if ($Variant -eq "policy_v1") {
    $prepareArgs += @("--policy-addendum", $PolicyAddendum)
}
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
$env:Path = "$venvScripts;$env:Path"

# Windows PowerShell 5.1 can report a null ExitCode for Start-Process when its redirect
# parameters are used. Let cmd.exe perform byte-for-byte redirection instead, so the wrapper's
# numeric exit code remains available while taskkill /T can still terminate the complete tree.
$piCommandValues = @($PiExe) + $piArgs
foreach ($value in $piCommandValues) {
    if ([string]$value -match '[\r\n"%]') {
        throw "Pi executable and arguments may not contain quotes, percent signs, or newlines."
    }
}
$piCommand = (@($piCommandValues | ForEach-Object { '"' + [string]$_ + '"' }) -join " ")
$piCommand += ' 1>"' + $tracePath + '" 2>"' + $stderrPath + '"'
$piShellCommand = '"' + $piCommand + '"'
$process = Start-Process `
    -FilePath $env:ComSpec `
    -ArgumentList @("/D", "/S", "/C", $piShellCommand) `
    -WorkingDirectory $workspace `
    -WindowStyle Hidden `
    -PassThru

$timeoutSeconds = [Math]::Max(1, [int][Math]::Ceiling($TimeLimitHours * 3600.0))
$waitResult = Wait-ExperimentProcess `
    -Process $process `
    -TimeoutSeconds $timeoutSeconds `
    -KillLogPath $killLogPath
$timedOut = [bool]$waitResult.timed_out
$exitCode = $waitResult.exit_code
$ended = [DateTime]::UtcNow

# The prompt forbids reading credentials. Redact the inherited token defensively if it was ever
# echoed by a child command, without printing it to the console.
foreach ($logPath in @($tracePath, $stderrPath, $killLogPath)) {
    if (Test-Path -LiteralPath $logPath -PathType Leaf) {
        $logText = [IO.File]::ReadAllText($logPath)
        if (-not [string]::IsNullOrEmpty($env:ANTHROPIC_AUTH_TOKEN)) {
            $logText = $logText.Replace($env:ANTHROPIC_AUTH_TOKEN, "<redacted>")
        }
        [IO.File]::WriteAllText($logPath, $logText, [Text.UTF8Encoding]::new($false))
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
