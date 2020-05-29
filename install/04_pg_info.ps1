
<#
.SYNOPSIS
  Create administrative views and useful functions
.DESCRIPTION
  Every object will be created in the public schema of 
  the target database.
.NOTES
  Last editor:  Enrico La Torre
#>

$lastchange="2020-05-29"

################################################################################
########################### CONFIGURATION PARAMETERS ###########################
################################################################################

# Set connection variables for PostgreSQL
$server = "localhost"
$PortNo = "5432"
$pguser = "postgres"
$database = "pg_admindb"

# Directory for log file
$logpath = "E:\pg_admindb\logs\installation"

# PowerShell library for PostgreSQL
$libname = "E:\pg_admindb\lib\powershell_postgresql_lib.psd1"

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

$cmd = @'
  SET client_min_messages = warning;

  -- GRANT SELECT RIGHTS TO db_owner
  GRANT SELECT ON pg_file_settings TO db_owner;
  GRANT SELECT ON pg_settings TO db_owner;
  GRANT EXECUTE ON FUNCTION pg_catalog.pg_show_all_file_settings() to db_owner;

  
  -- VIEW SHOWING ALL ACTIVE CONFIGURATION FILES
  DROP VIEW IF EXISTS public.conffiles;
  CREATE VIEW public.conffiles AS
  SELECT DISTINCT sourcefile
  FROM pg_settings
  WHERE sourcefile IS NOT NULL
  ORDER BY sourcefile;
  GRANT SELECT ON public.conffiles TO PUBLIC;
  COMMENT ON VIEW public.conffiles IS 'Show all active configuration files.';


  -- VIEW SHOWING CURRENT NON-DEFAULT SETTINGS
  DROP VIEW IF EXISTS public.non_default_settings;
  CREATE VIEW public.non_default_settings AS
  SELECT category, name, setting, unit, source, sourcefile, sourceline
  FROM pg_settings
  WHERE source <> 'default'
  ORDER BY 1;
  GRANT SELECT ON public.non_default_settings TO PUBLIC;
  COMMENT ON VIEW public.non_default_settings IS 'Show current non-default settings.';
  

  -- FUNCTION FOR RELOADING CONFIGURATION FILES IF FREE OF ERRORS
  DROP VIEW IF EXISTS public.config_reload;
  DROP FUNCTION IF EXISTS public.config_reload();
  CREATE FUNCTION public.config_reload() RETURNS SETOF text LANGUAGE plpgsql AS $body$
  DECLARE
    r text;
    noOfUnappliedSettings integer;
    noOfErrors integer;
  BEGIN
    SELECT COUNT(*) INTO NoOfErrors
    FROM pg_file_settings 
    WHERE error IS NOT NULL AND error <> 'setting could not be applied';
    
    IF NoOfErrors > 0 THEN
      FOR r IN SELECT 
        format ('%L in line %s of file %L, name: %s, setting %s', 
        error, sourceline, sourcefile, name, setting)
      FROM pg_file_settings 
      WHERE error IS NOT NULL AND error <> 'setting could not be applied'
      LOOP
        RETURN NEXT r;
      END LOOP;
      RETURN NEXT 'Number of errors: ' || NoOfErrors;
    END IF;

    IF NoOfErrors = 0 THEN
      SELECT pg_reload_conf() INTO r;
      SELECT COUNT(*) INTO NoOfUnappliedSettings
      FROM pg_file_settings f
      WHERE name IN (
        SELECT name FROM pg_settings
        WHERE pending_restart
      )
      AND setting <> (
        SELECT setting FROM pg_settings s
        WHERE s.name = f.name
      );
      FOR r IN SELECT 
        format ('Unapplied setting in line %s of file %L, name: %s, setting %s', 
        sourceline, sourcefile, name, setting)
      FROM pg_file_settings f
      WHERE name IN (
        SELECT name FROM pg_settings 
        WHERE pending_restart
      )
      AND setting <> (
        SELECT setting FROM pg_settings s
        WHERE s.name = f.name
      )
      LOOP
        RETURN NEXT r;
      END LOOP;
      IF NoOfUnappliedSettings = 0 THEN
        RETURN NEXT 'Configuration files have been successfully reloaded.';
      ELSE
        RETURN NEXT 'Number of unapplied settings: ' || NoOfUnappliedSettings;
        RETURN NEXT 'Please restart the server to apply these settings.';
      END IF;
    END IF;    
    RETURN;
  END;  
  $body$;
  COMMENT ON FUNCTION public.config_reload() IS 'Reload configuration without restart, if config files are error-free.';
  CREATE VIEW public.config_reload AS SELECT * from public.config_reload();
  COMMENT ON VIEW public.config_reload IS 'Reload configuration without restart, if config files are error-free.';


  -- VIEW TO SHOW OVERRIDDEN SETTINGS IN CONFIG FILES
  DROP VIEW IF EXISTS public.config_overridden;
  CREATE VIEW public.config_overridden AS 
  SELECT name, sourcefile ||':'|| sourceline || ', ' || setting  AS "config line", 
    (SELECT COALESCE (sourcefile || ':'|| sourceline, source) || ', ' || setting || COALESCE(' (unit: '||unit||')','') 
    FROM pg_settings s WHERE lower(s.name)=lower(f.name)
    ) AS "overridden by" 
  FROM pg_file_settings f
  WHERE NOT applied;
  COMMENT ON VIEW public.config_overridden IS 'Show configuration settings in file which are currently overridden by later entries.';
  

  -- VIEW TO TEST CONFIGURATION FILES FOR ERRORS
  DROP VIEW IF EXISTS public.config_test;
  CREATE VIEW public.config_test AS
  SELECT * FROM pg_file_settings WHERE error IS NOT NULL;
  COMMENT ON VIEW public.config_test IS 'Test configuration files for syntax errors.';
    

  -- FUNCTION TO KICK OUT ALL OTHER SESSIONS
  DROP FUNCTION IF EXISTS public.stop_sessions();
  CREATE FUNCTION public.stop_sessions() RETURNS BOOLEAN LANGUAGE SQL AS $body$
    SELECT pg_terminate_backend(pid)
    FROM pg_stat_activity
    WHERE pid <> pg_backend_pid();
  $body$;
  COMMENT ON FUNCTION public.stop_sessions() IS 'Stops all sessions except this one.';


  -- VIEW SHOWING CURRENT ACTIVITY ON THE SYSTEM
  DROP FUNCTION IF EXISTS public.pg_stat_activity();
  CREATE FUNCTION public.pg_stat_activity() RETURNS SETOF pg_stat_activity LANGUAGE SQL AS $body$
    SELECT * FROM pg_stat_activity;
  $body$;
  DROP VIEW IF EXISTS public.current_activity;
  CREATE VIEW public.current_activity AS
  SELECT
    datname AS "database",
    usename as "user",
    application_name AS "application",
    COALESCE(client_hostname || '(' || client_addr || ')', client_addr::TEXT) AS "client",
    backend_start::TIMESTAMP(0) AS "session start",
    query_start::TIMESTAMP(0) AS "query start",
    wait_event_type AS "wait event type",
    state,
    query
  FROM public.pg_stat_activity();
  GRANT SELECT ON public.current_activity TO PUBLIC;
  COMMENT ON VIEW public.current_activity IS 'Show current activity of the database system.';
  
  -- VIEW SHOWING CURRENT SESSIONS PER USER
  DROP VIEW IF EXISTS public.user_sessions;
  CREATE VIEW public.user_sessions AS 
  SELECT usename, COUNT(*), string_agg(pid::text, ', ') as pid, string_agg(datname,', ') AS database
  FROM pg_stat_activity 
  GROUP BY usename;
  COMMENT ON VIEW public.user_sessions IS 'Show current sessions per user.';
  

  -- VIEW SHOWING CURRENT QUERIES PER USER
  DROP VIEW IF EXISTS public.user_queries;
  CREATE VIEW public.user_queries AS
  SELECT usename, datname, query
  FROM pg_stat_activity 
  ORDER BY usename;
  GRANT SELECT ON public.user_queries TO PUBLIC;
  COMMENT ON VIEW public.user_queries IS 'Show current queries per user.';
  

  -- VIEW TO SHOW ROW COUNTS OF ALL NON-EMPTY TABLES
  DROP VIEW IF EXISTS public.show_row_counts;
  CREATE VIEW public.show_row_counts AS
  SELECT nspname AS schemaname,relname,reltuples::numeric
  FROM pg_class C LEFT JOIN pg_namespace N ON (N.oid = C.relnamespace)
  WHERE
    relkind='r' AND reltuples > 0 
  ORDER BY reltuples DESC;
  GRANT SELECT ON public.show_row_counts TO PUBLIC;
  COMMENT ON VIEW public.show_row_counts IS 'Show estimated row counts of all non-empty table';


  -- VIEW TO SHOW EMPTY TABLES
  DROP VIEW  IF EXISTS public.show_empty_tables;
  CREATE VIEW public.show_empty_tables AS
  SELECT nspname AS schemaname,relname,reltuples
  FROM pg_class C LEFT JOIN pg_namespace N ON (N.oid = C.relnamespace)
  WHERE 
    relkind='r' AND reltuples = 0;
  GRANT SELECT ON public.show_empty_tables TO PUBLIC;
  COMMENT ON VIEW public.show_empty_tables IS 'Show empty tables';


  -- VIEW TO SHOW UNUSED INDEXES WHICH AREN'T PRIMARY KEYS
  DROP VIEW IF EXISTS public.unused_index;
  CREATE VIEW public.unused_index AS
  SELECT relname, indexrelname 
  FROM pg_stat_user_indexes 
  WHERE relname || '_pkey' <> indexrelname AND idx_scan = 0;
  COMMENT ON VIEW public.unused_index IS 'Show unused non-primary-key indexes.';

  -- VIEW TO SHOW TABLES WITH MORE THAN 1000 ROWS WHICH HAVE ONLY BEEN
  -- SEQUENTIALLY SCANNED, BUT NOT BY INDEX
  DROP VIEW IF EXISTS public.seq_scan_tables;
  CREATE VIEW public.seq_scan_tables AS
  SELECT relname, seq_scan, n_live_tup 
  FROM pg_stat_user_tables 
  WHERE idx_scan = 0 AND n_live_tup > 1000;
  GRANT SELECT ON public.seq_scan_tables TO PUBLIC;
  COMMENT ON VIEW public.seq_scan_tables IS 'Show tables with more than 1000 rows which only have been sequentially scanned.';
  
  -- VIEW TO SHOW USAGE OF INDEXES, SHOW USAGE COUNT AS TIMES_USED
  DROP VIEW IF EXISTS public.index_usage;
  CREATE VIEW public.index_usage AS 
  SELECT idx_scan AS TIMES_USED, indexrelid::regclass AS INDEX, relid::regclass AS TABLE
  FROM pg_stat_user_indexes NATURAL JOIN pg_index
  WHERE idx_scan > 0 AND NOT indisunique
  ORDER BY 2;
  GRANT SELECT ON public.index_usage TO PUBLIC;
  COMMENT ON VIEW public.index_usage IS 'Show usage count of indexes.';
  

  -- VIEW TO SHOW SIZE OF DATABASES
  DROP VIEW IF EXISTS public.db_sizes;
  CREATE VIEW public.db_sizes AS
  SELECT datname as "database name", 
    pg_size_pretty(pg_database_size(datname)) AS size
  FROM pg_database
  WHERE NOT datistemplate;
  GRANT SELECT ON public.db_sizes TO PUBLIC;
  COMMENT ON VIEW public.db_sizes IS 'Show size of databases (except template dbs)';
  

  -- VIEW REPORTING TABLE SIZES
  DROP VIEW IF EXISTS public.table_sizes;
  CREATE VIEW public.table_sizes AS
  SELECT oid, table_schema as schema, table_name, row_estimate::numeric
    , pg_size_pretty(total_bytes) AS total
    , pg_size_pretty(index_bytes) AS INDEX
    , pg_size_pretty(toast_bytes) AS toast
    , pg_size_pretty(table_bytes) AS TABLE
  FROM (
    SELECT *, total_bytes-index_bytes-COALESCE(toast_bytes,0) AS table_bytes FROM (
      SELECT c.oid,nspname AS table_schema, relname AS table_name
              , c.reltuples AS row_estimate
              , pg_total_relation_size(c.oid) AS total_bytes
              , pg_indexes_size(c.oid) AS index_bytes
              , pg_total_relation_size(reltoastrelid) AS toast_bytes
          FROM pg_class c
          LEFT JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE relkind = 'r'
      ) a
    ) a
  ORDER BY total_bytes DESC;
  GRANT SELECT ON public.table_sizes TO PUBLIC;
  COMMENT ON VIEW public.table_sizes IS 'Show sizes of tables';


  -- VIEW TO SHOW ROLE NAMES AND ATTRIBUTES
  DROP VIEW IF EXISTS public.role_attributes;
  CREATE VIEW public.role_attributes AS
  SELECT r.rolname, COALESCE(pg_catalog.shobj_description(r.oid, 'pg_authid'), '') AS description,
  trim (
  CASE WHEN rolcanlogin   THEN 'LOGIN '      ELSE '' END ||
  CASE WHEN rolsuper      THEN 'SUPERUSER '  ELSE '' END ||
  CASE WHEN rolcreatedb   THEN 'CREATEDB '   ELSE '' END ||
  CASE WHEN rolcreaterole THEN 'CREATEROLE ' ELSE '' END)
  AS attributes
  FROM pg_catalog.pg_roles r
  WHERE r.rolname !~ '^pg_'
  ORDER BY 1;
  COMMENT ON VIEW public.role_attributes IS 'Show role names, real names and attributes.';


  -- VIEW TO SHOW ROLE NAMES AND MEMBERSHIPS
  DROP VIEW IF EXISTS public.role_memberships;
  CREATE VIEW public.role_memberships AS
  SELECT r.rolname, COALESCE(pg_catalog.shobj_description(r.oid, 'pg_authid'), '') AS description,
    NULLIF(ARRAY_TO_STRING (ARRAY(SELECT b.rolname
        FROM pg_catalog.pg_auth_members m
        JOIN pg_catalog.pg_roles b ON (m.roleid = b.oid)
        WHERE m.member = r.oid), ', '), '') as memberof
  FROM pg_catalog.pg_roles r
  WHERE r.rolname !~ '^pg_'
  ORDER BY 1;
  COMMENT ON VIEW public.role_memberships IS 'Show role names, real names and role memberships.';


  -- VIEW TO SHOW ALL GROUP ROLES AND MEMBERSHIP
  DROP VIEW IF EXISTS public.groups_memberships;
  CREATE VIEW public.groups_memberships AS
  SELECT r.rolname, pg_catalog.shobj_description(r.oid, 'pg_authid') AS description,
    ARRAY_TO_STRING (ARRAY(SELECT b.rolname
        FROM pg_catalog.pg_auth_members m
        JOIN pg_catalog.pg_roles b ON (m.roleid = b.oid)
        WHERE m.member = r.oid), ', ') as memberof,
    CASE WHEN rolsuper THEN 'is Superuser' ELSE '' END AS "special"
  FROM pg_catalog.pg_roles r
  WHERE r.rolname !~ '^pg_' AND NOT r.rolcanlogin
  ORDER BY 1;
  COMMENT ON VIEW public.groups_memberships IS 'Show group names, description and memberships.';
  
    
  -- VIEW TO GET PRIMARY KEY AND UNIQUE CONSTRAINTS FROM INFORMATION SCHEMA
  DROP VIEW IF EXISTS public.primary_unique_constraints;
  CREATE VIEW public.primary_unique_constraints AS
  SELECT kcu.TABLE_SCHEMA, kcu.TABLE_NAME, kcu.CONSTRAINT_NAME, 
         tc.CONSTRAINT_TYPE, kcu.COLUMN_NAME, kcu.ORDINAL_POSITION
    FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS as tc
    JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE as kcu
      ON kcu.CONSTRAINT_SCHEMA = tc.CONSTRAINT_SCHEMA
     AND kcu.CONSTRAINT_NAME = tc.CONSTRAINT_NAME
     AND kcu.TABLE_SCHEMA = tc.TABLE_SCHEMA
     AND kcu.TABLE_NAME = tc.TABLE_NAME
  WHERE tc.CONSTRAINT_TYPE in ('PRIMARY KEY', 'UNIQUE')
  ORDER BY kcu.TABLE_SCHEMA, kcu.TABLE_NAME, tc.CONSTRAINT_TYPE, kcu.CONSTRAINT_NAME, kcu.ORDINAL_POSITION;
  GRANT SELECT ON public.primary_unique_constraints TO PUBLIC;
  COMMENT ON VIEW public.primary_unique_constraints IS 'Show primary key and unique constraints.';
   

  -- VIEW TO GET ROLE HIERARCHY TOP TO BOTTOM
  DROP VIEW IF EXISTS public.roles_from_top;
  CREATE VIEW public.roles_from_top AS
    WITH RECURSIVE rollen (oid, role, canlogin) AS (
    -- Startpunkte der Hierarchien
    SELECT oid, rolname::text, rolcanlogin
    FROM pg_catalog.pg_roles
    WHERE rolname NOT IN ('postgres', 'Administrator') AND rolname !~ '^pg_'
    AND oid NOT IN (SELECT member FROM pg_catalog.pg_auth_members)
  UNION
    -- rekursive Unterabfrage
    SELECT b.oid, r.role || '->' || b.rolname, b.rolcanlogin
    FROM rollen r
     JOIN pg_catalog.pg_auth_members m ON (r.oid = m.roleid)
     JOIN pg_catalog.pg_roles b ON (b.oid = m.member)
    WHERE r.role NOT IN ('postgres', 'Administrator') 
      AND r.role !~ '^pg_' AND r.oid <> m.member  
  )
  SELECT *, pg_catalog.shobj_description(oid, 'pg_authid') AS description 
  FROM rollen 
  ORDER BY 3, 2;
  COMMENT ON VIEW public.roles_from_top IS 'Show role hierarchy starting from the top.';


  -- VIEW TO GET ROLE HIERARCHY BOTTOM TO TOP
  DROP VIEW IF EXISTS public.roles_from_bottom;
  CREATE VIEW public.roles_from_bottom AS
  WITH RECURSIVE rollen (oid, role, description, membership, canlogin, ebene) AS (
    -- Startpunkte der Hierarchien
    SELECT oid, rolname, 
        pg_catalog.shobj_description(oid, 'pg_authid') AS description,
        ''::text COLLATE "C", rolcanlogin, 0
    FROM pg_catalog.pg_roles
    WHERE rolname NOT IN ('postgres', 'Administrator') AND rolname !~ '^pg_'
    AND rolcanlogin
  UNION
    -- rekursive Unterabfrage
    SELECT b.oid, r.role, r.description, b.rolname, b.rolcanlogin, ebene+1
    FROM rollen r
     JOIN pg_catalog.pg_auth_members m ON (r.oid = m.member)
     JOIN pg_catalog.pg_roles b ON (b.oid = m.roleid)
    WHERE r.role NOT IN ('postgres', 'Administrator') 
      AND r.role !~ '^pg_'
      AND r.oid <> b.oid
  ), mitgliedschaften AS (
    SELECT role, description, canlogin, membership || ' (' || max(ebene) || ')' as membership, max(ebene) AS ebene 
    FROM rollen
    WHERE membership <> ''
    GROUP BY role, description, membership, canlogin
  )
  SELECT role, description, canlogin, string_agg (membership, ', ' ORDER BY ebene DESC, membership ASC) AS membership
  FROM mitgliedschaften
  GROUP BY role, description, canlogin
  ORDER BY 1;
  COMMENT ON VIEW public.roles_from_bottom IS 'Show role hierarchy starting from the bottom.';


  -- VIEW SHOWING INFORMATION ABOUT LOGGING
  DROP VIEW IF EXISTS public.log_info;
  CREATE VIEW public.log_info AS
  SELECT 'log_destination' AS setting, (select setting from pg_settings where name='log_destination') AS value
  UNION ALL
  SELECT 'logging_collector' AS setting, (select setting from pg_settings where name='logging_collector') AS value
  UNION ALL
    SELECT 'data_dir', (select setting from pg_settings where name='data_directory')
  UNION ALL
    SELECT 'log_dir', (select setting from pg_settings where name='log_directory')
  UNION ALL
    SELECT 'log_file', (select setting from pg_settings where name='log_filename')
  UNION ALL
    SELECT 'log_line_prefix', (select setting from pg_settings where name='log_line_prefix')
  UNION ALL
    SELECT 'log_timezone', (select setting from pg_settings where name='log_timezone')
  UNION ALL
    SELECT 'log_rotation_age', to_char(((select setting from pg_settings where name='log_rotation_age') || ' minutes')::interval, 'HH24:MI:SS')
  UNION ALL
    SELECT 'log_rotation_size', current_setting('log_rotation_size');
    COMMENT ON VIEW public.log_info IS 'Show information about logging.';

  
  -- FUNCTION TO ACQUIRE SUPERUSER RIGHTS IF PERMITTED
  DROP FUNCTION IF EXISTS public.admin();
  CREATE FUNCTION public.admin() RETURNS VOID LANGUAGE SQL AS $body$
  set role to "ADMIN";
  $body$;
  COMMENT ON FUNCTION public.admin() IS 'Acquire SUPERUSER rights if permitted.';

  -- VIEW SHOWING UPTIME OF SERVER
  DROP VIEW IF EXISTS public.uptime;
  CREATE VIEW public.uptime AS 
    SELECT 'started ' || pg_postmaster_start_time()::timestamp(0) ||  
          ', running for ' || date_trunc('second', current_timestamp - pg_postmaster_start_time()) 
    AS "postgresql uptime";
  GRANT SELECT ON public.uptime TO PUBLIC; 
  COMMENT ON VIEW public.uptime IS 'Show since when and for how long the server has been running.';

  

  -- VIEW SHOWING INFORMATION ABOUT VIEWS IN PUBLIC SCHEMA
  DROP VIEW IF EXISTS public.viewlist;
  CREATE VIEW public.viewlist AS
  SELECT relname as "view name", pg_catalog.obj_description(oid, 'pg_class') as "description"
  FROM pg_class
  WHERE relkind = 'v'
  AND relnamespace = (SELECT oid FROM pg_namespace WHERE nspname='public')
  ORDER BY relname;
  GRANT SELECT ON public.viewlist TO PUBLIC; 
  COMMENT ON VIEW public.viewlist IS 'Show information about views in PUBLIC schema.';



  -- LOAD EXTENSION tablefunc (for crosstab and other functions)
  SET search_path to public;
  CREATE EXTENSION IF NOT EXISTS tablefunc;
  
