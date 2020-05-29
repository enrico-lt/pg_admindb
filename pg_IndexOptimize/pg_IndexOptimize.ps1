<#
.SYNOPSIS
    Performs a REINDEX and VACUUM ANALYZE of all PostgreSQL databases
.DESCRIPTION
    By default all USER_DATABASES are reindexed. You can adjust the scope of 
    this script by adding the switches -database, -schema, -table or -index
    to the function call of pg_reindex. 

    Will be executed in NT SYSTEM security context.
.NOTES
    Author:			Enrico La Torre
    Date:			  2019-12-19
#>
################################################################################
############################## PROCESS PARAMETERS ##############################
################################################################################

param(
# Connection parameters
[string] $server = "localhost"
,[string] $maintenanceuser  = "system"
,[string] $pgPort = "5432"
,[string] $database = "USER_DATABASES"
# reindexdb parameters
,[string] $reindexdb
,[string] $schema 
,[string] $table 
,[string] $index
# vacuumdb parameters
,[string] $vacuumdb
,[string] $vacuum_table
,[string] $full
,[string] $analyze
,[string] $analyze_only
,[string] $analyze_in_stages
# Directory for log file
,[string] $logpath
# Genereal options
,[string] $verbose_client_app
,[int] $TimeOutMinutes
)

################################################################################
########################### CONFIGURATION PARAMETERS ###########################
################################################################################
$lastchange = "2020-05-29"

$pgVersion = "12"
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

Function pg_reindex () {

  param(
    [string] $computer = "localhost"
    ,[int] $pgPort
    ,[string] $user = "system" 
    ,[string] $database = "USER_DATABASES"
    ,[string] $schema
    ,[string] $table 
    ,[string] $index
    ,[string] $verbose_client_app
    ,[string] $progdir
    ,[int] $TimeOutMinutes = 360
    ,[parameter(Mandatory=$True)] [int] $ExitCode
  )
  # Handle the input scope parameters
  $database_array = $database.split(",")

  foreach ($database in $database_array) {

    if ($database -eq "USER_DATABASES" ) {
      $dbswitch = "--all"
    } else {
      $dbswitch = $database
    }
    $options = ""
    if ($verbose_client_app) {
      $options += " --verbose"
    }
    if ([int]$pgVersion -ge [int]"12") {
      $options += " --concurrently"
    }

    # Build the correct --schame, --table or --index switch for reindexdb.exe
    $scope = ""
    if ($schema) {
      $schema_Array = $schema.split(",")
      foreach ($schema in $schema_Array) {
          $scope += " --schema=$schema"
      }
    }
    if ($table) {
      $table_Array = $table.split(",")
      foreach ($table in $table_Array) {
          $scope += " --table=$table"
      }
    }
    if ($index) {
      $index_Array = $index.split(",")
      foreach ($index in $index_Array) {
          $scope += " --index=$index"
      }
    }

    # Execute reindexdb with all parameters
    writeLogMessage "INFO`t Executing: reindexdb -h $computer -p $pgPort -U $user --echo -w $options $scope $dbswitch"
    try {
      $reindex_proc= Start-Process -FilePath $progdir\reindexdb.exe -ArgumentList "-h $computer -p $pgPort -U $user --echo -w $options $scope $dbswitch" -PassThru -NoNewWindow -RedirectStandardError "$logpath\stderr_reindex.txt" -RedirectStandardOutput "$logpath\stdout_reindex.txt"
      $TimeOutSeconds = $TimeOutMinutes * 60
      $reindex_proc | Wait-Process -Timeout $TimeOutSeconds -ErrorAction Stop
    } catch {
      writeLogMessage "ERROR`t pg_reindex process failed or exceeds time out parameter: $_"
      $reindex_proc | Stop-Process -Force 
      $OdbcConn= openOdbcConnection -dbServer $computer -userName $user -portNo $pgPort
      $query = "select pg_terminate_backend(pid) from pg_stat_activity where application_name = 'reindexdb'"
      queryOdbcConnection -conn $OdbcConn -query $query
      finish ($ExitCode+1)
    }
    try {
      $stdout = Get-Content -Path "$logpath\stdout_reindex.txt"
      writeLogMessage "INFO`t Standard output:"
      foreach ($line in $stdout) { 
        writeLogMessage "$line"
      }
      Remove-Item -Path "$logpath\stdout_reindex.txt" -Force

      $stderr = Get-Content -Path "$logpath\stderr_reindex.txt"
      writeLogMessage "INFO`t Standard error:"
      foreach ($line in $stderr) { 
        writeLogMessage "$line"
      }
      Remove-Item -Path "$logpath\stderr_reindex.txt" -Force
    } catch {
      writeLogMessage "ERROR`t pg_reindex Handling of temporary log files '$logpath\stdout_reindex.txt' or '$logpath\stderr_reindex.txt' failed: $_"
      finish ($ExitCode+1)
    }

    if ($reindex_proc.ExitCode -ne 0) {
      writeLogMessage "ERROR`t pg_reindex Exit code of reindexdb is '$($reindex_proc.ExitCode)'. Check log file."
      finish $ExitCode
    } elseif ($reindex_proc.ExitCode -eq 0) {
      writeLogMessage "SUCCESS`t reindexdb of database '$database' finished succesfully."
    }
  } # foreach database

} # Function pg_reindex

