<#
.SYNOPSIS
  PowerShell Script for creating the Configuration of PostgreSQL 12
.DESCRIPTION
  Creates files in data directory and conf.d directory within data directory.
.NOTES
    Author:			Enrico La Torre
    Date:			  2020-02-17
#>

################################################################################
########################### CONFIGURATION PARAMETERS ###########################
################################################################################
$lastchange="2020-05-29"

# Major Version
$pgMajorVersion = "12"
# Data directory of PostgreSQL
$PgDataDir="G:\databases\PostgreSQL\$pgMajorVersion"
# Port of PostgreSQL cluster
$pgPort = 5432

# Directory for log file
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
setLogFileName -logfile $script:logfile


################################################################################
##################################### MAIN #####################################
################################################################################

$me=whoami
writeLogMessage ""
writeLogMessage "START (script version dated $lastchange, run by $me )"
writeLogMessage "INFO`t Library Version $($lib.Version.Major).$($lib.Version.Minor), last change $($lib.PrivateData.lastchange)"
writeLogMessage "INFO`t Logfile will be written to $script:logfile"

# Creating File Name 'conf.d\00ConnectionSettings.conf' ...
$fileContent = @"
##############################################################
# Connection Settings
##############################################################
# version 1.0 for PostgreSQL 12
# date 2019-12-23
##############################################################

# max number of connections (some are only for superuser)
# max_connections = 100   # (change requires restart)

listen_addresses = '*'		# what IP address(es) to listen on;
				                	# comma-separated list of addresses;
				                	# defaults to 'localhost'; use '*' for all
				                	# (change requires restart)
port = $pgPort		        # (change requires restart)

"@
try {
  $fileContent | Out-File $PgDataDir\conf.d\00ConnectionSettings.conf -Encoding Default 
} catch {
  writeLogMessage "ERROR`t Can not create config file"
  finish 1
}

# Creating File Name 'conf.d\01memory.conf' ...
$fileContent = @'
##############################################################
# Memory Settings
##############################################################
# version 1.0 for PostgreSQL 12
# date 2019-12-23
##############################################################

# shared_buffers should be 25% of available RAM
shared_buffers = '1024 MB' 

# effective_cache_size should be 75% of available RAM
effective_cache_size = 3GB
work_mem = 64MB
maintenance_work_mem = 256MB

'@
try {
  $fileContent | Out-File $PgDataDir\conf.d\01memory.conf -Encoding Default 
} catch {
  writeLogMessage "ERROR`t Can not create config file"
  finish 1
}


# Creating File Name 'conf.d\02wal.conf' ...
$fileContent = @'
##############################################################
# WAL Settings
##############################################################
# version 1.0 for PostgreSQL 12
# date 2019-12-23
##############################################################

# Call fsync() at each commit, forcing write-through of any disk write cache
wal_sync_method = fsync_writethrough 

wal_level = replica
archive_mode = on
archive_command = 'copy %p I:\\Backup\\PostgreSQL-WAL-Archive\\%f'
archive_timeout = 1h
max_wal_senders = 10

wal_compression = on

# If wal_writer_flush_after is set to 0 then WAL data is flushed immediately
wal_writer_flush_after = 0
#wal_writer_delay = 200ms # default

'@
try { 
  $fileContent | Out-File $PgDataDir\conf.d\02wal.conf-deactivated -Encoding Default 
} catch {
  writeLogMessage "ERROR`t Can not create config file"
  finish 1
}

# Creating File Name 'conf.d\03checkpoints.conf' ...
$fileContent = @'
##############################################################
# Checkpoint Settings
##############################################################
# version 1.0 for PostgreSQL 12
# date 2019-12-23
##############################################################

# Maximum time between automatic WAL checkpoints
checkpoint_timeout = 15min
# Specifies the target of checkpoint completion, as a fraction of total time between checkpoints
checkpoint_completion_target = 0.9

min_wal_size = 2GB
max_wal_size = 4GB


'@
try {
  $fileContent | Out-File $PgDataDir\conf.d\03checkpoints.conf -Encoding Default 
} catch {
  writeLogMessage "ERROR`t Can not create config file"
  finish 1
}



