<#
.SYNOPSIS
    Create a Scheduled Task for the pg_integrity_check.ps1 script
.DESCRIPTION
    Requires PostgreSQL Powershell library.
.NOTES
    Author:			Enrico La Torre
    Date:			  2019-08-29
#>

$lastchange="2020-05-29"

################################################################################
########################### CONFIGURATION PARAMETERS ###########################
################################################################################

# User that executes the Scheduled Task
$User = "NT AUTHORITY\SYSTEM"
$useronly = "system"

# Foreign Key Check parameters
$FKCheckScript ='E:\pg_admindb\pg_integrity_check\ForeignKeyConsistencyCheck.sql'
$FKCheckScriptLogPath = 'E:\pg_admindb\logs\pg_integrity_check'

# Scheduled Task parameter
$filepath = "E:\pg_admindb\pg_integrity_check\pg_integrity_check.ps1"
$ArgumentList = ' -backupdir "E:\pg_admindb\Backup\pg_integrity_check" -user "'+"$useronly"+'" -CheckWithPgCheckSums "Y" -UsedByCalendarTrigger "Y" -logpath "E:\pg_admindb\logs\pg_integrity_check" -CheckForeignKeys "Y" -FKCheckScript "'+"$FKCheckScript"+'"'
$Executable = $filepath + $ArgumentList 
$TaskName = "pg_integrity_check"
$description = "Checks the integrity of the PostgreSQL cluster. Checks integrity with pg_checksums, data accessibility with pg_dump and foreign key consistency with a custom script."

# Directory for log file of this installation script
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

# Check whether we are "NT Authority\System" 
if ($me -ne "NT Authority\System") { 
  writeLogMessage 'This script has to be executed as "NT Authority\System"' 
  finish 1 
} 

# Enter the correct logpath for the ForeignKeyConsistencyCheck.sql script
try {
    $script = Get-Content -Path $FKCheckScript
    $script -replace("{logpath}","$FKCheckScriptLogPath") | Set-Content -Path $FKCheckScript -Encoding Default
} catch {
    writeLogMessage "ERROR`t Can not replace '$FKCheckScriptLogPath' in '$FKCheckScript'"
    finish 2
}

Create_ScheduledTask_with_XML -Author $me -FilePathofScript $Executable -User $User -TaskName $TaskName -TaskDescription $description -StartTime "02:00:00" -DaysInterval 3 -Boottrigger "Y"

finish 0