Function pg_vacuum () {

  param(
    [string] $computer = "localhost"
    ,[int] $pgPort
    ,[string] $user = "system" 
    ,[string] $database = "USER_DATABASES"
    ,[string] $vacuum_table 
    ,[string] $full
    ,[string] $analyze
    ,[string] $analyze_only
    ,[string] $analyze_in_stages
    ,[string] $verbose_client_app
    ,[string] $progdir
    ,[int] $TimeOutMinutes = 360
    ,[parameter(Mandatory=$True)] [int] $ExitCode
  )
  # Handle the input options parameters
  $database_array = $database.split(",")

  foreach ($database in $database_array) {

    if ($database -eq "USER_DATABASES" ) {
      $dbswitch = "--all"
    } else {
      $dbswitch = $database
    }
    # Build the correct - --table switch for vacuumdb.exe
    $options = ""
    if ($vacuum_table) {
      $table_Array = $vacuum_table.split(",")
      foreach ($table in $table_Array) {
          $options += " --table=$table"
      }
    }
    if ($full) {
      $options += " --full"
    }
    if ($analyze) {
      $options += " --analyze"
    }
    if ($analyze_only) {
      $options += " --analyze-only"
    }
    if ($analyze_in_stages) {
      $options += " --analyze-in-stages"
    }
    if ($verbose_client_app) {
      $options += " --verbose"
    }

    # Execute vacuumdb with all parameters
    writeLogMessage "INFO`t Executing: vacuumdb -h $computer -p $pgPort -U $user --echo -w $options $dbswitch"
    try {
      $vacuumdb_proc= Start-Process -FilePath $progdir\vacuumdb.exe -ArgumentList "-h $computer -p $pgPort -U $user --echo -w $options $dbswitch" -Wait -PassThru -NoNewWindow -RedirectStandardError "$logpath\stderr_vacuumdb.txt" -RedirectStandardOutput "$logpath\stdout_vacuumdb.txt"
      $TimeOutSeconds = $TimeOutMinutes * 60
      $vacuumdb_proc | Wait-Process -Timeout $TimeOutSeconds -ErrorAction Stop
    } catch {
      writeLogMessage "ERROR`t pg_vacuum process failed or exceeds time out parameter: $_"
      $vacuumdb_proc | Stop-Process -Force
      $OdbcConn= openOdbcConnection -dbServer $computer -userName $user -portNo $pgPort
      $query = "select pg_terminate_backend(pid) from pg_stat_activity where application_name = 'vacuumdb'"
      queryOdbcConnection -conn $OdbcConn -query $query
      finish ($ExitCode+1)
    }
    try {
      $stdout = Get-Content -Path "$logpath\stdout_vacuumdb.txt"
      writeLogMessage "INFO`t Standard output:"
      foreach ($line in $stdout) { 
        writeLogMessage "$line"
      }
      Remove-Item -Path "$logpath\stdout_vacuumdb.txt" -Force

      $stderr = Get-Content -Path "$logpath\stderr_vacuumdb.txt"
      writeLogMessage "INFO`t Standard error:"
      foreach ($line in $stderr) { 
        writeLogMessage "$line"
      }
      Remove-Item -Path "$logpath\stderr_vacuumdb.txt" -Force
    } catch {
      writeLogMessage "ERROR`t pg_vacuum Handling of temporary log files '$logpath\stdout_vacuumdb.txt' or '$logpath\stderr_vacuumdb.txt' failed: $_"
      finish ($ExitCode+1)
    }

    if ($vacuumdb_proc.ExitCode -ne 0) {
      writeLogMessage "ERROR`t pg_vacuum Exit code of reindexdb is '$($vacuumdb_proc.ExitCode)'. Check log file."
      finish $ExitCode
    } elseif ($vacuumdb_proc.ExitCode -eq 0) {
      writeLogMessage "SUCCESS`t vacuumdb of database '$database' finished succesfully."
    }
  } # foreach database

} # Function pg_vacuum


