<#
.SYNOPSIS
  Switch from one PostgreSQL Server major version to a newer major version. 
.DESCRIPTION

  PARAMETERS:
  
    oldmajorversion newmajorversion

  PRECONDITIONS:
  
    * Postgres OLDMAJORVERSION is running on port 5432 and used by NEWPOSS
    * Postgres NEWMAJORVERSION is running on port 5433 and is ready to take over

  UPGRADE PROCEDURE:
    
  * This script stops and deactivates the NEWPOSS service.

  * The old database system is dumped into a file on the backup drive and its service stopped and disabled. 
    
  * The saved data including current user accounts are restored from the file to the new system.
    
  * The line in the configuration file postgresql.auto.conf of the new Postgres major version making it use 
    5433 instead of the standard port is removed in order to deactivate it.
    
  * The service of the new Postgres major version is re-started, so that it opens the standard 
    port 5432.

  * For saftey reasons a line in the configuration file postgresql.auto.conf of the OLD Postgres major 
    version making it use port 5433 is inserted. If it is started by accident it won't interfere.

  * The DependOnService entry of NEWPOSS in the registry will be replaced by the new
    service name 'postgresNEWMAJORVERSION'.

  * The NEWPOSS service is enabled by setting it to 'automatic' start and will be started
    on the next reboot of the system.
    
  * The intermediate file for the dump and its directory are deleted again if everything is okay.
    
  * This script takes care of these steps. In case of failure, some settings
    might have to be restored manually. Please check the contents of the log file
    (see below) if the error level (exit status) is not zero.
 
  The old database won't be deleted. Unless new data have been written to the new database,
  the following steps allow reverting to using the old one:
  
  * Stop and disable service postgresqlNEWMAJORVERSION.
  * Adjust dependencies of NEWPOSS to OLDMAJORVERSION.
  * Enable and start service postgresqlOLDMAJORVERSION.

  After running this script, a REBOOT is necessary. Otherwise, services dependent
  on PostgreSQL won't be running (currently, this is NEWPOSS).
    
.NOTES
    Author:			Enrico La Torre
    Date:			  2020-02-25
#>
<#
TODO
Error handling
Update cluster_name
-> check if WAL archive is empty and if not start incremental backup task and 
wait for exit code 0 of task, then continue
#>
################################################################################
############################## PROCESS PARAMETERS ##############################
################################################################################
param(
  [string] $oldversion,
  [string] $newversion,
  [switch] $enableWAL,
  [switch] $setNEWPOSSdependency
)
################################################################################
########################### CONFIGURATION PARAMETERS ###########################
################################################################################
$lastchange = "2020-05-29"

# Directory for backup. Will be deleted if migration successful
$dumpdir = 'E:\Backup\pg_major_upgrade_dump'

# PostgrSQL program directory. Correct major version will be appended if needed 
$pgProgDir = "C:\Program Files\PostgreSQL\"
# PostgrSQL data directory. Correct major version will be appended if needed 
$pgDataDir = "G:\databases\PostgreSQL\"

# Database that will be migrated
$database = "pg_admindb"
# Schema that will be migrated
$schema = "public"

# Config file name of WAL settings
$walconfig = "02wal.conf"

# Set variables with service names
$newServicename = "postgresql$newVersion"
if ($oldversion -eq '9.6') {
  $oldServicename = 'postgresql'
} else {
  $oldServicename = "postgresql$oldVersion"
}

# Timestamp for dump file name
$timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"

# Domain (FQDN)
$domainFQDN = (Get-WmiObject win32_computersystem).Domain
$domain = $domainFQDN.Split('.')[0]

# Directory for log file
$Logpath = "E:\pg_admindb\logs\major_upgrade_$newversion"

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
setLogFileName -logfile $script:logfile


#################################################################################
################################### FUNCTIONS ###################################
#################################################################################

Function removeDirWaitTryAgain () {
  param(
    [ValidateScript({Test-Path $_ -PathType 'container'})] [string] $dir, 
    [int] $maxWaitSeconds = 600
  )
  $totalWaitSecs = 0
  $sleepSecs = 10
  while ($True) {
    try {
      Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction Stop
      return $True
    } catch {
      write-host "WARNING`t Removing of '$dir' failed after $totalWaitSecs seconds. Trying again..."
      Start-Sleep $sleepSecs
      $totalWaitSecs += $sleepSecs
      if ($totalWaitSecs -gt $maxWaitSeconds) {
        writeLogMessage "ERROR`t Removing of '$dir' failed: $_"
        return $False
      }
    }
  } # while forever
} # Function removeDirWaitTryAgain

