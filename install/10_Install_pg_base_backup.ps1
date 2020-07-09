<#
.SYNOPSIS
    Create a Scheduled Task for the pg_base_backup.ps1 script
.DESCRIPTION
    Requires PostgreSQL Powershell library.
.NOTES
    Author:			Enrico La Torre
    Date:			  2020-07-02
#>

$lastchange = "2020-07-07 13:35"

################################################################################
########################### CONFIGURATION PARAMETERS ###########################
################################################################################

# Domain (FQDN)
$domainFQDN = (Get-WmiObject win32_computersystem).Domain
$domain = $domainFQDN.Split('.')[0]
$corp = $domain.substring($domain.length -3)

# Get the region number and determine if testenvironment or not
if ($env:computername -match "^0[0-9]{3}\w{8}[lL][0-9]{2}") { # live servers (\w is word character [A-Za-z0-9])
  $region = $env:computername.Substring(1,3)
  $testenvironment = $false
} elseif ($env:computername -match "^[1-9]{2}09\w{8}[tTdDqQ][0-9]{2}") { # corporate test servers 
  $region = $corp
  $testenvironment = $true
} elseif ($env:computername -match "^[0-8][0-9]{2}DB[TL]") { # legacy live
  $region = $env:computername.Substring(0,3)
  $testenvironment = $false
} elseif ($env:computername -match "^9[0-9]{2}DB[TL]") { # legacy test
  $region = $env:computername.Substring(0,3)
  $testenvironment = $true
} elseif ($env:computername -match "^[0-8][0-9]{2}-[0-9]{3}STL01") { # live store servers-Ob
  $region = $env:computername.Substring(0,3)
  $testenvironment = $false
  if ($domain -eq "aldi-113" -or $region -eq "102"){ # Exceptions
    $testenvironment = $true
  }
} elseif ($env:computername -match "^9[0-9]{2}-[0-9]{3}STL01") { # test store servers
  $region = $env:computername.Substring(0,3)
  $testenvironment = $true
} else {
	$region = Read-Host -Prompt 'Please enter the region or corporate number'
}

# User that executes the Scheduled Task
$User = "DOMAIN\USER"
$useronly = "USER"
$password = "xxx"

# Scheduled Task parameter
$filepath = "E:\pg_admindb\pg_base_backup\pg_base_backup.ps1" # "C:\Install\Files\PostgreSQL\pg_base_backup\pg_base_backup.ps1"  

# Backup user in PostgreSQL
$backupuser = $useronly
# Backup directory
$backupdir = "E:\pg_admindb\Backup"
$keepOldBackups = 2
# WAL Archive
$CleanUpWALArchive = "Y"
$WALarchiveDir = "E:\pg_admindb\PostgreSQL-WAL-Archive"
# Directory for log file
$logpathForScript = "E:\pg_admindb\logs\pg_base_backup"
# Directory for 7z.exe utility
$prog7z = "E:\pg_admindb\pg_log_mgmt\7z.exe"

$ArgumentList = ' -backupuser "'+$backupuser+'" -keepOldBackups "'+$keepOldBackups+'" -backupdir "'+$backupdir+'" -logpath "'+$logpathForScript+'" -CleanUpWALArchive "'+$CleanUpWALArchive+'" -WALarchiveDir "'+$WALarchiveDir+'" -prog7z "'+$prog7z+'"'
$Executable = $filepath + $ArgumentList 
$TaskName = "pg_base_backup" # "PG_Base_Backup"
$description = "Create a base backup of a PostgreSQL cluster"

# Directory for log file
$logpath = "C:\system_update\logs\PostgreSQL"

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

writeLogMessage "INFO`t Server: $env:computername, Domain $domain, Region $region, Corporate $corp"
writeLogMessage "INFO`t Testenviroment $testenvironment"

Create_ScheduledTask_with_XML -Author $me -FilePathofScript $Executable -User $User -Password $password -TaskName $TaskName -TaskDescription $description -StartTime "02:00:00" -WeeksInterval 1 -DaysOfWeek @("Saturday")

finish 0