# Creating File Name 'conf.d\04monitoring.conf' ...
$fileContent = @'
##############################################################
# Monitoring settings
##############################################################
# version 1.0 for PostgreSQL 12
# date 2019-12-23
##############################################################

shared_preload_libraries = 'pg_stat_statements'		# (change requires restart)
track_io_timing = on
track_functions = pl 

# save the first 8192 bytes of queries (instead of the default of 1024)
track_activity_query_size = 8192

'@
try {
  $fileContent | Out-File $PgDataDir\conf.d\04monitoring.conf -Encoding Default 
} catch {
  writeLogMessage "ERROR`t Can not create config file"
  finish 1
}



# Creating File Name 'conf.d\05logging.conf' ...
$fileContent = @'
##############################################################
# logging settings
##############################################################
# version 1.0 for PostgreSQL 12
# date 2019-12-23
##############################################################

# This is used when logging to stderr:
logging_collector = on

# log line prefix as recommended by pgbadger
log_line_prefix = '%t [%p]: [%l] %quser=%u,db=%d,app=%a,client=%h '

#### we start to log more than default
######################################

# Log checkpoints (including some statistics like number of buffers written and time spent)
log_checkpoints = on

# Log when clients connect and disconnect
log_connections = on
log_disconnections = on

# Log hostname, not only IP address of client. Interesting since
# SSL connections from other machines are allowed.
log_hostname = on

# Log creation of temporary files bigger than 100 kB
log_temp_files = 100kB


#log_min_duration_statement = 1000	# -1 is disabled, 0 logs all statements
    # and their durations, > 0 logs only
    # statements running at least this number
    # of milliseconds

# AUTO_EXPLAIN settings

# Make sure this doesn't overwrite other session_preload_libraries settings
# and isn't overwritten by other session_preload_libraries settings!
#session_preload_libraries = 'auto_explain'

# Log plan when duration > 8 seconds (8000 ms), change as needed.
#auto_explain.log_min_duration = 8000

'@
try {
  $fileContent | Out-File $PgDataDir\conf.d\05logging.conf -Encoding Default 
} catch {
  writeLogMessage "ERROR`t Can not create config file"
  finish 1
}


# Creating File Name 'conf.d\06ssl.conf' ...
$fileContent = @'
##############################################################
# SSL/TLS settings
##############################################################
# version 1.0 for PostgreSQL 12
# date 2019-12-23
##############################################################

#ssl = off
#ssl_ca_file = ''
#ssl_cert_file = 'server.crt'
#ssl_crl_file = ''
#ssl_key_file = 'server.key'
#ssl_ciphers = 'HIGH:MEDIUM:+3DES:!aNULL' # allowed SSL ciphers
#ssl_prefer_server_ciphers = on
#ssl_ecdh_curve = 'prime256v1'
#ssl_dh_params_file = ''
#ssl_passphrase_command = ''
#ssl_passphrase_command_supports_reload = off

ssl = on
ssl_cert_file = 'ssl-cert-snakeoil.pem'
ssl_key_file = 'ssl-cert-snakeoil.key'   

'@
try {
  $fileContent | Out-File $PgDataDir\conf.d\06ssl.conf -Encoding Default 
} catch {
  writeLogMessage "ERROR`t Can not create config file"
  finish 1
}

# Creating File Name 'conf.d\07cluster_name.conf' ...
$fileContent = @"
##############################################################
# SET CLUSTER_NAME LIKE COMPUTER NAME
##############################################################
# version 1.0 for PostgreSQL 12
# date 2019-12-23
##############################################################

# 'computer name' setting from Windows system to setting 'cluster_name' in PostgreSQL
cluster_name = '$env:computername'
"@
  
try{
  $fileContent | Out-File $PgDataDir\conf.d\07cluster_name.conf -Encoding Default 
} catch {
  writeLogMessage "ERROR`t Can not create config file"
  finish 1
}

