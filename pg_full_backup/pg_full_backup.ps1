<#
.SYNOPSIS
    Create a logical dump of PostgreSQL database(s)
.DESCRIPTION
    This script creates a custom dump with pg_dump and a dump of  all global
    objects with pg_dumpall.

    The PostgreSQL binary path must be present in PATH environment variable.
    
    Requires PostgreSQL Powershell library.
.NOTES
    Author:			Enrico La Torre
    Date:			  2019-07-22
#>

################################################################################
############################## PROCESS PARAMETERS ##############################
################################################################################
param(
# Connection parameters
[string] $server = "localhost"
,[string] $backupuser
,[string] $pgPort = "5432"
# Backup parameters
,[string] $excludeDB = ""
,[string] $backupdir = "E:\pg_admindb\Backup"
,[string] $BackupOlderThanHours
# c = custom dump, sql = plain text dump
,[string] $dumpFormat = "c"
# Directory for log file
,[string] $logpath
#,[string] $DelLogOlderThanDays
)

################################################################################
########################### CONFIGURATION PARAMETERS ###########################
################################################################################
$lastchange = "2020-05-29"

$pgVersion = "12"
$PgProgDir="C:\Program Files\PostgreSQL\$pgVersion\bin"

# Timestamp for file names
$timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"

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
$scriptName += "-log_{timestamp}.log"
New-Item -ItemType Directory -Force -Path $Logpath | Out-Null
$script:logfile="$Logpath\$scriptname"
setLogFileName -logfile $script:logfile


#################################################################################
################################### FUNCTIONS ###################################
#################################################################################

Function pg_backup () {

  param(
    [string] $computer = "localhost"
    ,[string] $user = "backup" 
    ,[string] $portNo = "5432"
    ,[string] $backupdir
    ,[string] $database
    ,[string] $format = "c"
    ,[string] $olderThanHours
    ,[string] $progdir
    ,[int] $exitcode
  )

  if($format -eq "c") { 
    $FileNameExtension = "custom" 
  } elseif ($format -eq "sql") {
    $FileNameExtension = "sql"
  }

  $backupdir_dump = "$backupdir\DUMP\$database"
  if(-Not (Test-Path -Path $backupdir_dump)) {
    New-Item -ItemType Directory -Force -Path $backupdir_dump | Out-Null
  }

  writeLogMessage "INFO`t Executing pg_dump for database '$database'"

   $filename = "$backupdir_dump\${env:COMPUTERNAME}_${database}_${timestamp}.${FileNameExtension}" 

  try {
    $dump_proc = Start-Process -FilePath "$progdir\pg_dump.exe" -ArgumentList "-h $computer -U $user -p $portNo -w --format=$format -f $filename $database" -Wait -PassThru -NoNewWindow -RedirectStandardError "$backupdir_dump\stderr.txt" -RedirectStandardOutput "$backupdir_dump\stdout.txt"
  } catch {
    writeLogMessage "ERROR`t pg_dump process failed: $_"
  }
  $stdout = Get-Content -Path "$backupdir_dump\stdout.txt"
  writeLogMessage "INFO`t Standard output:"
  foreach ($line in $stdout ) { 
    writeLogMessage "$line"
  }
  $stderr = Get-Content -Path "$backupdir_dump\stderr.txt"
  writeLogMessage "INFO`t Standard error:"
  foreach ($line in $stderr ) { 
    writeLogMessage "$line"
  }
  # Remove temporary log files again
  Remove-Item -Path "$backupdir_dump\stdout.txt" -Force
  Remove-Item -Path "$backupdir_dump\stderr.txt" -Force

  if ($dump_proc.ExitCode -ne 0) {
    writeLogMessage "ERROR`t Exit code of pg_dump is '$($dump_proc.ExitCode)'. Check log file. Integrity may be violated!"
    finish $exitcode
  } elseif ($dump_proc.ExitCode -eq 0) {
    writeLogMessage "SUCCESS`t pg_dump of '$database' to '$filename'"
    writeLogMessage "INFO`t Deleting backpups older than '$olderThanHours' hours"
    deleteOldBackupFiles -backupdir $backupdir_dump -olderThanHours $olderThanHours -exitcode $exitcode
  } 
} # Function pg_backup


