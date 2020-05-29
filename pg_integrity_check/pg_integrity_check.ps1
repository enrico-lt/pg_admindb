<#
.SYNOPSIS
    Performs an integrity check of PostgreSQL database
.DESCRIPTION
    Use switch -CheckWithPgDump for integrity check using pg_dump. pg_dump 
    creates a custom dump, which reads every data row of the database it 
    connects to. If the pg_dump runs successfull we expect the database to be 
    not corrupted. In rare cases system tables can be affected from corruption, 
    which would maybe not detected with pg_dump.
    
    Use switch -CheckWithPgCheckSums for integrity check with pg_checksums. 
    Only availiable with PostgreSQL 12. pg_checksums really checks the checksum
    feature of the PostgreSQL cluster.

    Use switch -CheckForeignKeys for consistency check of foreign keys. Due
    to corruption and a fix with data loss, foreign keys may have become 
    invalid. A file containing the bad rows with DELETE statement will be 
    created

    Will be executed in NT SYSTEM security context.
.NOTES
    Author:			Enrico La Torre
    Date:			  2019-08-05
#>
################################################################################
############################## PROCESS PARAMETERS ##############################
################################################################################
param(
# Connection parameters
[string] $server = "localhost"
,[string] $user
,[string] $pgPort = "5432"
# Switch if check is used regularly, otherwise only checked if last shutdown
# was unexpected
,[string] $UsedByCalendarTrigger
# Switches for check methods
,[string] $CheckWithPgDump
,[string] $CheckWithPgCheckSums
,[string] $CheckForeignKeys
# Parameters for check with pg_dump
,[string] $excludeDB = ""
,[string] $backupdir 
# c = custom dump, sql = plain text dump
,[string] $dumpFormat = "c"
# Path of script for Foreign Key Check
,[string] $FKCheckScript
# Directory for log file
,[string] $logpath
#,[string] $DelLogOlderThanDays
)

################################################################################
########################### CONFIGURATION PARAMETERS ###########################
################################################################################
$lastchange = "2020-05-29"

$pgVersion = "12"
$pgServiceName = "postgresql${pgVersion}"

$PgDataDir="G:\databases\PostgreSQL\$pgVersion\" # trailing \ is suuper important for pg_ctl
$PgProgDir="C:\Program Files\PostgreSQL\$pgVersion\bin"

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
    ,[string] $progdir
    ,[string] $format = "c"
    ,[int] $exitcode
  )
  if($format -eq "c") { 
    $FileNameExtension = "custom" 
  } elseif ($format -eq "sql") {
    $FileNameExtension = "sql"
  }

  # Get user databases names
  try {
    $OdbcConn= openOdbcConnection -dbServer $computer -userName $user -portNo $pgPort
    $query = "select datname from pg_database where datname not in ('postgres', 'template0', 'template1')"
    if ($excludeDB) {
      writeLogMessage "INFO`t Skipping database(s) NOT LIKE '$excludeDB'"
      $query += " AND datname NOT LIKE '$excludeDB';"
    }
    $USER_DATABASES = (queryOdbcConnection -conn $OdbcConn -query $query).Tables[0]
  } catch {
    writeLogMessage "ERROR`t pg_backup: Can not query list of databases $_"
    finish $exitcode
  } finally {
    $OdbcConn.close()
  }

  # Process each user database
  foreach ( $database in $USER_DATABASES.datname ) {
    writeLogMessage "INFO`t Starting integrity check of database '$database' on '$server' using pg_dump..."

    if(-Not (Test-Path -Path $backupdir)) {
      New-Item -ItemType Directory -Force -Path $backupdir | Out-Null
    }

    $filename = "$backupdir\${env:COMPUTERNAME}_${database}_${now}.${FileNameExtension}"

    writeLogMessage "INFO`t Executing pg_dump..."
    try {
      $dump_proc = Start-Process -FilePath "$progdir\pg_dump.exe" -ArgumentList "-h $computer -U $user -v -w --format=$format -f $filename $database" -Wait -PassThru -NoNewWindow -RedirectStandardError "$backupdir\stderr_pg_dump.txt" -RedirectStandardOutput "$backupdir\stdout_pg_dump.txt"
    } catch {
      writeLogMessage "ERROR`t pg_dump process failed: $_"
    }
    $stdout = Get-Content -Path "$backupdir\stdout_pg_dump.txt"
    writeLogMessage "INFO`t Standard output pg_dump:"
    foreach ($line in $stdout ) { 
      writeLogMessage "`t $line"
    }
    $stderr = Get-Content -Path "$backupdir\stderr_pg_dump.txt"
    writeLogMessage "INFO`t Standard error pg_dump:"
    foreach ($line in $stderr ) { 
      writeLogMessage "`t $line"
    }

    if ($dump_proc.ExitCode -ne 0) {
      writeLogMessage "ERROR`t Exit code of pg_dump is '$($dump_proc.ExitCode)'. Check log file. Integrity may be violated!"
      writeLogMessage "INFO`t Deleting temporary pg_dump directory..."
      deleteOldBackups -backupdir $backupdir -exitcode $exitcode
      finish $exitcode
    } elseif ($dump_proc.ExitCode -eq 0) {
      writeLogMessage "SUCCESS`t pg_dump possible of '$database'. Every data row is accessible."
      writeLogMessage "INFO`t Deleting temporary pg_dump directory..."
      deleteOldBackups -backupdir $backupdir -exitcode $exitcode
    } 
  } # foreach database
} # Function pg_backup