Function setPGTimeZone ([string] $confFile) {
  # setting PostgreSQL time zone according to the one of the Windows system
  $tzMap=@{}
  $tzMap.Add('Nepal Standard Time', 'Asia/Katmandu')
  $tzMap.Add('Magadan Standard Time', 'Asia/Magadan')
  $tzMap.Add('Argentina Standard Time', 'America/Buenos_Aires')
  $tzMap.Add('UTC+12', 'Etc/GMT-12')
  $tzMap.Add('US Mountain Standard Time', 'America/Phoenix')
  $tzMap.Add('Yakutsk Standard Time', 'Asia/Yakutsk')
  $tzMap.Add('Ulaanbaatar Standard Time', 'Asia/Ulaanbaatar')
  $tzMap.Add('Afghanistan Standard Time', 'Asia/Kabul')
  $tzMap.Add('Newfoundland Standard Time', 'America/St_Johns')
  $tzMap.Add('Dateline Standard Time', 'Etc/GMT+12')
  $tzMap.Add('Tasmania Standard Time', 'Australia/Hobart')
  $tzMap.Add('SA Eastern Standard Time', 'America/Fortaleza')
  $tzMap.Add('Arabian Standard Time', 'Asia/Muscat')
  $tzMap.Add('Azerbaijan Standard Time', 'Asia/Baku')
  $tzMap.Add('Singapore Standard Time', 'Asia/Singapore')
  $tzMap.Add('Paraguay Standard Time', 'America/Asuncion')
  $tzMap.Add('Montevideo Standard Time', 'America/Montevideo')
  $tzMap.Add('N. Central Asia Standard Time', 'Asia/Novosibirsk')
  $tzMap.Add('Alaskan Standard Time', 'America/Anchorage')
  $tzMap.Add('Central America Standard Time', 'America/Guatemala')
  $tzMap.Add('Pacific SA Standard Time', 'America/Santiago')
  $tzMap.Add('Georgian Standard Time', 'Asia/Tbilisi')
  $tzMap.Add('W. Central Africa Standard Time', 'Africa/Lagos')
  $tzMap.Add('Russian Standard Time', 'Europe/Moscow')
  $tzMap.Add('SE Asia Standard Time', 'Asia/Bangkok')
  $tzMap.Add('Central Pacific Standard Time', 'Pacific/Guadalcanal')
  $tzMap.Add('GMT Standard Time', 'Europe/London')
  $tzMap.Add('Atlantic Standard Time', 'America/Halifax')
  $tzMap.Add('Mauritius Standard Time', 'Indian/Mauritius')
  $tzMap.Add('Mountain Standard Time', 'America/Denver')
  $tzMap.Add('Kamchatka Standard Time', 'Asia/Kamchatka')
  $tzMap.Add('Pacific Standard Time', 'America/Los_Angeles')
  $tzMap.Add('West Asia Standard Time', 'Asia/Tashkent')
  $tzMap.Add('North Asia Standard Time', 'Asia/Krasnoyarsk')
  $tzMap.Add('Namibia Standard Time', 'Africa/Windhoek')
  $tzMap.Add('South Africa Standard Time', 'Africa/Johannesburg')
  $tzMap.Add('Canada Central Standard Time', 'America/Regina')
  $tzMap.Add('AUS Central Standard Time', 'Australia/Darwin')
  $tzMap.Add('Arabic Standard Time', 'Asia/Baghdad')
  $tzMap.Add('W. Australia Standard Time', 'Australia/Perth')
  $tzMap.Add('UTC-02', 'Etc/GMT+2')
  $tzMap.Add('Turkey Standard Time', 'Europe/Istanbul')
  $tzMap.Add('UTC', 'Etc/GMT')
  $tzMap.Add('Azores Standard Time', 'Atlantic/Azores')
  $tzMap.Add('Pacific Standard Time (Mexico)', 'America/Santa_Isabel')
  $tzMap.Add('India Standard Time', 'Asia/Kolkata')
  $tzMap.Add('Central Asia Standard Time', 'Asia/Almaty')
  $tzMap.Add('Israel Standard Time', 'Asia/Jerusalem')
  $tzMap.Add('Egypt Standard Time', 'Africa/Cairo')
  $tzMap.Add('Bangladesh Standard Time', 'Asia/Dhaka')
  $tzMap.Add('Fiji Standard Time', 'Pacific/Fiji')
  $tzMap.Add('UTC-11', 'Pacific/Pago_Pago')
  $tzMap.Add('Ekaterinburg Standard Time', 'Asia/Yekaterinburg')
  $tzMap.Add('China Standard Time', 'Asia/Shanghai')
  $tzMap.Add('SA Pacific Standard Time', 'America/Bogota')
  $tzMap.Add('Greenwich Standard Time', 'Atlantic/Reykjavik')
  $tzMap.Add('Sri Lanka Standard Time', 'Asia/Colombo')
  $tzMap.Add('Vladivostok Standard Time', 'Asia/Vladivostok')
  $tzMap.Add('Tokyo Standard Time', 'Asia/Tokyo')
  $tzMap.Add('Arab Standard Time', 'Asia/Riyadh')
  $tzMap.Add('Greenland Standard Time', 'America/Godthab')
  $tzMap.Add('E. South America Standard Time', 'America/Sao_Paulo')
  $tzMap.Add('E. Africa Standard Time', 'Africa/Nairobi')
  $tzMap.Add('Central Standard Time', 'America/Chicago')
  $tzMap.Add('Hawaiian Standard Time', 'Pacific/Honolulu')
  $tzMap.Add('Cen. Australia Standard Time', 'Australia/Adelaide')
  $tzMap.Add('US Eastern Standard Time', 'America/Indiana/Indianapolis')
  $tzMap.Add('AUS Eastern Standard Time', 'Australia/Sydney')
  $tzMap.Add('Taipei Standard Time', 'Asia/Taipei')
  $tzMap.Add('Middle East Standard Time', 'Asia/Beirut')
  $tzMap.Add('Romance Standard Time', 'Europe/Paris')
  $tzMap.Add('GTB Standard Time', 'Europe/Athens')
  $tzMap.Add('W. Europe Standard Time', 'Europe/Berlin')
  $tzMap.Add('Cape Verde Standard Time', 'Atlantic/Cape_Verde')
  $tzMap.Add('Central European Standard Time', 'Europe/Warsaw')
  $tzMap.Add('Samoa Standard Time', 'Pacific/Apia')
  $tzMap.Add('Korea Standard Time', 'Asia/Seoul')
  $tzMap.Add('Armenian Standard Time', 'Asia/Yerevan')
  $tzMap.Add('Pakistan Standard Time', 'Asia/Karachi')
  $tzMap.Add('Myanmar Standard Time', 'Asia/Rangoon')
  $tzMap.Add('Bahia Standard Time', 'America/Bahia')
  $tzMap.Add('Mexico Standard Time', 'America/Mexico_City')
  $tzMap.Add('Jordan Standard Time', 'Asia/Amman')
  $tzMap.Add('FLE Standard Time', 'Europe/Kiev')
  $tzMap.Add('Venezuela Standard Time', 'America/Caracas')
  $tzMap.Add('Syria Standard Time', 'Asia/Damascus')
  $tzMap.Add('Tonga Standard Time', 'Pacific/Tongatapu')
  $tzMap.Add('Central Europe Standard Time', 'Europe/Budapest')
  $tzMap.Add('E. Australia Standard Time', 'Australia/Brisbane')
  $tzMap.Add('Mountain Standard Time (Mexico)', 'America/Chihuahua')
  $tzMap.Add('New Zealand Standard Time', 'Pacific/Auckland')
  $tzMap.Add('West Pacific Standard Time', 'Pacific/Port_Moresby')
  $tzMap.Add('Iran Standard Time', 'Asia/Tehran')
  $tzMap.Add('Morocco Standard Time', 'Africa/Casablanca')
  $tzMap.Add('Eastern Standard Time', 'America/New_York')
  $tzMap.Add('E. Europe Standard Time', 'Europe/Minsk')
  $tzMap.Add('SA Western Standard Time', 'America/La_Paz')
  $tzMap.Add('Central Brazilian Standard Time', 'America/Cuiaba')
  $tzMap.Add('North Asia East Standard Time', 'Asia/Irkutsk')

  $confText = @"
##############################################################
# LANGUAGE/COUNTRY settings
##############################################################
# version 1.0 for PostgreSQL 11
# date 2019-07-10 by Enrico La Torre
##############################################################

# no stemming in full text search
default_text_search_config = simple

# for log analysis, messages have to be in plain English
lc_messages = 'C'

# no local settings
lc_monetary = 'C'
lc_numeric = 'C'
lc_time = 'C'

# time zone settings from Windows system
"@

  $tzName=$tzMap.Get_Item([TimeZoneInfo]::Local.Id)
  $confText+="`r`nlog_timezone = '$tzName'`r`n"
  $confText+="timezone = '$tzName'`r`n`r`n"

  if ($confFile -ne "") {
    $confText | Out-File $confFile -Encoding Default 
  }
  return $tzName
} # Function setPGTimeZone