# Remove configuration item which changed the port number of PG NEWMAJORVERSION
# from 5432 to 5433. Now old PG version is disabled and port 5432 is free 
# for the new PG version. So the port setting in postgresql.auto.conf has to
# be removed. 
Function setPortToStandard ([string] $PgVersion ,[int] $exitCode) {
  $autoConf = $pgDataDir
  $autoConf += $PgVersion
  $autoConf += "\postgresql.auto.conf"
  try {
    $autoConfLines = Get-Content -Path $autoConf | Select-String -Pattern 'port.*5433' -NotMatch
    Set-Content -Path $autoConf -Value $autoConfLines 
    writeLogMessage "INFO`t Port setting of port 5433 removed from file '$autoConf'"
  } catch {
    writeLogMessage "ERROR`t Cannot remove port setting from '$autoConf' file"
    writeLogMessage "INFO`t Starting old service and related services again"
    startPgService -pgServiceName $oldServicename -pgPort 5432 -exitCode $exitcode
    startRelatedServices -exitcode $exitcode
    finish $exitCode
  }
} # setPortToStandard

Function portTo5433 ([string] $PgVersion ,[int] $exitcode) {

  $autoConf = $pgDataDir
  $autoConf += $PgVersion 
  $autoConf += "\postgresql.auto.conf"
  try {
    "`n" | Out-File $autoConf -Encoding ASCII -Append
    'port = 5433' | Out-File $autoConf -Encoding ASCII -Append
    "`n" | Out-File $autoConf -Encoding ASCII -Append
  } catch {
    writeLogMessage "ERROR`t Cannot change port by modifying postgresql.auto.conf for PostgreSQL '$pgMajorVersion', $_"
    finish $exitcode
  }  
  writeLogMessage "INFO`t Port changed to 5433 in file '$autoConf'."
} # Function portTo5433

# Get MAJOR version of PostgreSQl
Function getPgMajorVersion ([int] $portNo = 5432) {
  $version = getPgVersionOdbc $portNo
  if ($version -eq "") {
    return ""
  }
  return [regex]::Match($version, '^(.*)\.[0-9]+$').captures.groups[1].value
} # Function getPgMajorVersion


# Update dependency of NEWPOSS service
Function setNewpossServiceDependency ([string[]] $dependsOn, [int] $exitcode) {
  try {
    [String] $NEWPOSSpath = 'HKLM:\SYSTEM\CurrentControlSet\Services\NEWPOSS'
    if (Test-Path -Path $NEWPOSSpath) {
      Set-ItemProperty -Path $NEWPOSSpath -Name DependOnService -Value $dependsOn
    } else {
      writeLogMessage "WARINING`t No NEWPOSS Service path in registry found"
    }
  } catch {
    writeLogMessage "ERROR`t setNewpossServiceDependency $_"
    finish $exitcode
  }
} # Function setNewpossServiceDependency

Function pg_backup () {

  param(
    [string] $computer = "localhost"
    ,[string] $user = "backup" 
    ,[string] $portNo = "5432"
    ,[string] $backupdir
    ,[string] $database
    ,[string] $schema
    ,[string] $format = "c"
    ,[string] $progdir
    ,[int] $exitcode
  )

  if($format -eq "c") { 
    $FileNameExtension = "custom" 
  } elseif ($format -eq "sql") {
    $FileNameExtension = "sql"
  }

  if ($schema) {
    $schemaSwitch = "-n $schema"
  }

  $backupdir_dump = "$backupdir\DUMP\$database"
  if(-Not (Test-Path -Path $backupdir_dump)) {
    New-Item -ItemType Directory -Force -Path $backupdir_dump | Out-Null
  }

  writeLogMessage "INFO`t Executing pg_dump for database '$database' on '$computer' on port '$portNo'"

  $filename = "$backupdir_dump\${env:COMPUTERNAME}_${database}_${timestamp}.${FileNameExtension}" 
  
  writeLogMessage "INFO`t $progdir\bin\pg_dump.exe -h $computer -U $user -p $portNo -w --format=$format $schemaSwitch -f $filename $database"
  try {
    $dump_proc = Start-Process -FilePath "$progdir\bin\pg_dump.exe" -ArgumentList "-h $computer -U $user -p $portNo -w --format=$format $schemaSwitch -f $filename $database" -Wait -PassThru -NoNewWindow -RedirectStandardError "$backupdir_dump\stderr.txt" -RedirectStandardOutput "$backupdir_dump\stdout.txt"
  } catch {
    writeLogMessage "ERROR`t pg_dump process failed: $_"
    writeLogMessage "INFO`t Starting related services again"
    startRelatedServices -exitcode $exitcode
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
    writeLogMessage "ERROR`t Exit code of pg_dump is '$($dump_proc.ExitCode)'. Check log file"
    writeLogMessage "INFO`t Starting related services again"
    startRelatedServices -exitcode $exitcode
    finish $exitcode
  } elseif ($dump_proc.ExitCode -eq 0) {
    writeLogMessage "INFO`t pg_dump of '$database' to '$filename' finished"
  } 
} # Function pg_backup