Function deleteOldBackups ([string] $backupdir, [int] $exitcode) {
  try {
    Remove-Item -Path $backupdir -Force -Recurse
    writeLogMessage "SUCCESS`t Deleted temporary directory '$backupdir'"
  } catch {
    writeLogMessage "ERROR`t deleteOldBackups: $_"
    finish $exitcode
  }
 } # Function deleteOldBackups

 Function CheckEventLogForUnexpectedShutdown ([int] $exitcode) {

  try {
    $BootTime = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
    $UnexpectedShutDownEvent = Get-WinEvent -FilterHashtable @{ LogName='System'; StartTime=$BootTime.AddMinutes(-2); Id='41' } -ErrorAction SilentlyContinue
  
    if($null -ne $UnexpectedShutDownEvent) {
      return $true
    } else {
      return $false
    }
  } catch {
    writeLogMessage "ERROR`t CheckEventLogForUnexpectedShutdown: $_"
    finish $exitcode
  }
  

} # Function CheckEventLogForUnexpectedShutdown

Function CheckPostgreSQLService () {

  param (
    [string] $pgServiceName
    ,[string] $datadir
    ,[string] $progdir
    ,[int] $exitcode
  )

  try {
    $pgservice = Get-Service -Name $pgServiceName
  } catch {
    writeLogMessage "ERROR`t CheckPostgreSQLService, can not get service '$pgServiceName'.`n`t $_"
    finish $exitcode
  }
  
  # If service is not running check the cluster with pg_ctl
  if ($pgservice.Status -ne 'Running') {
    writeLogMessage "INFO`t PostgreSQL service $pgServiceName is '$($pgservice.Status)'. Checking PostgreSQL server with pg_ctl.exe"
    try {
      $pgStatusProc =  Start-Process -FilePath "$progdir\pg_ctl.exe" -ArgumentList "status -D $datadir" -Wait -PassThru -NoNewWindow -RedirectStandardError "$logpath\stderr_pg_ctl.txt" -RedirectStandardOutput "$logpath\stdout_pg_ctl.txt"  
    } catch {
      writeLogMessage "ERROR`t CheckPostgreSQLService`t Start-Process of '$progdir\pg_ctl.exe status' failed: $_"
      writeLogMessage "ERROR`t Assuming that PostgreSQL server is running. Therefore doing pg_ctl stop and Start-Service $pgServiceName"
      $KnownErrorWorkAround1 = $true
    }
    $stdout = Get-Content -Path "$logpath\stdout_pg_ctl.txt"
    writeLogMessage "INFO`t Standard output pg_ctl status:"
    foreach ($line in $stdout) { 
      writeLogMessage "`t $line"
    }
    $stderr = Get-Content -Path "$logpath\stderr_pg_ctl.txt"
    writeLogMessage "INFO`t Standard error pg_ctl status:"
    foreach ($line in $stderr) { 
      writeLogMessage "`t $line"
    }
    # Remove temporary log files again
    Remove-Item -Path "$logpath\stdout_pg_ctl.txt" -Force
    Remove-Item -Path "$logpath\stderr_pg_ctl.txt" -Force

    # If PostgreSQL server is running stop it with pg_ctl stop so the Service Control Manager can start the service properly
    if (($pgStatusProc.ExitCode -eq 0) -or $KnownErrorWorkAround1) { # 0 = Server is running
      writeLogMessage "INFO`t Service '$pgServiceName' is NOT running, but pg_ctl status is running. Therefore stopping with pg_ctl stop ..."
      try {
        $pgStopProc =  Start-Process -FilePath "$progdir\pg_ctl.exe" -ArgumentList "stop -D $datadir -m fast" -Wait -PassThru -NoNewWindow -RedirectStandardError "$logpath\stderr_pg_ctl_stop.txt" -RedirectStandardOutput "$logpath\stdout_pg_ctl_stop.txt"
      } catch {
        writeLogMessage "ERROR`t CheckPostgreSQLService`t Start-Process of '$progdir\pg_ctl.exe stop' failed: $_"
        writeLogMessage "ERROR`t Assuming that pg_ctl stop worked fine but only Start-Process Cmdlet had problems. Continuing..."
        $KnownErrorWorkAround2 = $true
      }
      $stdout = Get-Content -Path "$logpath\stdout_pg_ctl_stop.txt"
      writeLogMessage "INFO`t Standard output pg_ctl stop:"
      foreach ($line in $stdout) { 
        writeLogMessage "`t $line"
      }
      $stderr = Get-Content -Path "$logpath\stderr_pg_ctl_stop.txt"
      writeLogMessage "INFO`t Standard error pg_ctl stop:"
      foreach ($line in $stderr) { 
        writeLogMessage "`t $line"
      }
      # Remove temporary log files again
      Remove-Item -Path "$logpath\stdout_pg_ctl_stop.txt" -Force
      Remove-Item -Path "$logpath\stderr_pg_ctl_stop.txt" -Force

      if (($pgStopProc.ExitCode -eq 0) -or $KnownErrorWorkAround2) {
        writeLogMessage "INFO`t Cluster stopped. Starting PostgreSQL service '$pgServiceName'..."
        try {
          Set-Service -Name $pgServiceName -StartupType "Automatic"
          Start-Service -Name $pgServiceName
          (Get-Service -Name $pgServiceName).WaitForStatus('Running','00:01:00')
          writeLogMessage "SUCCESS`t PostgreSQL service '$pgServiceName' started"
        } catch {
          writeLogMessage "ERROR`t Can not start service '$pgServiceName'. It reached not the status 'Running' after 1 minute,`n`t $_"
          finish $exitcode
        }
      } else {
        writeLogMessage "ERROR`t Stopping of cluster with pg_ctl failed, exit code $($pgStopProc.ExitCode)"
        finish $exitcode
      }
    # If PostgreSQL server is stopped and service is stopped, simply start the service  
    } elseif ($pgStatusProc.ExitCode -eq 3) { # 3 = Server is not running
      writeLogMessage "INFO`t Service '$pgServiceName' is NOT running AND pg_ctl status is NOT running. Trying to start the service..."
      try {
        Set-Service -Name $pgServiceName -StartupType "Automatic"
        Start-Service -Name $pgServiceName
        (Get-Service -Name $pgServiceName).WaitForStatus('Running','00:01:00')
        writeLogMessage "SUCCESS`t PostgreSQL service '$pgServiceName' started"
      } catch {
        writeLogMessage "ERROR`t Can not start service '$pgServiceName'. It reached not the status 'Running' after 1 minute,`n`t $_"
        finish $exitcode
      }
    } # elseif exit code 3
  # If the service is running everyhting is fine
  } else {
    writeLogMessage "INFO`t PostgreSQL service $pgServiceName is '$($pgservice.Status)'. This is fine."
  }
  writeLogMessage "SUCCESS`t PostgreSQL service status checked"
} # Function CheckPostgreSQLService