# set time zone from Windows system
$tz = (setPGTimeZone -confFile "$PgDataDir\conf.d\08language_country.conf")
writeLogMessage "INFO`t PostgreSQL server time zone set to '$tz'"


# File Name 'conf.d\08language_country.conf' is created with 02_create_pg_admindb.ps1

# Creating File Name 'conf.d\09recovery.conf' ...
$fileContent = @"
##############################################################
# PITR Recovery settings
##############################################################
# version 1.0 for PostgreSQL 12
# date 2020-01-29
# With PostgreSQL 12 the recovery settings are loaded from the
# configration and no recovery.conf file in the data directory
##############################################################

restore_command = 'copy I:\\Backup\\PostgreSQL-WAL-Archive\\%f %p'		# command to use to restore an archived logfile segment
				# placeholders: %p = path of file to restore
				#               %f = file name only
				# e.g. 'cp /mnt/server/archivedir/%f %p'
				# (change requires restart)
#archive_cleanup_command = ''	# command to execute at every restartpoint
#recovery_end_command = ''	# command to execute at completion of recovery

# - Recovery Target -

# Set these only when performing a targeted recovery.

#recovery_target = ''		# 'immediate' to end recovery as soon as a
                                # consistent state is reached
				# (change requires restart)
#recovery_target_name = ''	# the named restore point to which recovery will proceed
				# (change requires restart)
