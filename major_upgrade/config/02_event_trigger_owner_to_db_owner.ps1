
<#
.SYNOPSIS
  Create an event trigger for automatic ownership change 
  and permissions on new objects
.DESCRIPTION
 THIS FILE CREATES AN EVENT TRIGGER FUNCTION PLUS AN EVENT TRIGGER
 TO MAKE SURE THAT ALL SUBSEQUENTLY CREATED OBJECTS IN DATABASE
 WILL BE OWNED BY ROLE db_owner, NO MATTER
 WHICH ROLE ACTUALLY HAS CREATED THEM.

.NOTES
  Date:         2017-09-12
  Last editor:  Enrico La Torre
#>

$lastchange = "2020-05-29"

################################################################################
########################### CONFIGURATION PARAMETERS ###########################
################################################################################


# Set connection variables for PostgreSQL
$server = "localhost"
$PortNo = "5433"
$pguser = "postgres"
$database = "pg_admindb"

# PowerShell library for PostgreSQL
$libname = "E:\pg_admindb\lib\powershell_postgresql_lib.psd1"

# Directory for log file
$logpath = "E:\pg_admindb\logs\installation"

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

# script variable for commands
$script:cmds = ''
########################################################################
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

# database commands follow
# LOGGING CREATION OF NEW OBJECTS INTO A TABLE
# REMARK: dropping of objects could be logged as well.

$cmd = @'
SET client_min_messages TO warning;
DROP EVENT TRIGGER IF EXISTS trg_create_set_owner;
DROP FUNCTION IF EXISTS trg_create_set_owner_to_db_owner();
DROP TABLE IF EXISTS PUBLIC.object_creation_log;

CREATE TABLE PUBLIC.object_creation_log (
  id               BIGSERIAL PRIMARY KEY,
  create_time      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by_user  TEXT NOT NULL DEFAULT SESSION_USER,
  created_in_role  TEXT NOT NULL DEFAULT CURRENT_USER,
  new_object       TEXT NOT NULL
);
ALTER TABLE PUBLIC.object_creation_log OWNER TO db_owner;														 
GRANT SELECT ON PUBLIC.object_creation_log TO db_datareader;

-- Set up an event trigger in order to make all new objects owned by
-- db_owner, so that the owner is the same for all objects.

CREATE OR REPLACE FUNCTION public.trg_create_set_owner_to_db_owner()
  RETURNS event_trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
AS $body$
DECLARE
  obj RECORD;
  obj_owner TEXT;
  no_of_owning_tables INTEGER;
BEGIN
  FOR obj IN SELECT * FROM pg_event_trigger_ddl_commands() WHERE command_tag LIKE 'CREATE %' LOOP
    -- If the object is an extension, a foreign data wrapper or is created as a temporary object, don't bother.
    IF obj.object_type = 'extension' OR obj.object_type = 'foreign data wrapper' OR obj.schema_name LIKE 'pg_temp%' THEN
      CONTINUE;
    END IF;
    -- If the object is a sequence tied to a table, don't bother.
    IF obj.object_type = 'sequence' THEN
      SELECT COUNT(*) INTO no_of_owning_tables
      FROM   pg_catalog.pg_depend    d
      JOIN   pg_catalog.pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
      WHERE  d.objid = obj.object_identity::regclass
      AND    d.refobjsubid > 0;
      IF no_of_owning_tables > 0 THEN
        RAISE NOTICE 'The new sequence "%" is tied to a table.', obj.object_identity;
        CONTINUE;
      END IF;
    END IF;
    -- in case the creation of new objects is to be logged into a table
    INSERT INTO PUBLIC.object_creation_log (new_object)
    VALUES (obj.object_type || ' ' || obj.object_identity);
    BEGIN
      RAISE NOTICE 'Changing ownership of new object: ALTER % % OWNER TO db_owner; created by %', obj.object_type, obj.object_identity, current_user;
      EXECUTE format('ALTER %s %s OWNER TO db_owner;', obj.object_type, obj.object_identity);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Could not alter user of new % %', obj.object_type, obj.object_identity;
    END;
    IF obj.object_type = 'table' THEN
      EXECUTE format ('GRANT SELECT ON %s TO db_datareader;', obj.object_identity);
      EXECUTE format ('GRANT SELECT ON %s TO db_backupoperator;', obj.object_identity);
      EXECUTE format ('GRANT ALL ON %s TO db_datawriter;', obj.object_identity);
    END IF;
    IF obj.object_type = 'sequence' THEN
      EXECUTE format ('GRANT ALL ON SEQUENCE %s TO db_datawriter;', obj.object_identity);
      EXECUTE format ('GRANT SELECT ON SEQUENCE %s TO db_backupoperator;', obj.object_identity);
    END IF;
 END LOOP;
END;
$body$;

CREATE EVENT TRIGGER trg_create_set_owner
  ON ddl_command_end
  EXECUTE PROCEDURE trg_create_set_owner_to_db_owner();
'@
addCmd $cmd


# Execute the commands on the database
writeLogMessage "INFO`t Going to execute SQL commands..."
ExecutePSQL -sqlCommands $script:cmds -server $server -PortNo $PortNo -user $pguser -database $database 

finish 0
