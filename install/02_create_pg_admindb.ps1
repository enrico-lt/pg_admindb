<#
.SYNOPSIS
  Installation Task of PostgreSQL Database in version 12
.DESCRIPTION
Preconditions for executing this script:
  * PostgreSQL server is installed.
    
Sets the correct time zone and clustername for cluster. 
The database pg_admindb is created with default MS SQL like 
predefined roles 

.NOTES
  Date:         2017-09-12
  Last editor:  Enrico La Torre 
#>

$lastchange="2020-05-29"

################################################################################
########################### CONFIGURATION PARAMETERS ###########################
################################################################################

# Major version of PostgreSQL
$pgVersion = "12"

# Data directory of PostgreSQL
$PgDataDir="G:\databases\PostgreSQL\$pgVersion"
# Program directory of PostgreSQL
# $PgProgDir="C:\Program Files\PostgreSQL\$pgVersion"

$adSyncRole = "adsync"

# Set connection variables for PostgreSQL
$server = "localhost"
$PortNo = "5432"
$pguser = "postgres"
$database = "postgres"

# PowerShell library for PostgreSQL
$libname = "E:\pg_admindb\lib\powershell_postgresql_lib.psd1"

# Directory for log file
$logpath = "E:\pg_admindb\logs\installation"

# Service account which runs the postgres service
$useronly = "USER"
# Role for creating backups of databases
$backuprole = $useronly 

# Password for postgres
$env:PGPASSWORD = Read-Host -Prompt "Please enter password for PostgreSQL superuser 'postgres'"

# Import PostgreSQL Powershell library
try {
  Import-Module -Name $libname -Force
  $lib = Get-Module -ListAvailable $libname
} catch {
  Throw "ERROR`t Cannot import powershell library '$libname'"
}

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

# Script variable for commands
$script:cmds = ''
# Add a command to the script variable cmds
Function addCmd ([string] $cmd) {
   $script:cmds += ($cmd + "`r`n")
} # addCmd

################################################################################
##################################### MAIN #####################################
################################################################################
$ErrorActionPreference = "Stop"

$me=whoami
writeLogMessage ""
writeLogMessage "START (script version dated $lastchange, run by $me )"
writeLogMessage "INFO`t Library Version $($lib.Version.Major).$($lib.Version.Minor), last change $($lib.PrivateData.lastchange)"
writeLogMessage "INFO`t Logfile will be written to $script:logfile"

# default value = "silentlycontinue", further values: stop, inquire
$debugpreference = "continue"

########################################################################
# creating special role storeinstaller
addCmd "--------------------------------------------------"
addCmd "-- INITIAL CONFIGURATION OF POSTGRESQL FOR pg_admindb --"
addCmd "--------------------------------------------------"
addCmd "--"
addCmd "SET client_min_messages TO warning;"
addCmd "--"
# Add local administrators as superuser
addCmd "CREATE ROLE system LOGIN SUPERUSER;"
addCmd 'CREATE ROLE "SYSTEM" LOGIN SUPERUSER;'
addCmd "--"
addCmd "-- special role db_owner, owner of database pg_admindb and all objects within  --"
addCmd "CREATE ROLE db_owner;" # db_owner may become owner of a new database.
addCmd "--"

addCmd 'CREATE ROLE "ADMIN" SUPERUSER;'
addCmd 'GRANT db_owner TO "ADMIN";'

addCmd "-- add group role db_backupoperator, may execute backup functions, rotate log files and switch xlog --"
addCmd "-- when connected to database postgres (same granted for database pg_admindb below)            --"
addCmd "CREATE ROLE db_backupoperator;"
addCmd "GRANT EXECUTE ON FUNCTION pg_start_backup(text, boolean, boolean), pg_stop_backup() TO db_backupoperator;"
addCmd "GRANT EXECUTE ON FUNCTION pg_rotate_logfile() TO db_backupoperator;"
addCmd "GRANT EXECUTE ON FUNCTION pg_switch_wal() TO db_backupoperator;"
# To use pg_dumpall --globals-only
addCmd "GRANT SELECT ON ALL TABLES in SCHEMA pg_catalog to db_backupoperator;"
addCmd "GRANT SELECT ON ALL SEQUENCES in SCHEMA pg_catalog to db_backupoperator;"

