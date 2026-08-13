[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$DataDir,
    [string]$VenvDir,
    [string]$KaggleVenvDir,
    [string]$PiExe,
    [switch]$InstallDependencies,
    [switch]$PullLfs,
    [switch]$PrepareData,
    [switch]$RulesAccepted
)

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
if (-not $VenvDir) {
    $VenvDir = Join-Path $RepoRoot ".venv"
}
if (-not $KaggleVenvDir) {
    $KaggleVenvDir = Join-Path $RepoRoot ".venv-kaggle"
}
if (-not $PiExe) {
    $PiExe = Join-Path (Split-Path $RepoRoot -Parent) "pi\pi.exe"
}

$ManifestPath = Join-Path $PSScriptRoot "candidates.json"
$ExperimentPy = Join-Path $PSScriptRoot "experiment.py"
$VenvPython = Join-Path $VenvDir "Scripts\python.exe"
$KagglePython = Join-Path $KaggleVenvDir "Scripts\python.exe"
$KaggleExe = Join-Path $KaggleVenvDir "Scripts\kaggle.exe"
$GitExe = "D:\Git\cmd\git.exe"

function Invoke-BootstrapPython {
    param([string[]]$Arguments)
    $launcher = Get-Command py.exe -ErrorAction SilentlyContinue
    if (-not $launcher) {
        throw "py.exe was not found. Install 64-bit Python 3.11 or newer."
    }
    $process = Start-Process `
        -FilePath $launcher.Source `
        -ArgumentList (@("-3.11") + $Arguments) `
        -NoNewWindow `
        -Wait `
        -PassThru
    if ($process.ExitCode -ne 0) {
        throw "Python bootstrap command failed with exit code $($process.ExitCode)."
    }
}

function Invoke-CheckedProcess {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$FailureMessage
    )
    $process = Start-Process `
        -FilePath $FilePath `
        -ArgumentList $Arguments `
        -NoNewWindow `
        -Wait `
        -PassThru
    if ($process.ExitCode -ne 0) {
        throw "$FailureMessage Exit code: $($process.ExitCode)."
    }
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

if ($PullLfs) {
    if (-not (Test-Path -LiteralPath $GitExe -PathType Leaf)) {
        $gitCommand = Get-Command git.exe -ErrorAction SilentlyContinue
        if (-not $gitCommand) {
            throw "Git for Windows is missing. Install Git and Git LFS before continuing."
        }
        $GitExe = $gitCommand.Source
    }
    $env:Path = "$(Split-Path $GitExe -Parent);$env:Path"
    Invoke-CheckedProcess -FilePath $GitExe -Arguments @("lfs", "version") `
        -FailureMessage "Git LFS is missing. Install it (for example: winget install GitHub.GitLFS)."
    Invoke-CheckedProcess -FilePath $GitExe -Arguments @("-C", $RepoRoot, "lfs", "install", "--local") `
        -FailureMessage "git lfs install failed."

    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    $ids = @($manifest.smoke.competition_id) + @($manifest.candidates.competition_id)
    $includes = @("experiments/competition_categories.csv")
    foreach ($competitionId in $ids) {
        $includes += "mlebench/competitions/$competitionId/leaderboard.csv"
    }
    Invoke-CheckedProcess -FilePath $GitExe `
        -Arguments @(
            "-C", $RepoRoot, "lfs", "pull",
            ("--include=" + ($includes -join ",")), "--exclude="
        ) `
        -FailureMessage "Selective Git LFS pull failed."
}

if ($InstallDependencies) {
    if (-not (Test-Path -LiteralPath $VenvPython -PathType Leaf)) {
        Invoke-BootstrapPython -Arguments @("-m", "venv", $VenvDir)
    }
    Invoke-CheckedProcess -FilePath $VenvPython `
        -Arguments @("-m", "pip", "install", "--upgrade", "pip") `
        -FailureMessage "pip upgrade failed."
    Invoke-CheckedProcess -FilePath $VenvPython `
        -Arguments @("-m", "pip", "install", "-e", $RepoRoot) `
        -FailureMessage "MLE-bench editable installation failed."
    # MLE-bench 1.0 preparers/graders still call DataFrame.applymap, removed in pandas 3.
    Invoke-CheckedProcess -FilePath $VenvPython `
        -Arguments @("-m", "pip", "install", "pandas==2.2.3") `
        -FailureMessage "Installing the MLE-bench-compatible pandas version failed."
    if (-not (Test-Path -LiteralPath $KagglePython -PathType Leaf)) {
        Invoke-BootstrapPython -Arguments @("-m", "venv", $KaggleVenvDir)
    }
    Invoke-CheckedProcess -FilePath $KagglePython `
        -Arguments @("-m", "pip", "install", "--upgrade", "kaggle==2.2.4") `
        -FailureMessage "Modern Kaggle CLI installation failed."
}

if ($PrepareData) {
    if (-not $RulesAccepted) {
        throw "Open Kaggle in a browser, accept the rules for the six candidates and spaceship-titanic, then rerun with -RulesAccepted."
    }
    $KaggleLegacyCredential = Join-Path $HOME ".kaggle\kaggle.json"
    $KaggleAccessToken = Join-Path $HOME ".kaggle\access_token"
    if (-not (Test-Path -LiteralPath $KaggleLegacyCredential -PathType Leaf) -and
        -not (Test-Path -LiteralPath $KaggleAccessToken -PathType Leaf)) {
        throw "Kaggle credentials are missing. Configure .kaggle\access_token or legacy kaggle.json; neither is copied into the repository."
    }
    if (-not (Test-Path -LiteralPath $VenvPython -PathType Leaf)) {
        throw "The experiment virtual environment is missing. Run with -InstallDependencies first."
    }
    if (-not (Test-Path -LiteralPath $KaggleExe -PathType Leaf)) {
        throw "The modern Kaggle CLI environment is missing. Run with -InstallDependencies first."
    }
    New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    $ids = @([string]$manifest.smoke.competition_id) + @($manifest.candidates.competition_id)
    foreach ($competitionId in $ids) {
        $competitionDir = Join-Path $DataDir $competitionId
        New-Item -ItemType Directory -Path $competitionDir -Force | Out-Null
        $archive = Join-Path $competitionDir "$competitionId.zip"
        if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) {
            Invoke-CheckedProcess -FilePath $KaggleExe `
                -Arguments @("competitions", "download", $competitionId, "--path", $competitionDir) `
                -FailureMessage "Downloading $competitionId failed. Confirm that its Kaggle rules were accepted."
        }
        Invoke-CheckedProcess -FilePath $VenvPython `
            -Arguments @(
                $ExperimentPy, "prepare-archive", "--repo-root", $RepoRoot,
                "--data-dir", $DataDir, "--competition-id", $competitionId,
                "--archive", $archive
            ) `
            -FailureMessage "MLE-bench preparation/checksum verification failed for $competitionId."
    }
}