Function pg_restore () {

  param(
    [string] $computer = "localhost"
    ,[string] $user = "backup" 
    ,[string] $portNo = "5432"
    ,[string] $backupdir
    ,[string] $database
    ,[string] $schema
    ,[string] $progdir
    ,[int] $exitcode
  )

  if ($schema) {
    $schemaSwitch = "-n $schema"
  }

  $backupdir_restore = "$backupdir\DUMP\$database"

  writeLogMessage "INFO`t Executing pg_restore for database '$database' on '$computer' on port '$portNo'"
  $filename = (Get-ChildItem -Path $backupdir_restore -Recurse | Sort-Object CreationTime -Descending | Select-Object -First 1).Fullname

  writeLogMessage "INFO`t $progdir\bin\pg_restore.exe -h $computer -U $user -p $portNo -w --clean --if-exists -1 -e $schemaSwitch -d $database $filename" 
  try {
    $restore_proc = Start-Process -FilePath "$progdir\bin\pg_restore.exe" -ArgumentList "-h $computer -U $user -p $portNo -w --clean --if-exists -1 -e $schemaSwitch -d $database $filename" -Wait -PassThru -NoNewWindow -RedirectStandardError "$backupdir_restore\stderr_pgrestore.txt" -RedirectStandardOutput "$backupdir_restore\stdout_pgrestore.txt"
  } catch {
    writeLogMessage "ERROR`t pg_restore process failed: $_"
    writeLogMessage "INFO`t Starting old service and related services again"
    startPgService -pgServiceName $oldServicename -pgPort 5432 -exitCode $exitcode
    startRelatedServices -exitcode $exitcode
  }
  $stdout = Get-Content -Path "$backupdir_restore\stdout_pgrestore.txt"
  writeLogMessage "INFO`t Standard output:"
  foreach ($line in $stdout ) { 
    writeLogMessage "$line"
  }
  $stderr = Get-Content -Path "$backupdir_restore\stderr_pgrestore.txt"
  writeLogMessage "INFO`t Standard error:"
  foreach ($line in $stderr ) { 
    writeLogMessage "$line"
  }
  # Remove temporary log files again
  Remove-Item -Path "$backupdir_restore\stdout_pgrestore.txt" -Force
  Remove-Item -Path "$backupdir_restore\stderr_pgrestore.txt" -Force

  if ($restore_proc.ExitCode -ne 0) {
    writeLogMessage "ERROR`t Exit code of pg_restore is '$($restore_proc.ExitCode)'. Check log file"
    if(!(removeDirWaitTryAgain -dir $dumpdir)){ 
      writeLogMessage "ERROR`t Cannot remove program directory '$dumpdir'"
    }
    writeLogMessage "INFO`t Starting old service and related services again"
    startPgService -pgServiceName $oldServicename -pgPort 5432 -exitCode $exitcode
    startRelatedServices -exitcode $exitcode
    finish $exitcode
  } elseif ($restore_proc.ExitCode -eq 0) {
    writeLogMessage "INFO`t pg_restore of '$database' from '$filename' finished"
  } 

} # Function pg_restore