#recovery_target_time = ''	# the time stamp up to which recovery will proceed
				# (change requires restart)
#recovery_target_xid = ''	# the transaction ID up to which recovery will proceed
				# (change requires restart)
#recovery_target_lsn = ''	# the WAL LSN up to which recovery will proceed
				# (change requires restart)
#recovery_target_inclusive = on # Specifies whether to stop:
				# just after the specified recovery target (on)
				# just before the recovery target (off)
				# (change requires restart)
#recovery_target_timeline = 'latest'	# 'current', 'latest', or timeline ID
				# (change requires restart)
#recovery_target_action = 'pause'	# 'pause', 'promote', 'shutdown'
				# (change requires restart)
"@

try{
  $fileContent | Out-File $PgDataDir\conf.d\09recovery.conf -Encoding Default 
} catch {
  writeLogMessage "ERROR`t Can not create config file"
  finish 1
}

# Creating File Name 'pg_hba.conf' ...
$fileContent = @'
# PostgreSQL Client Authentication Configuration File
# ===================================================
#
# Refer to the "Client Authentication" section in the PostgreSQL
# documentation for a complete description of this file.  A short
# synopsis follows.
#
# This file controls: which hosts are allowed to connect, how clients
# are authenticated, which PostgreSQL user names they can use, which
# databases they can access.  Records take one of these forms:
#
# local      DATABASE  USER  METHOD  [OPTIONS]
# host       DATABASE  USER  ADDRESS  METHOD  [OPTIONS]
# hostssl    DATABASE  USER  ADDRESS  METHOD  [OPTIONS]
# hostnossl  DATABASE  USER  ADDRESS  METHOD  [OPTIONS]
#
# (The uppercase items must be replaced by actual values.)
#
# The first field is the connection type: "local" is a Unix-domain
# socket, "host" is either a plain or SSL-encrypted TCP/IP socket,
# "hostssl" is an SSL-encrypted TCP/IP socket, and "hostnossl" is a
# plain TCP/IP socket.
#
# DATABASE can be "all", "sameuser", "samerole", "replication", a
# database name, or a comma-separated list thereof. The "all"
# keyword does not match "replication". Access to replication
# must be enabled in a separate record (see example below).
#
# USER can be "all", a user name, a group name prefixed with "+", or a
# comma-separated list thereof.  In both the DATABASE and USER fields
# you can also write a file name prefixed with "@" to include names
# from a separate file.
#
# ADDRESS specifies the set of hosts the record matches.  It can be a
# host name, or it is made up of an IP address and a CIDR mask that is
# an integer (between 0 and 32 (IPv4) or 128 (IPv6) inclusive) that
# specifies the number of significant bits in the mask.  A host name
# that starts with a dot (.) matches a suffix of the actual host name.
# Alternatively, you can write an IP address and netmask in separate
# columns to specify the set of hosts.  Instead of a CIDR-address, you
# can write "samehost" to match any of the server's own IP addresses,
# or "samenet" to match any address in any subnet that the server is
# directly connected to.
#
# METHOD can be "trust", "reject", "md5", "password", "scram-sha-256",
# "gss", "sspi", "ident", "peer", "pam", "ldap", "radius" or "cert".
# Note that "password" sends passwords in clear text; "md5" or
# "scram-sha-256" are preferred since they send encrypted passwords.
#
# OPTIONS are a set of options for the authentication in the format
# NAME=VALUE.  The available options depend on the different
# authentication methods -- refer to the "Client Authentication"
# section in the documentation for a list of which options are
# available for which authentication methods.
#
# Database and user names containing spaces, commas, quotes and other
# special characters must be quoted.  Quoting one of the keywords
# "all", "sameuser", "samerole" or "replication" makes the name lose
# its special character, and just match a database or username with
# that name.
#
# This file is read on server startup and when the server receives a
# SIGHUP signal.  If you edit the file on a running system, you have to
# SIGHUP the server for the changes to take effect, run "pg_ctl reload",
# or execute "SELECT pg_reload_conf()".
#
# Put your actual configuration here
# ----------------------------------
#
# If you want to allow non-local connections, you need to add more
# "host" records.  In that case you will also need to make PostgreSQL
# listen on a non-local interface via the listen_addresses
# configuration parameter, or via the -i or -h command line switches.