# PostgreSQL Service Account
addCmd ('CREATE ROLE "'+$backuprole+'" LOGIN SUPERUSER;')
addCmd ('GRANT db_backupoperator TO "'+$backuprole+'";')

########################################################################
# creating database pg_admindb
addCmd "--"
addCmd "-- database creation and connection --"
addCmd 'CREATE DATABASE pg_admindb OWNER db_owner;'
addCmd "\connect pg_admindb"
addCmd "--"
addCmd "--"
addCmd "-- creating standard extensions --"
addCmd "CREATE EXTENSION pg_stat_statements SCHEMA public;"
addCmd "CREATE EXTENSION tablefunc SCHEMA public;"

addCmd "--"
addCmd "-- BEGIN OF ROLE CREATION AND GRANTS --"


# special role for AD sync, can manage other roles
addCmd "--"
addCmd "-- special role for AD sync --"
addCmd ("CREATE ROLE " + $adSyncRole + " SUPERUSER LOGIN;")

# standard group roles
$objectCreatorRoles = ('postgres, "ADMIN", "SYSTEM", system, db_owner, ' + $adSyncRole)

addCmd "--"
addCmd "-- group role db_backupoperator, may execute backup functions, rotate log files and switch WAL --"
addCmd "-- when connected to database pg_admindb (same granted for database postgres above)         --"
addCmd "GRANT EXECUTE ON FUNCTION pg_start_backup(text, boolean, boolean), pg_stop_backup() TO db_backupoperator;"
addCmd "GRANT EXECUTE ON FUNCTION pg_rotate_logfile() TO db_backupoperator;"
addCmd "GRANT EXECUTE ON FUNCTION pg_switch_wal() TO db_backupoperator;"
# To use pg_dump
addCmd "GRANT SELECT ON ALL TABLES IN SCHEMA public TO db_backupoperator;"
addCmd "GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO db_backupoperator;"
addCmd "--"
addCmd "-- general roles and grants --"

addCmd "CREATE ROLE db_datareader;"
addCmd "GRANT SELECT ON ALL TABLES IN SCHEMA public TO db_datareader;"

addCmd "CREATE ROLE db_datawriter;"
addCmd "GRANT ALL ON ALL TABLES IN SCHEMA public TO db_datawriter;"
addCmd "GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO db_datawriter;"


# Default privileges for new objects that are created by $objectCreatorRoles, will be enhanced by event trigger
addCmd ("ALTER DEFAULT PRIVILEGES FOR ROLE " + $objectCreatorRoles + " IN SCHEMA public GRANT SELECT ON TABLES TO db_datareader, db_backupoperator;")
addCmd ("ALTER DEFAULT PRIVILEGES FOR ROLE " + $objectCreatorRoles + " IN SCHEMA public GRANT SELECT ON SEQUENCES TO db_backupoperator;")
addCmd ("ALTER DEFAULT PRIVILEGES FOR ROLE " + $objectCreatorRoles + " IN SCHEMA public GRANT ALL ON TABLES TO db_datawriter, db_owner;")
addCmd ("ALTER DEFAULT PRIVILEGES FOR ROLE " + $objectCreatorRoles + " IN SCHEMA public GRANT ALL ON SEQUENCES TO db_datawriter, db_owner;")

addCmd "--"
addCmd "-- END OF ROLE CREATION AND GRANTS --"
addCmd "--"

# Execute the commands on the database
writeLogMessage "INFO`t Going to execute SQL commands..."
ExecutePSQL -sqlCommands $script:cmds -server $server -PortNo $PortNo -user $pguser -database $database 

finish 0