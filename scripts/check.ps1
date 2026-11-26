# Runs every check in one go: on the laptop, in the pre-push hook and in the pipeline.
# Works in Windows PowerShell 5.1 and PowerShell 7 (Linux). Needs terraform, tflint, git and Python 3.14.
# No AWS login, and nothing is created: the Terraform tests use a mocked provider.
#
#   .\scripts\check.ps1                 all checks
#   .\scripts\check.ps1 -PrivateOnly    only the private-data scan (a few seconds)

param([switch]$PrivateOnly)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$script:results = @()

# Runs a program, keeps its output and returns $true when it exited with 0
function Invoke-Tool {
    param([string]$Exe, [string[]]$Arguments)
    $script:output = & $Exe @Arguments 2>&1 | ForEach-Object { "$_" }
    return ($LASTEXITCODE -eq 0)
}

function Add-Result {
    param([string]$Name, [bool]$Passed, [string[]]$Details)
    $script:results += [pscustomobject]@{ Check = $Name; Passed = $Passed }
    if ($Passed) { Write-Host "  ok    $Name" }
    else {
        Write-Host "  FAIL  $Name"
        $Details | ForEach-Object { Write-Host "        $_" }
    }
}

# -----------------------------------------------------------------------------
# Private data: the repository is public. Matches are reported by place and rule
# only; the value itself is never printed, because pipeline logs are public too.
# -----------------------------------------------------------------------------

function Get-LocalSecrets {
    # Real values from the git-ignored files on this machine (none of them exist in the pipeline)
    $values = @()
    $files = @(Get-ChildItem terraform -Recurse -File -Include '*.tfvars', 'backend.hcl' -ErrorAction SilentlyContinue)
    foreach ($file in $files) {
        foreach ($line in (Get-Content $file.FullName)) {
            if ($line -match '^\s*#') { continue }
            foreach ($m in [regex]::Matches($line, '"([^"]+)"')) {
                $value = $m.Groups[1].Value
                # only values that are private: emails, IP addresses, the state bucket
                if ($value -match '@') { $values += $value }
                elseif ($value -match '^(\d+\.\d+\.\d+\.\d+)(/\d+)?$') { $values += $Matches[1] }
                elseif ($value -match '-tfstate-') { $values += $value }
            }
        }
    }
    # Further private terms, one per line, in a file that is never committed
    $extra = Join-Path $PSScriptRoot 'private-terms.local.txt'
    if (Test-Path $extra) {
        $values += Get-Content $extra | Where-Object { $_.Trim() -and $_ -notmatch '^\s*#' } | ForEach-Object { $_.Trim() }
    }
    return @($values | Sort-Object -Unique)
}

$rules = @(
    @{ Name = 'AWS account ID'; Pattern = '\b\d{12}\b'; Allow = '^(123456789012|111122223333)$' }
    @{ Name = 'AWS access key'; Pattern = '\b(AKIA|ASIA)[A-Z0-9]{16}\b' }
    @{ Name = 'private key'; Pattern = '-----BEGIN [A-Z ]*PRIVATE KEY' }
    @{ Name = 'GitHub token'; Pattern = '\b(gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{20,})' }
    @{ Name = 'home network address'; Pattern = '\b192\.168\.\d+\.\d+\b' }
    @{ Name = 'email address'; Pattern = '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}'; Allow = '(@example\.com|@users\.noreply\.github\.com|^git@github\.com)$' }
    @{ Name = 'local user path'; Pattern = '[A-Za-z]:\\Users\\' }
)