Function pg_check_integrity () {

  param (
    [string] $pgServiceName
    ,[string] $datadir
    ,[string] $progdir
    ,[int] $exitcode
  )

  # Stop related services of PostgreSQL and PostgreSQL service
  stopRelatedServices -exitcode $exitcode
  stopPgService -pgServiceName $pgServiceName -exitcode $exitcode

  # pg_checksums
  try {
    $pgcheckProc =  Start-Process -FilePath "$progdir\pg_checksums.exe" -ArgumentList "--check --progress -D $datadir" -Wait -PassThru -NoNewWindow -RedirectStandardError "$logpath\stderr_pg_checksums.txt" -RedirectStandardOutput "$logpath\stdout_pg_checksums.txt"
    $stdout = Get-Content -Path "$logpath\stdout_pg_checksums.txt"
    writeLogMessage "INFO`t Standard output pg_checksums:"
    foreach ($line in $stdout) { 
      writeLogMessage "$line"
    }
    $stderr = Get-Content -Path "$logpath\stderr_pg_checksums.txt"
    writeLogMessage "INFO`t Standard error pg_checksums:"
    foreach ($line in $stderr) { 
      writeLogMessage "$line"
    }

    if ($pgcheckProc.ExitCode -eq 0) {
      writeLogMessage "INFO`t pg_checksums.exe finished with exit code $($pgcheckProc.ExitCode). Everything is fine."
    } else {
      writeLogMessage "ERROR`t Checksum integrity violated! Exit code of pg_checksums is $($pgcheckProc.ExitCode)."
      finish $exitcode
    }
    # Remove temporary log files again
    Remove-Item -Path "$logpath\stdout_pg_checksums.txt" -Force
    Remove-Item -Path "$logpath\stderr_pg_checksums.txt" -Force

  } catch {
    writeLogMessage "ERROR`t Execution of program 'pg_checksums.exe' failed: $_"
    finish $exitcode
  } finally {
    # Start related services of PostgreSQL and PostgreSQL service
    startRelatedServices -exitcode $exitcode
    StartPgService -pgServiceName $pgServiceName -exitcode $exitcode
  }
} # pg_check_integrity