$checks = [ordered]@{}
$checks.git_lfs = $false
if (Test-Path -LiteralPath $GitExe -PathType Leaf) {
    $gitCheck = Start-Process -FilePath $GitExe -ArgumentList @("lfs", "version") `
        -WindowStyle Hidden -Wait -PassThru
    $checks.git_lfs = ($gitCheck.ExitCode -eq 0)
}
$checks.kaggle_credentials = (
    (Test-Path -LiteralPath (Join-Path $HOME ".kaggle\access_token") -PathType Leaf) -or
    (Test-Path -LiteralPath (Join-Path $HOME ".kaggle\kaggle.json") -PathType Leaf)
)
$checks.modern_kaggle_cli = Test-Path -LiteralPath $KaggleExe -PathType Leaf
$checks.anthropic_auth_token_in_session = (
    (Test-Path Env:\ANTHROPIC_AUTH_TOKEN) -and
    -not [string]::IsNullOrWhiteSpace($env:ANTHROPIC_AUTH_TOKEN)
)
$checks.pi_shell = $false
$settingsPath = Join-Path $HOME ".pi\agent\settings.json"
if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
    $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    if ($settings.shellPath) {
        $checks.pi_shell = Test-Path -LiteralPath ([string]$settings.shellPath) -PathType Leaf
    }
}
$checks.pi_model = $false
$modelsPath = Join-Path $HOME ".pi\agent\models.json"
if (Test-Path -LiteralPath $modelsPath -PathType Leaf) {
    $models = Get-Content -LiteralPath $modelsPath -Raw | ConvertFrom-Json
    $provider = $models.providers."lum-llm"
    if ($provider) {
        $checks.pi_model = @($provider.models.id) -contains "qwen3.6-27b"
    }
}
$checks.pi_version = $false
if (Test-Path -LiteralPath $PiExe -PathType Leaf) {
    $checks.pi_version = ((Get-PiVersion -Path $PiExe) -eq "0.84.1")
}
$checks.venv_python = Test-Path -LiteralPath $VenvPython -PathType Leaf
$checks.compatible_pandas = $false
if ($checks.venv_python) {
    $pandasCheck = Start-Process `
        -FilePath $VenvPython `
        -ArgumentList @("-c", "import pandas as pd; raise SystemExit(0 if hasattr(pd.DataFrame, 'applymap') else 1)") `
        -NoNewWindow `
        -Wait `
        -PassThru
    $checks.compatible_pandas = ($pandasCheck.ExitCode -eq 0)
}

$preflightPython = if ($checks.venv_python) { $VenvPython } else { $null }
if ($preflightPython) {
    $preflightProcess = Start-Process `
        -FilePath $preflightPython `
        -ArgumentList @(
            $ExperimentPy, "preflight",
            "--repo-root", $RepoRoot,
            "--data-dir", $DataDir,
            "--pi-exe", $PiExe,
            "--manifest", $ManifestPath
        ) `
        -NoNewWindow `
        -Wait `
        -PassThru
    $checks.repository_data_preflight = ($preflightProcess.ExitCode -eq 0)
} else {
    $checks.repository_data_preflight = $false
}

$ready = -not ($checks.Values -contains $false)
[pscustomobject]@{
    ready = $ready
    repo_root = $RepoRoot
    data_dir = $DataDir
    checks = $checks
} | ConvertTo-Json -Depth 5

if (-not $ready) {
    exit 2
}
