<#
.SYNOPSIS
  PostgreSQL rotate logs, compress them and delete old logs
.DESCRIPTION
  It will be executed by a Scheduled Task.
  This script makes PostgreSQL start a new log file and compresses the previous one.
  Requires 7z.exe and 7z.dll file in script directory.

  This script deletes two kinds of old log files:

    1. PostgreSQL's log files
    2. Log files of the pg_ad_sync_tool

  Optional parameter is -olderthan value
  --------------------------------------
  The parameter -olderthan may be specified as the year, month or day from which to 
  keep the logs, e. g. "2017-08" will delete all logs up to end of July 2017, or 
  "2017" will delete all logs up to 2016-12-31, or "2017-08-15" will delete all 
  logs before 2016-08-15. The default is to delete all logs older than 90 days.

.NOTES
    Last editor:  Enrico La Torre
#>

################################################################################
############################## PROCESS PARAMETERS ##############################
################################################################################
param(
  [string] $DelLogsOlderThanDays = "90"
  ,[string] $server = "localhost"
  ,[string] $database = "postgres"
  ,[string] $log_mgmt_user = "backup" 
  # Port for PostgreSQL cluster
  ,[string] $pgPort = "5432"
  # Directory for log file of script
  ,[string] $logpath
)

################################################################################
########################### CONFIGURATION PARAMETERS ###########################
################################################################################
$lastchange = "2020-05-29"

# PostgreSQL major version
$pgVersion = "12"
# Data directory of PostgreSQL
$PgDataDir="G:\databases\PostgreSQL\$pgVersion"
$pgLogDirectory = "$PgDataDir\log"
# Directories of log files to manage
$logDirectories = @()
$logDirectories += "$PgDataDir\log"
$logDirectories += "E:\pg_admindb\logs\pg_full_backup"
$logDirectories += "E:\pg_admindb\logs\pg_ADSync"
$logDirectories += "E:\pg_admindb\logs\pg_integrity_check"
$logDirectories += "E:\pg_admindb\logs\pg_IndexOptimize"
$logDirectories += "$logpath"

# File location of 7z.exe for archiving
$sevenZ = $PSScriptRoot + "\7z.exe"

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
$scriptName += "-log-{timestamp}.log"
if (-Not (Test-Path -Path $Logpath)) {
  New-Item -ItemType Directory -Force -Path $Logpath | Out-Null
}
$script:logfile="$Logpath\$scriptname"
setLogFileName -logfile $script:logfile

#################################################################################
################################### FUNCTIONS ###################################
#################################################################################

# Deletes log files. Parameters:
#    1 - directory
#    2 - pattern prefix
#    3 - olderthan date
Function deleteLogs () {
  Param (
    [Parameter(Mandatory=$true)]
    [string] $logFilePath,
    [Parameter(Mandatory=$true)] 
    [string] $prefix,
    [Parameter(Mandatory=$true)] 
    [string] $olderThan,
    [int]$ExitCode
  )
  
  if (-Not (Test-Path -Path $logFilePath -PathType Container)){
    return $null
  }

  $regex = '(\d\d\d\d\-\d\d-\d\d)_'
  WriteLogMessage "INFO`t deleteLogs in '$logFilePath' older than '$olderThan', date regex: '$regex'"

  try {
    Get-ChildItem $logFilePath -Filter ($prefix + "*2*.log*") |
    Foreach-Object {
      if ($_.Name -match $regex) {
        $date = $matches[1]
        if ($date -lt $olderthan) {
          WriteLogMessage "INFO`t Deleting '$($_.FullName)'"
          Remove-Item -Force $_.FullName
        } else {
          WriteLogMessage "INFO`t Keeping '$($_.FullName)'"
        } # if
      } else {
        WriteLogMessage "WARNING`t Doesn't match date-regex '${$_.Name}'"
      } # if
    } # foreach
  } catch {
    writeLogMessage "ERROR`t deleteLogs: $_"

    finish $ExitCode
  }
} # deleteLogs


# Make PostgreSQL start a new log file and compress the previous one using 7-zip
# Omit Path7zExecutable switch to skip compression
Function rotateLogs () {

  param(
    [string] $server
    ,[string] $database
    ,[string] $pgPort
    ,[string] $log_mgmt_user
    ,[string] $dir
    ,[string] $Path7zExecutable
    ,[int] $ExitCode
  )

  $cmd = "SELECT pg_rotate_logfile();"
  ExecutePSQL -sqlCommands $cmd -server $server -PortNo $pgPort -database $database -user $log_mgmt_user -exitCode $ExitCode
  WriteLogMessage "SUCCESS`t Rotated log file with '$cmd'"


  if(Test-Path -Path $Path7zExecutable) {
    # find out name of current log file (youngest one, just begun)
    $logFileName = ''
    try {
      $logFileName=(Get-ChildItem $dir | 
      Where-Object {$_.Name -like '*.log'} |
      Sort-Object -Property @{Expression={$_.CreationTime}; Ascending=$False} |
      Select-Object -first 1)
      WriteLogMessage "INFO`t Found current (new) logfile '$logFileName'"
    } catch {
      WriteLogMessage "ERROR`t rotateLogs: Cannot determine name of new log file! $_"
      finish $($ExitCode+1)
    }

    # compress all log files except the current one and log files older than 2 days
    $logFileList = (Get-ChildItem $dir | 
      Where-Object {$_.Name -like '*.log'} |
      where-Object {($_.Name -ne $logFileName) -and ((New-TimeSpan -Start $_.CreationTime -End (Get-Date)).Days -gt 2)})
    foreach ($logFile in $logFileList) {
      $fileName = $dir + '\' + $logFile
      $archive = $fileName
      $archive += ".gz"     
      & $Path7zExecutable a -tgzip $archive $fileName
      if ($LASTEXITCODE -eq 0) {
        Remove-Item $fileName -Force
      } else {
        WriteLogMessage "ERROR`t rotateLogs: Cannot cannot compress previous log files!"
        WriteLogMessage "ERROR`t LASTEXITCODE of 7z is '$LASTEXITCODE'"
        finish $($ExitCode+2)
      }
      writeLogMessage "SUCCESS`t Compressed log file '$fileName' to '$archive' and deleted log file"
    } # foreach
  } else {
    WriteLogMessage "Test-Path of '$Path7zExecutable' yields false!"
    finish $($ExitCode+3)
  } # if $Path7zExecutable
} # rotateLogs


################################################################################
##################################### MAIN #####################################
################################################################################
$ErrorActionPreference = "Stop"

$me=whoami
writeLogMessage ""
writeLogMessage "START (script version dated $lastchange, run by $me )"
writeLogMessage "INFO`t Library Version $($lib.Version.Major).$($lib.Version.Minor), last change $($lib.PrivateData.lastchange)"
writeLogMessage "INFO`t Logfile will be written to '$logpath'"

WriteLogMessage "INFO`t Rotating PostgreSQL log file..."
rotateLogs -server $server -database $database -pgPort $pgPort -log_mgmt_user $log_mgmt_user -dir $pgLogDirectory -Path7zExecutable $sevenZ -ExitCode 1

# Set threshold to default if not specified

$olderThan = ((Get-Date).addDays(-$DelLogsOlderThanDays).ToString("yyyy-MM-dd"))

# Delete old logs and archives in given directories
foreach ($dir  in $logDirectories) {
  writeLogMessage "INFO`t Deleting log files in '$dir' older than '$olderThan'..."
  deleteLogs -logFilePath $dir -prefix "*-" -olderThan $olderThan -ExitCode 2

finish 0