################################################################################
##################################### MAIN #####################################
################################################################################
$ErrorActionPreference = "Stop"

$me=whoami
writeLogMessage ""
writeLogMessage "START (script version dated $lastchange, run by $me )"
writeLogMessage "INFO`t Library Version $($lib.Version.Major).$($lib.Version.Minor), last change $($lib.PrivateData.lastchange)"
writeLogMessage "INFO`t Logfile will be written to '$logpath'"

# Local connections should not establish SSL connection at first
if ($server -in ("localhost", "127.0.0.1", "::1")) {
  $Env:PGSSLMODE = "allow"
  writeLogMessage "INFO`t Local execution: Setting PGSSLMODE = 'allow'"
}

if ($reindexdb) {
  $msg = "INFO`t reindexdb.exe on host '$server' 'port' $pgPort  as user '$maintenanceuser'`n`tdatabase '$database'"
  if ($schema) {$msg += "`n`tschema $schema"}
  if ($table) {$msg += "`n`ttable '$table'"}
  if ($index) {$msg += "`n`tindex '$index'"}
  writeLogMessage $msg

  pg_reindex -computer $server -pgPort $pgPort -database $database -schema $schema -table $table -index $index -user $maintenanceuser -ExitCode 1 -verbose_client_app $verbose_client_app -progdir $PgProgDir -TimeOutMinutes $TimeOutMinutes
}

writeLogMessage "`n"
writeLogMessage "`n"
writeLogMessage "`n"

if ($vacuumdb) {
  $msg = "INFO`t vacuumdb.exe on host '$server' 'port' $pgPort  as user '$maintenanceuser'`n`tdatabase '$database'"
  if ($vacuum_table) {$msg += "`n`tvacuum_table $vacuum_table"}
  if ($full) {$msg += "`n`tfull '$full'"}
  if ($analyze) {$msg += "`n`tanalyze '$analyze'"}
  if ($analyze_only) {$msg += "`n`tanalyze_only '$analyze_only'"}
  if ($analyze_in_stages) {$msg += "`n`tanalyze_in_stages '$analyze_in_stages'"}
  writeLogMessage $msg

  pg_vacuum -computer $server -pgPort $pgPort -database $database -vacuum_table $vacuum_table -full $full -analyze $analyze -analyze_only $analyze_only -analyze_in_stages $analyze_in_stages -user $maintenanceuser -ExitCode 2 -verbose_client_app $verbose_client_app -progdir $PgProgDir -TimeOutMinutes $TimeOutMinutes
}

finish 0