Function pg_backup_globals () {

  param(
    [string] $computer = "localhost"
    ,[string] $user = "backup"
    ,[string] $portNo = "5432"
    ,[string] $backupdir
    ,[string] $olderThanHours
    ,[string] $progdir
    ,[int] $exitcode
  )

  $backupdir_globals = "$backupdir\GLOBALS"
  if(-Not (Test-Path -Path $backupdir_globals)) {
    New-Item -ItemType Directory -Force -Path $backupdir_globals | Out-Null
  }

  writeLogMessage "INFO`t Executing pg_dumpall for cluster '$computer' on port '$portNo'"

  $filename = "$backupdir_globals\${env:COMPUTERNAME}_${timestamp}.globals.sql" 

  try {
    $dumpall_proc = Start-Process -FilePath "$progdir\pg_dumpall.exe" -ArgumentList "-h $computer -U $user -p $portNo -w --globals-only -f $filename" -Wait -PassThru -NoNewWindow -RedirectStandardError "$backupdir_globals\stderr.txt" -RedirectStandardOutput "$backupdir_globals\stdout.txt"
  } catch {
    writeLogMessage "ERROR`t pg_dumpall process failed: $_"
  }
  $stdout = Get-Content -Path "$backupdir_globals\stdout.txt"
  writeLogMessage "INFO`t Standard output:"
  foreach ($line in $stdout ) { 
    writeLogMessage "$line"
  }
  $stderr = Get-Content -Path "$backupdir_globals\stderr.txt"
  writeLogMessage "INFO`t Standard error:"
  foreach ($line in $stderr ) { 
    writeLogMessage "$line"
  }
  # Remove temporary log files again
  Remove-Item -Path "$backupdir_globals\stdout.txt" -Force
  Remove-Item -Path "$backupdir_globals\stderr.txt" -Force

  if ($dumpall_proc.ExitCode -ne 0) {
    writeLogMessage "ERROR`t Exit code of pg_dumpall is '$($dumpall_proc.ExitCode)'. Check log file. Integrity may be violated!"
    finish $exitcode
  } elseif ($dumpall_proc.ExitCode -eq 0) {
    writeLogMessage "SUCCESS`t pg_dumpall for cluster '$computer' on port '$portNo' to '$filename'"
    writeLogMessage "INFO`t Deleting backpups older than '$olderThanHours' hours"
    deleteOldBackupFiles -backupdir $backupdir_globals -olderThanHours $olderThanHours -exitcode $exitcode
  } 
} # Function pg_backup_globals

Function deleteOldBackupFiles () {

  param(
    [string] $backupdir
    ,[string] $olderThanHours
    ,[int] $exitcode
  )

  try {
    Get-ChildItem -Path "$backupdir" -Recurse | Where-Object {($_.LastWriteTime -lt (Get-Date).AddHours(-$olderThanHours))} | Remove-Item -Force
    writeLogMessage "SUCCESS`t Deleted old backup files in '$backupdir'"
  } catch {
    writeLogMessage "ERROR`t deleteOldBackupFiles: $_"
    finish $exitcode
  }
 } # Function deleteOldBackupFiles

################################################################################
##################################### MAIN #####################################
################################################################################
$ErrorActionPreference = "Stop"

$me=whoami
writeLogMessage ""
writeLogMessage "START (script version dated $lastchange, run by $me )"
writeLogMessage "INFO`t Library Version $($lib.Version.Major).$($lib.Version.Minor), last change $($lib.PrivateData.lastchange)"
writeLogMessage "INFO`t Logfile will be written to '$logpath'"

# Backup global objects like roles etc
pg_backup_globals -computer $server -portNo $pgPort -user $backupuser -backupdir $backupdir -olderThanHours $BackupOlderThanHours -progdir $PgProgDir -exitcode 1

# Get user databases names
try {
  $OdbcConn= openOdbcConnection -dbServer $server -userName $backupuser -portNo $pgPort
  $query = "select datname from pg_database where datname not in ('postgres', 'template0', 'template1')"
  if ($excludeDB) {
    $query += " AND datname NOT LIKE '$excludeDB';"
  }
  $USER_DATABASES = (queryOdbcConnection -conn $OdbcConn -query $query).Tables[0]
} catch {
  writeLogMessage "ERROR`t pg_backup: Can not query list of databases $_"
  finish 99
} finally {
  $OdbcConn.close()
}

# Backup user databases
foreach ( $database in $USER_DATABASES.datname ) {
  pg_backup -computer $server -portNo $pgPort -user $backupuser -backupdir $backupdir -database $database -format $dumpFormat -olderThanHours $BackupOlderThanHours -progdir $PgProgDir -exitcode 2
}

finish 0