Function pg_foreign_key_check () {

  param (
    [string] $fkscript
    ,[string] $computer
    ,[string] $user
    ,[string] $pgPort
    ,[string] $progdir 
    ,[string] $excludeDB
    ,[int] $exitcode
  )
  
  try {
    # Get user databases names
    $OdbcConn= openOdbcConnection -dbServer $computer -userName $user -portNo $pgPort
    $query = "select datname from pg_database where datname not in ('postgres', 'template0', 'template1')"
    if ($excludeDB) {
      writeLogMessage "INFO`t Skipping database(s) NOT LIKE '$excludeDB'"
      $query += " AND datname NOT LIKE '$excludeDB';"
    }
    $USER_DATABASES = (queryOdbcConnection -conn $OdbcConn -query $query).Tables[0]
  } catch {
    writeLogMessage "ERROR`t pg_foreign_key_check: Can not query list of databases $_"
    finish $exitcode
  } finally {
    $OdbcConn.close()
  }

  
  $errorcounter = 0
  # Process each user database
  foreach ( $database in $USER_DATABASES.datname ) {
    $psqlerror = "false"
    try {
      writeLogMessage "INFO`t Starting consistency check of Foreign Keys for database '$database' on '$server' as user '$user'..."
      Start-Process -FilePath "$progdir\psql.exe" -ArgumentList "-h $computer -p $pgPort -U $user --echo-errors --no-password -f $fkscript $database" -Wait -PassThru -NoNewWindow -RedirectStandardError "$logpath\stderr_fk.txt" -RedirectStandardOutput "$logpath\stdout_fk.txt"
      
      $stdout = Get-Content -Path "$logpath\stdout_fk.txt"
      writeLogMessage "INFO`t Standard output psql:"
      foreach ($line in $stdout) { 
        writeLogMessage "`t $line"
      }
      $stderr = Get-Content -Path "$logpath\stderr_fk.txt"
      writeLogMessage "INFO`t Standard error psql:"
      foreach ($line in $stderr) {
        if ($line -match "ERROR:") {
          $psqlerror = "true"
        } 
        writeLogMessage "`t $line"
      }
      # Remove temporary log files again
      Remove-Item -Path "$logpath\stdout_fk.txt" -Force
      Remove-Item -Path "$logpath\stderr_fk.txt" -Force
  
      if ($psqlerror -eq "true") { 
        writeLogMessage "ERROR`t Foreign key integrity violated! psql.exe returned an error."
        writeLogMessage "ERROR`t pg_foreign_key_check: There are bad rows in database '$database' $_"
        $errorcounter++
      } else {
        writeLogMessage "INFO`t psql.exe returned no errors. Everything is fine."
        writeLogMessage "INFO`t Foreign Key Consistency check for database '$database' passed"
      }
    } catch {
      writeLogMessage "ERROR`t pg_foreign_key_check for '$database' Problem with Start-Process -FilePath $progdir\psql.exe  $_"
      finish $exitcode
    }
  } # foreach
  if ($errorcounter -gt 0){
    writeLogMessage "ERROR`t pg_check_integrity $errorcounter database(s) show inconsistent foreign keys! Therefore stop!"
    finish $exitcode
  }
} # Function pg_foreign_key_check

