<#
.SYNOPSIS
    Create the Scheduled Task 'pg_IndexOptimize' for database maintenance
    tasks
.DESCRIPTION
    Must be executed in NT SYSTEM security context, i.e account that will 
    execute the Scheduled Task.

    The exit codes mean
    0   - Success
    1   - Can not import module C:\Install\Files\StoreServerSetup.psm1
    2   - Wrong parameters
    701 - Can not create Scheduled Task
.NOTES
    Author:			Enrico La Torre 
    Date:			  2019-10-17
#>

$lastchange="2020-05-29"

################################################################################
########################### CONFIGURATION PARAMETERS ###########################
################################################################################
# User that executes the Scheduled Task
$User = "DOMAIN\USER"
$useronly = "USER"
$password = "xxx"

# Database user
$maintenanceuser = $useronly

# Log verbose information of reindexdb and vacuumdb in log file
# $verbose_client_app = 'Y'

# Scope definition for reindexing
$reindexdb = 'Y'
# With USER_DATABASES all databases are reindexed.
# Wildcard characters and '-' to exclude names, like in Ola Hallengrens functions are not 
# supported yet. If you use USER_DATABASES don't specify any other database.
#
# If you specify a list of databases please follow the template: "DB1,DB2,...,DBN"
# If you use multiple databases the schema, table and index switches might fail if they 
# don't exist in the target database
$database = "USER_DATABASES"
# By default all schemas, tables and indexes are processed.
# If you specify a list of schemas please follow the template: "Schema1,Schema2,...,SchemaN" 
# $schema = "public"
# If you specify a list of tables please follow the template: "Table1,Table2,...,TableN" 
# $table  = ""
# If you specify a list of index please follow the template: "Index1,Index2,...,IndexN"
# $index = ""

# Options for vacuumdb
# Enable usage of vacuumdb tool. Common usage is to enable also $analyze.
# $vacuumdb = 'Y'

# If you specify a list of tables please follow the template: "Table1,Table2,...,TableN". By 
# default all tables are processed.
# $vacuum_table = ""

# Do a VACUUM FULL instead of normal VACUUM
# $full = 'Y'

# Update statistics after vacuum
# $analyze = 'Y'

# Only update statistics and do no vacuum
# You cannot specify --full and --analyze-only togehter
# $analyze_only = 'Y'

# Run the statistics update in stages to produce usable statistics faster 
# You cannot specify --full and --analyze-in-stages togehter
# $analyze_in_stages = 'Y'

# Time out for reindexing and vacuum
# If you fear that you run into the time out then the $maintenanceuser must have superuser 
# permissions, because the real SQL command must be killed to stop the execution
$TimeOutMinutes = 360 # 6 hours

# Scheduled Task parameter
$TaskName = "pg_IndexOptimize"
$description = "Custom PostgreSQL database maintenance task. Can execute REINDEX and VACUUM commands against a PostgreSQL cluster."
$filepath = "E:\pg_admindb\pg_IndexOptimize\pg_IndexOptimize.ps1"
$ArgumentList = ' -database "'+$database+'" -maintenanceuser "'+"$maintenanceuser"+'" -logpath "E:\pg_admindb\logs\pg_IndexOptimize" -TimeOutMinutes "'+"$TimeOutMinutes"+'"'
# Reindexing parameters
if($reindexdb) { $ArgumentList += ' -reindexdb "'+$reindexdb +'"'}
if($schema) { $ArgumentList += ' -schema "'+$schema +'"' }
if($table) { $ArgumentList += ' -table "'+$table +'"' }
if($index) { $ArgumentList += ' -index "'+$index +'"' }
# Vacuum and analyze parameters
if($vacuumdb) { $ArgumentList += ' -vacuumdb "'+$vacuumdb +'"'}
if($vacuum_table) { $ArgumentList += ' -vacuum_table "'+$vacuum_table +'"'}
if($full) { $ArgumentList += ' -full "'+$full +'"'}
if($analyze) { $ArgumentList += ' -analyze "'+$analyze +'"'}
if($analyze_only) { $ArgumentList += ' -analyze_only "'+$analyze_only +'"'}
if($analyze_in_stages) { $ArgumentList += ' -analyze_in_stages "'+$analyze_in_stages +'"'}
# General options
if($verbose_client_app) { $ArgumentList += ' -verbose_client_app "'+$verbose_client_app +'"' }

# Put it all together
$Executable = $filepath + $ArgumentList 

# Directory for log file of this install script
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

# Parameter checks
if ($database -eq "USER_DATABASES" -and $schema) {
    writeLogMessage "ERROR`t Cannot reindex specific schema in all databases. You cannot specify --all and --schema for reindexdb"
    finish 2
}
if ($full -and $analyze_only) {
    writeLogMessage "ERROR`t You cannot specify --full and --analyze-only togehter for vacuumdb"
    finish 2
}
if ($full -and $analyze_in_stages) {
    writeLogMessage "ERROR`t You cannot specify --full and --analyze-in-stages togehter for vacuumdb"
    finish 2
}

writeLogMessage "INFO`t Creating Scheduled Task '$TaskName'..."
Create_ScheduledTask_with_XML -Author $me -FilePathofScript $Executable -User $User -Password $password -TaskName $TaskName -TaskDescription $description -ExecutionTimeLimit "PT8H" -StartTime "02:00:00" -WeeksInterval 1 -DaysOfWeek @("Sunday") -ExitCode 701

finish 0