<#
Opens an SSM tunnel to the app, the database or Grafana, and keeps it open until Ctrl+C (or 60 minutes without traffic).

    scripts\tunnel.ps1 app          the app on http://localhost:8000
    scripts\tunnel.ps1 db           PostgreSQL on localhost:15432
    scripts\tunnel.ps1 grafana      Grafana on http://localhost:3000 (the monitoring server)
    scripts\tunnel.ps1 db -DryRun   only check and show what it would open

Needs two environment variables with AWS profile names (they are private, so they are not in this file):
    DATASITE_ADMIN_PROFILE    your login: looks up the server and the database
    DATASITE_TUNNEL_PROFILE   the operator role: opens the session (only from the company network)
Works in Windows PowerShell 5.1 and PowerShell 7.
#>
param(
    [Parameter(Mandatory = $true, Position = 0)][ValidateSet('app', 'db', 'grafana')][string]$Target,
    [int]$LocalPort = 0,
    [switch]$DryRun
)

$region = if ($env:AWS_REGION) { $env:AWS_REGION } else { 'eu-north-1' }
# A terminal opened before the variables were set doesn't have them yet: then read them from the user's settings
$adminProfile = if ($env:DATASITE_ADMIN_PROFILE) { $env:DATASITE_ADMIN_PROFILE } else { [Environment]::GetEnvironmentVariable('DATASITE_ADMIN_PROFILE', 'User') }
$tunnelProfile = if ($env:DATASITE_TUNNEL_PROFILE) { $env:DATASITE_TUNNEL_PROFILE } else { [Environment]::GetEnvironmentVariable('DATASITE_TUNNEL_PROFILE', 'User') }
if (-not $adminProfile -or -not $tunnelProfile) {
    Write-Host 'Set the two profile names once (they stay on this computer), then open a new terminal:'
    Write-Host "    [Environment]::SetEnvironmentVariable('DATASITE_ADMIN_PROFILE', '<your login profile>', 'User')"
    Write-Host "    [Environment]::SetEnvironmentVariable('DATASITE_TUNNEL_PROFILE', '<operator profile>', 'User')"
    exit 2
}
# Port on the server, the default port on this computer, and the server the session goes to
$remotePort = @{ app = 8000; db = 5432; grafana = 3000 }[$Target]
if ($LocalPort -eq 0) { $LocalPort = @{ app = 8000; db = 15432; grafana = 3000 }[$Target] }
$serverName = if ($Target -eq 'grafana') { 'aws-datasite-obs' } else { 'aws-datasite-app' }
$serverText = if ($Target -eq 'grafana') { 'monitoring server' } else { 'app server' }

# Runs the AWS CLI with the admin profile and returns its text output, or stops with a message
function Get-AwsText {
    param([string[]]$Arguments, [string]$Problem)
    $output = & aws @Arguments --profile $adminProfile --region $region --output text
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: $Problem"
        exit 1
    }
    return ($output | Out-String).Trim()
}

Get-AwsText @('sts', 'get-caller-identity', '--query', 'Arn') "the login has expired: aws login --profile $adminProfile" | Out-Null

$instance = Get-AwsText @(
    'ec2', 'describe-instances',
    '--filters', "Name=tag:Name,Values=$serverName", 'Name=instance-state-name,Values=running',
    '--query', 'Reservations[0].Instances[0].InstanceId'
) "the $serverText could not be looked up"
if ($instance -notmatch '^i-[0-9a-f]+$') {
    Write-Host "The $serverText is not running (weekdays 07:00-19:00 Berlin time)."
    exit 3
}

# The port on this computer must be free: often a tunnel is open already
$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $LocalPort)
try { $listener.Start(); $listener.Stop() }
catch {
    Write-Host "Port $LocalPort on this computer is in use: is a tunnel open already? Or choose another one with -LocalPort."
    exit 4
}

if ($Target -ne 'db') {
    $session = @(
        'ssm', 'start-session', '--target', $instance,
        '--document-name', 'AWS-StartPortForwardingSession',
        '--parameters', "portNumber=$remotePort,localPortNumber=$LocalPort"
    )
    $where = if ($Target -eq 'app') { "the app: http://localhost:$LocalPort  (try /health and /docs)" } else { "Grafana: http://localhost:$LocalPort" }
}
else {
    $database = Get-AwsText @(
        'rds', 'describe-db-instances', '--db-instance-identifier', 'aws-datasite-db',
        '--query', 'DBInstances[0].[DBInstanceStatus,Endpoint.Address]'
    ) 'the database could not be looked up'
    $status, $address = $database -split '\s+'
    if ($status -ne 'available') {
        Write-Host "The database is '$status', not available (it runs on weekdays 07:00-19:00 Berlin time)."
        exit 3
    }
    $session = @(
        'ssm', 'start-session', '--target', $instance,
        '--document-name', 'AWS-StartPortForwardingSessionToRemoteHost',
        '--parameters', "host=$address,portNumber=5432,localPortNumber=$LocalPort"
    )
    $where = "PostgreSQL: localhost:$LocalPort  (PGHOST=localhost, PGPORT=$LocalPort, PGSSLMODE=require)"
}

if ($DryRun) {
    Write-Host "Checks passed. It would open $where"
    Write-Host "through the $serverText, with the profile in DATASITE_TUNNEL_PROFILE."
    exit 0
}
Write-Host "Opening $where"
Write-Host 'Keep this window open; Ctrl+C closes the tunnel. It also closes after 60 minutes without traffic.'
& aws @session --profile $tunnelProfile --region $region
exit $LASTEXITCODE