################################################################################
##################################### MAIN #####################################
################################################################################
$ErrorActionPreference = "Stop"

$me=whoami
writeLogMessage ""
writeLogMessage "START (script version dated $lastchange, run by $me )"
writeLogMessage "INFO`t Library Version $($lib.Version.Major).$($lib.Version.Minor), last change $($lib.PrivateData.lastchange)"
writeLogMessage "INFO`t Logfile will be written to '$logpath'"

writeLogMessage "INFO`t Checking the status of the PostgreSQL Service..."
CheckPostgreSQLService -pgServiceName $pgServiceName  -datadir $PgDataDir -progdir $PgProgDir -exitcode 1

writeLogMessage "INFO`t Checking if last shutdown was unexpected..."
if(CheckEventLogForUnexpectedShutdown -exitcode 99){
  writeLogMessage "WARNING`t Last shutdown was unexpected!"

  if ($CheckWithPgCheckSums) {
    writeLogMessage "INFO`t Starting integrity check of PostreSQL cluster '$PgDataDir' on '$server' using pg_checksums..."
    pg_check_integrity -pgServiceName $pgServiceName -datadir $PgDataDir -progdir $PgProgDir -exitcode 3
  }  # CheckWithPgCheckSums

  if ($CheckWithPgDump) {
    # Process each user database
    writeLogMessage "INFO`t Starting integrity check of PostreSQL cluster '$PgDataDir' on '$server' using pg_dump..."
    pg_backup -computer $server -user $user -portNo $pgPort -progdir $PgProgDir -backupdir $backupdir -database $database -excludeDB $excludeDB -dumpFormat $dumpFormat -exitcode 2 
  } # CheckWithPgDump

} else {
  writeLogMessage "INFO`t Last shutdown was OK"

  if ($UsedByCalendarTrigger) {
    writeLogMessage "INFO`t Integrity is checked on a regular basis..."

    if ($CheckWithPgCheckSums) {
      writeLogMessage "INFO`t Starting integrity check of PostreSQL cluster '$PgDataDir' on '$server' using pg_checksums..."
      pg_check_integrity -pgServiceName $pgServiceName -datadir $PgDataDir -progdir $PgProgDir -exitcode 3
    } # CheckWithPgCheckSums
  
    if ($CheckWithPgDump) {
      writeLogMessage "INFO`t Starting integrity check of PostreSQL cluster '$PgDataDir' on '$server' using pg_dump..."
      pg_backup -computer $server -user $user -portNo $pgPort -progdir $PgProgDir -backupdir $backupdir -database $database -excludeDB $excludeDB -dumpFormat $dumpFormat -exitcode 2 
    } # CheckWithPgDump
  } # UsedByCalendarTrigger
} #CheckEventLogForUnexpectedShutdown

if ($CheckForeignKeys) {
  writeLogMessage ""
  writeLogMessage "INFO`t Checking integrity of foreign keys..."
  pg_foreign_key_check -fkscript $FKCheckScript -computer $server -user $user -pgPort $pgPort -progdir $PgProgDir -excludeDB $excludeDB -exitcode 4
}

writeLogMessage "SUCCESS`t Integrity check passed"
finish 0