function Find-PrivateData {
    param([string]$Text, [string[]]$LocalSecrets)
    $found = @()
    foreach ($rule in $rules) {
        foreach ($m in [regex]::Matches($Text, $rule.Pattern)) {
            if ($rule.Allow -and $m.Value -match $rule.Allow) { continue }
            $found += $rule.Name
        }
    }
    foreach ($value in $LocalSecrets) {
        if ($Text.IndexOf($value, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $found += 'value from a local private file' }
    }
    return @($found | Sort-Object -Unique)
}

function Test-PrivateData {
    $hits = @()
    $localSecrets = @(Get-LocalSecrets)

    # 1. every file that is tracked or would be committed
    foreach ($file in @(git ls-files -co --exclude-standard)) {
        if (-not (Test-Path -LiteralPath $file)) { continue }
        $number = 0
        foreach ($line in [IO.File]::ReadAllLines((Join-Path $root $file))) {
            $number++
            foreach ($name in (Find-PrivateData $line $localSecrets)) { $hits += "${file}:${number}  $name" }
        }
    }

    # 2. every commit that has not been pushed: a value added in one commit and removed
    #    in the next would still become public
    git rev-parse --verify --quiet origin/main | Out-Null
    if ($LASTEXITCODE -eq 0) {
        foreach ($commit in @(git rev-list origin/main..HEAD)) {
            $short = $commit.Substring(0, 7)
            foreach ($line in @(git show --format=%B --unified=0 --no-color $commit)) {
                # without the diff's own + or -, which would turn a Python decorator into something like an email address
                foreach ($name in (Find-PrivateData ($line -replace '^[+-]', '') $localSecrets)) { $hits += "commit $short  $name" }
            }
            foreach ($email in @(git show -s --format='%ae%n%ce' $commit)) {
                if ($email -notmatch '@users\.noreply\.github\.com$') { $hits += "commit $short  author email is not the noreply address" }
            }
        }
    }

    Add-Result 'private data' ($hits.Count -eq 0) @($hits | Sort-Object -Unique)
}

# -----------------------------------------------------------------------------
# Terraform: format, then every module and stack
# -----------------------------------------------------------------------------

function Test-Terraform {
    $ok = Invoke-Tool 'terraform' @('fmt', '-check', '-recursive', 'terraform')
    Add-Result 'terraform fmt' $ok $script:output

    $folders = @(Get-ChildItem terraform/modules -Directory) + @(Get-ChildItem terraform/live -Directory)
    foreach ($folder in $folders) {
        $name = "$($folder.Parent.Name)/$($folder.Name)"
        $dir = "-chdir=$($folder.FullName)"

        # A stack that is already initialised keeps its S3 backend settings untouched
        if (-not (Test-Path (Join-Path $folder.FullName '.terraform'))) {
            $ok = Invoke-Tool 'terraform' @($dir, 'init', '-backend=false', '-input=false', '-no-color')
            if (-not $ok) { Add-Result "$name init" $false $script:output; continue }
        }
        elseif ($folder.Parent.Name -eq 'modules') {
            $ok = Invoke-Tool 'terraform' @($dir, 'init', '-backend=false', '-input=false', '-no-color')
            if (-not $ok) { Add-Result "$name init" $false $script:output; continue }
        }

        $ok = Invoke-Tool 'terraform' @($dir, 'validate', '-no-color')
        Add-Result "$name validate" $ok $script:output

        $ok = Invoke-Tool 'tflint' @("--chdir=$($folder.FullName)")
        Add-Result "$name tflint" $ok $script:output

        if ($folder.Parent.Name -eq 'modules') {
            $tests = @(Get-ChildItem (Join-Path $folder.FullName 'tests') -Filter '*.tftest.hcl' -ErrorAction SilentlyContinue)
            if ($tests.Count -eq 0) {
                Add-Result "$name tests" $false @('This module has no tests (tests/*.tftest.hcl). Every module needs them.')
                continue
            }
            $ok = Invoke-Tool 'terraform' @($dir, 'test', '-no-color')
            $summary = @($script:output | Where-Object { $_ -match 'passed, \d+ failed' })
            Add-Result "$name tests  $summary" $ok $script:output
        }
    }
}

# -----------------------------------------------------------------------------
# App: lint, format and the tests that need no database (the others run in the
# pipeline, against a real PostgreSQL). The libraries are installed into app/.venv.
# -----------------------------------------------------------------------------

function Test-App {
    $venv = Join-Path $root 'app/.venv'
    $stamp = Join-Path $venv 'requirements.sha256'
    $wanted = @('app/requirements.txt', 'app/requirements-dev.txt' | ForEach-Object { (Get-FileHash $_ -Algorithm SHA256).Hash }) -join ' '
    $python = @('Scripts/python.exe', 'bin/python' | ForEach-Object { Join-Path $venv $_ }) | Where-Object { Test-Path $_ } | Select-Object -First 1

    if (-not $python -or -not (Test-Path $stamp) -or (Get-Content $stamp -Raw).Trim() -ne $wanted) {
        $system = @('python3', 'python' | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue }) | Select-Object -Last 1
        if (-not $python) {
            $ok = Invoke-Tool $system @('-m', 'venv', $venv)
            if (-not $ok) { Add-Result 'app environment' $false $script:output; return }
            $python = @('Scripts/python.exe', 'bin/python' | ForEach-Object { Join-Path $venv $_ }) | Where-Object { Test-Path $_ } | Select-Object -First 1
        }
        $ok = Invoke-Tool $python @('-m', 'pip', 'install', '-q', '--disable-pip-version-check', '--require-hashes', '-r', 'app/requirements.txt', '-r', 'app/requirements-dev.txt')
        if (-not $ok) { Add-Result 'app environment' $false $script:output; return }
        Set-Content -Path $stamp -Value $wanted -Encoding ascii
    }

    $ok = Invoke-Tool $python @('-m', 'ruff', 'check', 'app')
    Add-Result 'app lint' $ok $script:output
    $ok = Invoke-Tool $python @('-m', 'ruff', 'format', '--check', 'app')
    Add-Result 'app format' $ok $script:output
    $ok = Invoke-Tool $python @('-m', 'pytest', '-c', 'app/pyproject.toml', '--rootdir', 'app', '-p', 'no:cacheprovider', 'app/tests/unit')
    $summary = @($script:output | Where-Object { $_ -match '\d+ (passed|failed|error)' }) | Select-Object -Last 1
    Add-Result "app tests without database  $summary" $ok $script:output

    $ok = Invoke-Tool $python @('-m', 'pytest', '-q', '-p', 'no:cacheprovider', '--rootdir', 'scripts', 'scripts/tests')
    $summary = @($script:output | Where-Object { $_ -match '\d+ (passed|failed|error)' }) | Select-Object -Last 1
    Add-Result "log filter tests  $summary" $ok $script:output
}

Write-Host 'Checks:'
Test-PrivateData
if (-not $PrivateOnly) { Test-Terraform; Test-App }

$failed = @($script:results | Where-Object { -not $_.Passed })
Write-Host ''
if ($failed.Count -gt 0) {
    Write-Host "$($failed.Count) of $($script:results.Count) checks failed."
    exit 1
}
Write-Host "All $($script:results.Count) checks passed."
exit 0