# test entries, only activate for testing purposes!
#host          all            test1               127.0.0.1/32      md5
#host          all            test1               ::1/128           md5


# TYPE        DATABASE        USER                ADDRESS           METHOD

# from local computer, don't use SSL
hostnossl     all             postgres            127.0.0.1/32      md5
hostnossl     all             postgres            ::1/128           md5 
hostnossl     all             all                 127.0.0.1/32      sspi     map=IDENT 
hostnossl     all             all                 ::1/128           sspi     map=IDENT

# from IPv6 link local address (cannot be sure if local computer), use SSL
hostssl       all             all                 fe80::/10         sspi     map=IDENT

# from other computer within 10.0.0.0/8 network, use SSL
hostssl       all             all                 10.0.0.0/8        sspi     map=IDENT


# IPv4 local connections:
#host    all             all             127.0.0.1/32            md5
# IPv6 local connections:
#host    all             all             ::1/128                 md5
# Allow replication connections from localhost, by a user with the
# replication privilege.
#host    replication     postgres        127.0.0.1/32            md5
#host    replication     postgres        ::1/128                 md5
'@
try {
  $fileContent | Out-File $PgDataDir\pg_hba.conf -Encoding Default 
} catch {
  writeLogMessage "ERROR`t Can not create config file"
  finish 1
}



# Creating File Name 'pg_ident.conf' ...
$fileContent = @'
# PostgreSQL User Name Maps
# =========================
#
# Refer to the PostgreSQL documentation, chapter "Client
# Authentication" for a complete description.  A short synopsis
# follows.
#
# This file controls PostgreSQL user name mapping.  It maps external
# user names to their corresponding PostgreSQL user names.  Records
# are of the form:
#
# MAPNAME  SYSTEM-USERNAME  PG-USERNAME
#
# (The uppercase quantities must be replaced by actual values.)
#
# MAPNAME is the (otherwise freely chosen) map name that was used in
# pg_hba.conf.  SYSTEM-USERNAME is the detected user name of the
# client.  PG-USERNAME is the requested PostgreSQL user name.  The
# existence of a record specifies that SYSTEM-USERNAME may connect as
# PG-USERNAME.
#
# If SYSTEM-USERNAME starts with a slash (/), it will be treated as a
# regular expression.  Optionally this can contain a capture (a
# parenthesized subexpression).  The substring matching the capture
# will be substituted for \1 (backslash-one) if present in
# PG-USERNAME.
#
# Multiple maps may be specified in this file and used by pg_hba.conf.
#
# No map names are defined in the default configuration.  If all
# system user names and PostgreSQL user names are the same, you don't
# need anything in this file.
#
# This file is read on server startup and when the postmaster receives
# a SIGHUP signal.  If you edit the file on a running system, you have
# to SIGHUP the postmaster for the changes to take effect.  You can
# use "pg_ctl reload" to do that.