'@
addCmd $cmd

########################################################################
# statistics functions and views for performance monitoring
addCmd "--"
addCmd "-- statistics functions and views --"

$cmd = @"
CREATE TYPE public.pg_stat_statements_type as (
  userid oid,
  dbid oid,
  queryid bigint,
  query text,
  calls bigint,
  total_time double precision,
  min_time double precision,
  max_time double precision,
  mean_time double precision,
  stddev_time double precision,
  rows bigint,
  shared_blks_hit bigint,
  shared_blks_read bigint,
  shared_blks_dirtied bigint,
  shared_blks_written bigint,  
  local_blks_hit bigint,
  local_blks_read bigint,
  local_blks_dirtied bigint,
  local_blks_written bigint,
  temp_blks_read bigint,
  temp_blks_written bigint,
  blk_read_time double precision,
  blk_write_time double precision
);

CREATE FUNCTION public.get_statistics() RETURNS SETOF PUBLIC.pg_stat_statements_type
LANGUAGE plpgsql AS `$body`$
  BEGIN
    BEGIN
      RETURN QUERY SELECT * FROM pg_stat_statements;
    EXCEPTION
      WHEN sqlstate '55000' THEN
        RAISE 'Extension pg_stat_statements was not preloaded using "shared_preload_libraries" configuration.' USING ERRCODE = '55000';
      WHEN sqlstate '42P01' THEN
        RAISE EXCEPTION E'Extension pg_stat_statements is not installed. Please execute "CREATE EXTENSION pg_stat_statements SCHEMA public;"\n        if you want to collect statistics.\n        Later you might execute "DROP EXTENSION pg_stat_statements;" to get rid of it again.';
      WHEN OTHERS THEN
        RAISE EXCEPTION 'Try to execute "SELECT * FROM pg_stat_statements" to get more information about the problem.';
    END;
  END;
`$body`$;

CREATE VIEW public.slow_queries AS
  SELECT 
    round((100* total_time / sum(total_time) over())::numeric,2) percent,
    round(total_time::numeric,2) as "total (ms)",
    calls,
    round(mean_time::numeric,2) as "mean (ms)",
    queryid,
    substring(query,1,100) as "Query"
  FROM pg_stat_statements
  ORDER BY total_time DESC
  LIMIT 10;
  COMMENT ON VIEW public.slow_queries IS 'Show top 10 queries from statistics by total execution time.';
"@
addCmd $cmd


########################################################################
# Function for accessing setting 'cluster_name' from SQL
addCmd "--"
addCmd "-- Function providing access to setting 'cluster_name' --"
$cmd = @'
  CREATE FUNCTION public.servername() RETURNS VARCHAR LANGUAGE sql AS $$
    SELECT setting FROM pg_settings WHERE name = 'cluster_name';
  $$;

'@
addCmd $cmd

# Execute the commands on the database
writeLogMessage "INFO`t Going to execute SQL commands..."
ExecutePSQL -sqlCommands $script:cmds -server $server -PortNo $PortNo -user $pguser -database $database 

finish 0