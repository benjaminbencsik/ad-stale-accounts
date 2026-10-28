<#PSScriptInfo
.VERSION 1.0.0
.GUID 7c1d4f5e-3a9b-4b8e-9f2a-6d0e8c5b1a42
.AUTHOR Ben Bencsik
.COPYRIGHT (c) 2026 Ben Bencsik. MIT License.
.TAGS ActiveDirectory AD StaleAccounts InactiveUsers InactiveComputers Cleanup Audit Security Sysadmin LastLogon
.LICENSEURI https://github.com/benjaminbencsik/ad-stale-accounts/blob/main/LICENSE
.PROJECTURI https://github.com/benjaminbencsik/ad-stale-accounts
.RELEASENOTES Initial release.
#>

<#
.SYNOPSIS
    Finds stale (inactive) user and computer accounts in Active Directory and exports them to CSV.

.DESCRIPTION
    Lists enabled AD users and computers that have not logged on in -Days days, or have never
    logged on. Accounts created within the threshold are skipped, so new hires and freshly
    imaged machines are not flagged.

    This script is read-only: it never changes anything in Active Directory.

    Want an HTML audit report, 8 more security checks (Kerberoastable accounts, password never
    expires, privileged group members...) and safe, reversible disable/quarantine?
    See the AD Hygiene Toolkit: https://payhip.com/b/mfHrx

.PARAMETER Days
    Days without a logon before an account counts as stale. Default 90.

.PARAMETER Type
    User, Computer or Both. Default Both.

.PARAMETER SearchBase
    Limit the search to one OU (distinguished name).

.PARAMETER Server
    Domain controller or domain to query.

.PARAMETER ExcludeSamAccountName
    Accounts to ignore (wildcards allowed), e.g. 'svc_*'.

.PARAMETER CsvPath
    Optional path for a CSV export.

.EXAMPLE
    .\Find-StaleADAccounts.ps1
    Lists users and computers inactive for 90+ days.

.EXAMPLE
    .\Find-StaleADAccounts.ps1 -Days 180 -Type User -SearchBase 'OU=Staff,DC=corp,DC=local' -CsvPath .\stale-users.csv

.LINK
    https://github.com/benjaminbencsik/ad-stale-accounts
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 3650)][int]$Days = 90,
    [ValidateSet('User', 'Computer', 'Both')][string]$Type = 'Both',
    [string]$SearchBase,
    [string]$Server,
    [string[]]$ExcludeSamAccountName = @('krbtgt', 'Guest', 'DefaultAccount', 'WDAGUtilityAccount'),
    [string]$CsvPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (-not (Get-Command -Name Get-ADUser -ErrorAction SilentlyContinue)) {
    try { Import-Module ActiveDirectory -ErrorAction Stop }
    catch { throw "The ActiveDirectory module is required. Install RSAT: Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0" }
}

$cutoff = (Get-Date).AddDays(-$Days)
$params = @{ Filter = 'Enabled -eq $true'; Properties = 'LastLogonDate', 'whenCreated', 'DistinguishedName', 'SamAccountName', 'Name', 'Enabled' }
if ($SearchBase) { $params.SearchBase = $SearchBase }
if ($Server)     { $params.Server = $Server }

function Test-Excluded([string]$Sam) {
    foreach ($p in $ExcludeSamAccountName) { if ($Sam -like $p) { return $true } }
    return $false
}

$objects = @()
if ($Type -in 'User', 'Both')     { $objects += @(Get-ADUser @params     | ForEach-Object { $_ | Add-Member -Force -NotePropertyName ObjectType -NotePropertyValue 'User' -PassThru }) }
if ($Type -in 'Computer', 'Both') { $objects += @(Get-ADComputer @params | ForEach-Object { $_ | Add-Member -Force -NotePropertyName ObjectType -NotePropertyValue 'Computer' -PassThru }) }

$stale = @($objects | Where-Object {
        $_.Enabled -and -not (Test-Excluded $_.SamAccountName) -and
        $_.whenCreated -lt $cutoff -and
        ($null -eq $_.LastLogonDate -or $_.LastLogonDate -lt $cutoff)
    } | Sort-Object LastLogonDate | ForEach-Object {
        [pscustomobject]@{
            Type              = $_.ObjectType
            Name              = $_.Name
            SamAccountName    = $_.SamAccountName
            LastLogon         = if ($_.LastLogonDate) { $_.LastLogonDate.ToString('yyyy-MM-dd') } else { 'Never' }
            DaysInactive      = if ($_.LastLogonDate) { [int]((Get-Date) - $_.LastLogonDate).TotalDays } else { $null }
            Created           = $_.whenCreated.ToString('yyyy-MM-dd')
            DistinguishedName = $_.DistinguishedName
        }
    })

if ($CsvPath) {
    $stale | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
    Write-Host "Exported $($stale.Count) stale accounts to $CsvPath" -ForegroundColor Green
}

Write-Host ("Found {0} stale account(s) inactive for {1}+ days." -f $stale.Count, $Days)
Write-Host 'Need an HTML report, 8 more security checks and reversible cleanup? https://payhip.com/b/mfHrx' -ForegroundColor Cyan
$stale