# Put your actual configuration here
# ----------------------------------

# MAPNAME       SYSTEM-USERNAME                             PG-USERNAME

IDENT        "SYSTEM@NT AUTHORITY"                        postgres
IDENT        "SYSTEM@NT AUTHORITY"                        "SYSTEM"
IDENT        "SYSTEM@NT AUTHORITY"                        system

#IDENT        POSTGRES Service Acccount                   adsync

# This is required for connecting with the database using AD-SSPI-Authentication 
IDENT        /^(.*)@DOMAIN\-?\d\d\d$                        \1
'@
try {
  $fileContent | Out-File $PgDataDir\pg_ident.conf -Encoding Default 
} catch {
  writeLogMessage "ERROR`t Can not create config file"
  finish 1
}

# Creating File Name 'ssl-cert-snakeoil.key' ...
$fileContent = @'
-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQDRWcmzXXAUZLdi
oi+QQCSjdc0JyeGhNH29r61Kgq37pBqPhx8VyPkdpnhAmQ5Tc731KLl0j1AEsd6v
qNkNL1Xl0fg3LWbvWtpqf9ciEnwdJtyDPgrtof4oZWbq88+b9i05lX/BJbIX/Uk+
ZgqXqBuYoJoKbb0ufTTa3foIgpd57E30JYEm7vSo315wfg/fG0VfR5bPibI8okBx
98dJ9CKmiStOZ1Y6oWD+ZlkAwLAMUDwFcN7vsCN/IQpMyBJ0uJgyy4KUNTeExN7p
2qdWKy3aVUS30JgWKU4D/2BKym0wALUJ322OftOHW6t71aGtpNOW6R5PpnlDbtyy
VJmZMZqHAgMBAAECggEBAJTrVPJ1ZhPrrRPJoSHwrt9kHc13wTumFkgHnrKhENgv
XQF6Md+STbsMvv/coHc2nwq0xG+ovlgImwrDhlq9sFHCMdo2PsHHFBWsCMHg+k7W
ZQgq6yUtFZlwwGwjsSwVSwhqUy12/h/YefCcL66/05mXrNv8QhW+1QlX29OP6ea8
qu62tm5e4PuJyItGrprsg+cawR56c6mCyVQ0DuVLJaeJ63jaIqRQCFSAgyu+Aob5
SRS6Gucvk1vtU3iyhbqQ0pWs7SxZgHG/h2HW6IXhV4d3hXfG69tr7dmL0TZCJ1+R
zeExYIfn7I06iFpxQjZbyVpZQ1/MDDXzrRPMuHwOh4ECgYEA8dWfXV3X/3Xvw2Im
DY4ZQEPcdv6C2PZ340NgYWwLflRAh+sn+HqpgCmyMdZfPsgnAdBsn/PRGl/HAohg
A4nOv/Uyf/JU9Evngxfm9FwkMOZruyBWZ95UY6Dput5HpIaHEAc0Ku+BBC7fHguU
6VRLyMGis+Se9YRQN/uHl1sl3EcCgYEA3Z0P/6harMQguaGi5RaZ/N9I7E/mkIDW
ersZ667WPwki251WPu+DkYiBydKYaLualZ7/g7kAMdq2PQs9NQbk6wuwkwqoYk6g
f2QRqGVjjv7d/ryJPfjTT4Sk1AoPd9NlHCwSeJ8Fmuh9k4BEhDo75sVV+sjeRlZL
5Eo9C/Jer8ECgYEA6DujsY6H+VtxJuje8A9wckV4tpDMaLuu/4BZUtTl6KfR3HRX
SwfINDpWVAOwLWMaCmTzm1sRh8lIHEeIJH23HKHDoBi/umYV6c8PS8QcQRVViTqR
n2djFNWW/oussvM5SowQbdbXx4OXYYvvsW3w5NYGf8hhWhZ4znnuiMvP/MsCgYBZ
vr0330m5JUPLaPW6qEh760Bw0nqgkkxJL3Pzyb3hkSWYokLHAd/aE9nbjXlDEJYt
eVIoWccGaXfbiK2kx8H0natIIMzH4ueEL1YnR8flpLjp7Bf4DMgmL6VAaUKSV/1e
R0rDpkJy1Svli9AzbBHOBqQnBylcep4JOTc3m1NVAQKBgB93y4GbRrpJFocEksng
UWQGrP9SWJ4PTJZVTcc0dWccinDA68M5Dg7pd0p21BPtm4ovmOHeNRj5neerjVDj
CODkRAvWEH8s3IJoghcT1aGKCM0aGLxbJIiR5idNRE/N9zJy4J368Jhq9oYgoW9m
C4mPCCKzyjNEh9IdoNo4PE+K
-----END PRIVATE KEY-----
'@
try {
  $fileContent | Out-File $PgDataDir\ssl-cert-snakeoil.key -Encoding Default 
} catch {
  writeLogMessage "ERROR`t Can not create config file"
  finish 1
}



