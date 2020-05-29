<#
.SYNOPSIS
    Create Scheduled Task for deletion of old log files,archives and rotation of 
    PostgreSQL log
.DESCRIPTION
    Must be executed in NT SYSTEM security context.

    Requires PostgreSQL Powershell library.
.NOTES
    Author:			Enrico La Torre
    Date:			  2019-07-22
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
$filepath = "E:\pg_admindb\pg_log_mgmt\pg_log_mgmt.ps1"
$ArgumentList = ' -DelLogsOlderThanDays "30" -log_mgmt_user "'+"$useronly"+'" -logpath "E:\pg_admindb\logs\pg_log_mgmt"'
$Executable = $filepath + $ArgumentList 
$TaskName = "PG_log_mgmt"
$description = "Rotate and delete old PostgreSQL log files."

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

Create_ScheduledTask_with_XML -Author $me -FilePathofScript $Executable -User $User -Password $password -TaskName $TaskName -TaskDescription $description -StartTime "01:00:00" -WeeksInterval 1 -DaysOfWeek @("Sunday")

finish 0