Function EnableWALarchiving ([int] $exitCode) {

  try {
    if (Test-Path -Path $($pgDataDir + $newPgVersion + "\conf.d\"  + $walconfig + "-deactivated") -PathType Leaf) {
      writeLogMessage "INFO`t Enable config file '$($pgDataDir + $newPgVersion + "\conf.d\"  + $walconfig + "-deactivated")' from to '$($pgDataDir + $newPgVersion + "\conf.d\"  + $walconfig)'"
      Rename-Item -Path $($pgDataDir + $newPgVersion + "\conf.d\"  + $walconfig + "-deactivated") -NewName $($pgDataDir + $newPgVersion + "\conf.d\"  + $walconfig)
    } elseif (Test-Path -Path $($pgDataDir + $newPgVersion + "\conf.d\"  + $walconfig) -PathType Leaf) {
      writeLogMessage "INFO`t WAL config file '$($pgDataDir + $newPgVersion + "\conf.d\"  + $walconfig)' already exists. Skipping"
    } else {
      writeLogMessage "ERROR`t EnableWALarchiving Not able to find deactivated WAL config file '$($pgDataDir + $newPgVersion + "\conf.d\"  + $walconfig + "-deactivated")'. Please check!"
      finish $exitcode
    }
  } catch {
    writeLogMessage "ERROR`t EnableWALarchiving $_"
    finish $exitcode
  }
} # Function EnableWALarchiving

############################################################################################
########################################## MAIN ############################################
############################################################################################
$ErrorActionPreference = "Stop"

$me=whoami
writeLogMessage ""
writeLogMessage "START (script version dated $lastchange, run by $me )"
writeLogMessage "INFO`t Library Version $($lib.Version.Major).$($lib.Version.Minor), last change $($lib.PrivateData.lastchange)"
writeLogMessage "INFO`t Logfile will be written to $script:logfile"

# Check time of day - must not run during business hours
$now = get-date -format "HHmm"
if ($now -gt "0600" -and $now -lt "2200") {
  writeLogMessage "ERROR`t This script must not be executed during business hours (0600 to 2200)."
  finish 601
} 

writeLogMessage "INFO`t Local execution: Setting PGSSLMODE = 'allow'"
$Env:PGSSLMODE = "allow"

# Start new service for migration
startPgService -pgServiceName $newServicename -pgPort 5433 -exitCode 602

# Displaying old and new PostgreSQL version (including minor version)
$oldPgVersion = getPgMajorVersion -portNo 5432 
writeLogMessage "INFO`t PostgreSQL major version on port 5432 is '$oldPgVersion'"
$newPgVersion = getPgMajorVersion -portNo 5433
writeLogMessage "INFO`t PostgreSQL major version on port 5433 is '$newPgVersion'"

if ($oldPgVersion -eq '') {
  writeLogMessage "ERROR`t Cannot determine PG version on port 5432. Switching to new version not possible. STOP."
  finish 603
}
if ($newPgVersion -eq '') {
  writeLogMessage "ERROR`t Cannot determine PG version on port 5433. Switching to new version not possible. STOP."
  finish 604
}

# Check if old version matches parameter.
if ($oldVersion -ne $oldPgVersion) {
  writeLogMessage "ERROR`t Old version is supposed to be '$oldversion', but on the default port (5432) version '$oldPgVersion' is active. STOP."
  finish 605
}
# Check if new version matches parameter.
if ($newVersion -ne $newPgVersion) {
  writeLogMessage "ERROR`t New version is supposed to be '$newversion', but on port 5433 version '$newPgVersion' is active. STOP."
  finish 606
}

# Stopping related services which might interfere
stopRelatedServices -exitCode 607

# Creating a dump with old version
pg_backup -computer "localhost" -user "system" -portNo "5432" -backupdir $dumpdir -database $database -schema $schema -format "c" -progdir $($pgProgDir + $oldversion) -exitcode 608

# Stop and disable old service
stopPgService -pgServiceName $oldServicename -exitCode 609

# Restoring contents from dumpfile to new database (on port 5433)
pg_restore -computer "localhost" -user "system" -portNo "5433" -backupdir $dumpdir  -database $database -schema $schema -progdir $($pgProgDir + $newversion) -exitcode 610

# Enable WAL archiving of NEW database
if ($enableWAL) {
  EnableWALarchiving -exitcode 611
}

# Set port of NEW database to standard port
setPortToStandard -PgVersion $newPgVersion -exitCode 612

# Set port of OLD database to 5433 for saftey reasons, if old service started by accident it does not do any damage
portTo5433 -PgVersion $oldPgVersion -exitcode 613

# Restart NEW PostgreSQL service
stopPgService -pgServiceName $newServicename -exitCode 614
startPgService -pgServiceName $newServicename -pgPort 5432 -exitCode 615

# Enabling and starting related services again, except NEWPOSS it can only start after a reboot
startRelatedServices -exitcode 618

writeLogMessage "SUCCESS`t Switch of PostgreSQL service from version '$oldVersion' to version '$newVersion' completed successfully."

#writeLogMessage "INFO`t REBOOT is necessary for re-starting NEWPOSS."
#$rebootNecessary = 1029 # https://docs.microsoft.com/en-us/windows/desktop/msi/event-logging
#$msg = "REBOOT REQUIRED, because dependencies of NEWPOSS service changed to new PostgreSQL Major version."
#Write-EventLog -LogName Application -Source PG_MAINTENANCE -EntryType "Warning" -EventId $rebootNecessary -Message $msg

# Start AD-Sync task
if (Get-ScheduledTask -TaskName 'PG_ADSync' -ErrorAction SilentlyContinue) {
  writeLogMessage "INFO`t Starting Scheduled Task 'PG_ADSync'"
  Start-ScheduledTask -TaskName 'PG_ADSync'
}

# Remove dump file if switch successful
writeLogMessage "INFO`t Removing temporary backup directory '$dumpdir'"
if(!(removeDirWaitTryAgain -dir $dumpdir)){ 
  writeLogMessage "ERROR`t Cannot remove program directory '$dumpdir'"
  finish  619
}

finish 0