# Creating File Name 'ssl-cert-snakeoil.pem' ...
$fileContent = @'
-----BEGIN CERTIFICATE-----
MIIC2DCCAcCgAwIBAgIJAP9H1oQl10BGMA0GCSqGSIb3DQEBCwUAMCQxIjAgBgNV
BAMTGWgyMzY3NDQyLnN0cmF0b3NlcnZlci5uZXQwHhcNMTQxMTIyMjI1MDU5WhcN
MjQxMTE5MjI1MDU5WjAkMSIwIAYDVQQDExloMjM2NzQ0Mi5zdHJhdG9zZXJ2ZXIu
bmV0MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA0VnJs11wFGS3YqIv
kEAko3XNCcnhoTR9va+tSoKt+6Qaj4cfFcj5HaZ4QJkOU3O99Si5dI9QBLHer6jZ
DS9V5dH4Ny1m71raan/XIhJ8HSbcgz4K7aH+KGVm6vPPm/YtOZV/wSWyF/1JPmYK
l6gbmKCaCm29Ln002t36CIKXeexN9CWBJu70qN9ecH4P3xtFX0eWz4myPKJAcffH
SfQipokrTmdWOqFg/mZZAMCwDFA8BXDe77AjfyEKTMgSdLiYMsuClDU3hMTe6dqn
Vist2lVEt9CYFilOA/9gSsptMAC1Cd9tjn7Th1ure9WhraTTlukeT6Z5Q27cslSZ
mTGahwIDAQABow0wCzAJBgNVHRMEAjAAMA0GCSqGSIb3DQEBCwUAA4IBAQC/uddN
K8x5+KmGoXbcPTXDXJHoSDXCxxTV/4yofH/GnIXsXEg3s/oTtqAs3kMIxTJIGPES
6ZKwhuOeoBOB2mFbRrlxrpORgolIhF/NzK0e0UI+bgbby1muGZxQhGTD79ucP4n5
EgJH/hNmqzVqrp1YwbJP0W1za4HOXvwoYPmLOfYu4ZY2qB925chnlqDhVdooN2RW
7FVPBTk6V3tc4gKylYCTbN7Zj0BJpSArhG6/bZXmIObel+BUuwbQYeKDfK+NYdFl
UC3xCAlAQvwj4I+7YIwJbncHYMduKG2xeUZ8DvChoupX5tQp4CyvSoNp9HdY4umP
ROo2cQJWjCSHzqrN
-----END CERTIFICATE-----
'@
try {
  $fileContent | Out-File $PgDataDir\ssl-cert-snakeoil.pem -Encoding Default 
} catch {
  writeLogMessage "ERROR`t Can not create config file"
  finish 1
}


# Enable the conf.d directory in postgresql.conf
try {
  $config = Get-Content -Path $PgDataDir\postgresql.conf
  $config -replace("#include_dir = '...'","include_dir = 'conf.d'") | Set-Content -Path $PgDataDir\postgresql.conf -Encoding Default
} catch {
  writeLogMessage "ERROR`t Can not enable conf.d directory in postgresql.config"
  finish 2
}

finish 0