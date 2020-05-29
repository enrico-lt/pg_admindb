<#
.SYNOPSIS
    Create Scheduled Task for Synchronisation of AD Groups with PostgreSQL 
.DESCRIPTION
    Must be executed in NT SYSTEM security context.

    Requires PostgreSQL Powershell library.
.NOTES
    Author:			Enrico La Torre
    Date:			  2020-01-14
#>

$lastchange="2020-05-29"

################################################################################
########################### CONFIGURATION PARAMETERS ###########################
################################################################################

# User that executes the Scheduled Task
$User = "DOMAIN\USER"
$useronly = "USER"
$password = "xxx"

# Scheduled Task parameter
$filepath = "E:\pg_admindb\pg_ad_sync\pg_ad_sync_tool.ps1"
$ArgumentList = ''
$Executable = $filepath + $ArgumentList 
$TaskName = "PG_ADSync"
$description = "Synchronise Active Directory groups with PostgreSQL"

# Directory for log file
$logpath = "E:\pg_admindb\logs\installation"

# PowerShell library for PostgreSQL
$libname = "E:\pg_admindb\lib\powershell_postgresql_lib.psd1"

# Import PostgreSQL Powershell library
try {
    Import-Module -Name $libname -Force
    $lib = Get-Module -ListAvailable $libname
} catch {
    Throw "ERROR`t Cannot import powershell library '$libname'"
}

# Set log file name
$script:logfile = ''
$scriptName = $MyInvocation.MyCommand.Name
$scriptName = $scriptName -replace '.ps1',''
$scriptName += "-log.txt"
New-Item -ItemType Directory -Force -Path $Logpath | Out-Null
$script:logfile="$Logpath\$scriptname"
setLogFileName -logfile $script:logfile -custom $true

################################################################################
##################################### MAIN #####################################
################################################################################
$ErrorActionPreference = "Stop"

$me=whoami
writeLogMessage ""
writeLogMessage "START (script version dated $lastchange, run by $me )"
writeLogMessage "INFO`t Library Version $($lib.Version.Major).$($lib.Version.Minor), last change $($lib.PrivateData.lastchange)"
writeLogMessage "INFO`t Logfile will be written to $script:logfile"

if(-Not (Get-Module -Name "ActiveDirectory" -ListAvailable)) {
  try {
    writeLogMessage "WARNING`t PowerShell Module 'ActiveDirectory' not found. Trying to install it..."
    Import-Module ServerManager
    Add-WindowsFeature RSAT-AD-PowerShell
    writeLogMessage "SUCCESS`t PowerShell Module 'ActiveDirectory' installed"
  } catch {
    writeLogMessage "ERROR`t Could not install PowerShell Module 'ActiveDirectory': $_"
    finish 99
  }
}

Create_ScheduledTask_with_XML -Author $me -FilePathofScript $Executable -User $User -Password $password -TaskName $TaskName -TaskDescription $description -StartTime "01:15:00" -DaysInterval 1

try {
  Start-ScheduledTask -TaskName $TaskName
  writeLogMessage  "INFO`t Started Scheduled Task '$TaskName'"
} catch {
  writeLogMessage "ERROR`t Could not start Scheduled Task '$TaskName' $_"
  finish 1
}

finish 0