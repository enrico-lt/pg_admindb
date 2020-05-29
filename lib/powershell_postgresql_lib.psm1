<#
.SYNOPSIS
    PostgreSQL DB Library for PowerShell
    filename powershell_postgresql_lib.psm1

.DESCRIPTION
  This library provides several PowerShell functions to be used with the PostgreSQL database system

.AUTHOR
  Holger Jakobs
  Enrico La Torre
.NOTES
  Date: 2017-09-27

.PRECONDITIONS
  Some script variables have to be set before, some other actions have to be taken as well. Look at
  description of functions for details.
#>

# $lastchange$ Please change last change date in manifest file .psd1 

# Cmdlet to permanently add a directory to the environment variable PATH 
# based on : https://blogs.technet.microsoft.com/heyscriptingguy/2011/07/23/use-powershell-to-modify-your-environmental-path/
Function Add_Dir_To_PATH() {
  param ( 
  [String] $AddedFolder,
  [switch] $prepend = $false,
  [int] $exitcode = 1
  )

  $pathKey = 'Registry::HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\Session Manager\Environment'
  
  # Get the current search path from the environment keys in the registry.
  # $OldPath=(Get-ItemProperty -Path $pathKey -Name PATH).Path

  # See if a new folder has been supplied.
  if (!$AddedFolder) { Return 'No Folder Supplied. $env:PATH Unchanged' }

  # See if the new folder exists on the file system.
  if (!(Test-Path $AddedFolder -PathType container)) { Return 'Folder does not exist, cannot be added to $env:PATH' }

  # See if the new Folder is already in the path.
  $splitPath = $env:PATH.split(';')
  if ($splitPath.contains($AddedFolder)) { Return 'Folder already within $ENV:PATH' }

  # Set the New Path
  if ($prepend) {
    $newPath = (@($AddedFolder) + $splitPath) -join ';'
  } else {
    $newPath = ($splitPath + $AddedFolder) -join ';'
  }

  try {
    Set-ItemProperty -Path  $pathKey -Name PATH -Value $newPath
  } catch {
    writeLogMessage "ERROR`t Add_Dir_To_PATH: $_"
    finish $exitcode
  }
  # Show our results back to the world
  Return $newPath
} # Function Add_Dir_To_PATH



# Cmdlet to permanently remove a directory from the environment variable PATH
# based on : https://blogs.technet.microsoft.com/heyscriptingguy/2011/07/23/use-powershell-to-modify-your-environmental-path/
Function global:Remove-Path() {
  [Cmdletbinding()]
  param (
    [parameter(Mandatory=$True)] [String]$RemoveFolder
  )

  $RemoveFolder=[regex]::escape($RemoveFolder)

  $pathKey = 'Registry::HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\Session Manager\Environment'

  # Get the Current Search Path from the environment keys in the registry
  $NewPath=(Get-ItemProperty -Path $pathKey -Name PATH).Path

  # Find the value to remove, replace it with $NULL. If it’s not found, nothing will change.
  $NewPath=$NewPath -replace $RemoveFolder,$NULL
  $NewPath=$NewPath -replace ';;',';'

  # Update the Environment Path
  Set-ItemProperty -Path $pathKey -Name PATH –Value $newPath
  # [Environment]::SetEnvironmentVariable("PATH", $newPath, [EnvironmentVariableTarget]::Machine)

  # Show what we just did
  return $NewPath
} # global:Remove-Path


####################################################################################
# Gets width of current Powershell window
Function getWindowWidth () {
  $pshost = get-host
  $pswindow = $pshost.ui.rawui
  $windowsize = $pswindow.windowsize
  $width = $windowsize.width
  return $width
} ;# Function getWindowWidth


####################################################################################
# Writes list of strings within width of physical window (not within width of
# buffer. If a string won't fit in the current line, a line break will be inserted
# before, so that word wrap results.
Function writeListInWindow ([string[]] $list) {
  $ww = getWindowWidth
  [string] $currentLine = ''
  $list | ForEach-Object {
    if ($currentLine.length + $_.length -le $ww) {
      $currentLine = "$currentLine $_"
      $currentLine = $currentLine.trim()
    } else {
      write-host $currentLine
      $currentLine = $_
    }
  }
  write-host $currentLine
} # Function writeListInWindow

####################################################################################
# Set Log File Name With Timestamp, Date, Domain or Region.
# If logFile contains '{timestamp}', it will be replaced with current timestamp.
# If logFile contains '{date}', it will be replaced with current date.
# Under the precondition that the script variables domain and region have been set,
# the following two may be used as well:
# If logFile contains '{domain}', it will be replaced with the domain (corp number).
Function setLogFileName ([string] $logfile, [boolean] $custom) {

  if ($custom -eq $true){
	$script:logfile = $logfile
	return
  }
  if ($logfile -ne "") {
    $now = (get-date -format s) -replace "T", "_"
    $now = $now -replace ":", "-"
    $logfile = $logfile -replace "\{timestamp\}", $now
    $logfile = $logfile -replace "\{date\}", $now.substring(0,10)
    if ((Test-Path variable:script:domain)) {
      $logfile = $logfile -replace "\{domain\}", $script:domain
    }
    $script:logfile = $logfile
    return
  } else {
	$script:logfile = ""
  }
} # setLogFileName


####################################################################################
# Write Error Message to log file.
# The variable $script:logfile has to be set before using setLogFileName
# The error message is abridged, if you want the full message, add the option -detail
$noOfErrors = 0
Function writeErrorMessage ([string] $msg, [switch] $detail) {
  $script:noOfErrors++
  $msg = (($msg.trim() -replace "`r`n *", "`r`n`t") -replace " --->",  "`r`n`t--->")
  if (-not $detail) {
    if ($msg -match "`t---> (.*)`n") {
      $msg = $matches[0]
    }
  } # if
  Write-Host $msg -foregroundcolor DarkRed -backgroundcolor Yellow
  if ($script:logfile -and $script:logfile -ne '') {
    ((Get-Date).ToString("yyyy-MM-dd HH:mm:ss ") + "ERROR:`r`n`t" + $msg) | Out-File $script:logfile -Append -Encoding Default
  }
} # writeErrorMessage

####################################################################################
# Write Log Message or empty line to log file.
# The variable $script:logfile has to be set before.
Function writeLogMessage ([string] $msg) {
  if ($script:logfile -eq '') {
    Write-Host $msg
  } else {
    if ($msg -ne "") {
		Write-Host $msg
		$msg = ((Get-Date).ToString("yyyy-MM-dd HH:mm:ss ") + $msg) 
		$msg | Out-File $script:logfile -Append -Encoding Default
    } else {
       "`n" | Out-File $script:logfile -Append -Encoding Default 
    }
  }  
} # writeLogMessage

####################################################################################
# Write Debug Message or empty line to log file.
# writes only if script variable debug is set to $true (by debugOn)
Function writeDebugMessage ([string] $msg) {
  if ($script:debug) {
    if ($script:logfile -eq '') {
      Write-Host  $msg
    } else {
      if ($msg -ne "") {
        ((Get-Date).ToString("yyyy-MM-dd HH:mm:ss ") + $msg) | Out-File $script:logfile -Append -Encoding Default
      } else {
        "`n" | Out-File $script:logfile -Append -Encoding Default
      }
    }
  }
} # writeDebugMessage

# turn debugging on
Function debugOn () {
  $script:debug = $true
}

# turn debugging off
Function debugOff () {
  $script:debug = $false
}


# Function 'finish' to end script anywhere, writes log entry and exits.
#   returnCode - exit status of script to be set
Function finish  {
  param ([int] $returnCode)
  writeLogMessage "FINISH with return Code $($returnCode)."
  writeLogMessage ''
  exit $returnCode
}


####################################################################################
# set eventLogSource for writeEventLogInformation
Function setEventLogSource ([Parameter(Mandatory=$true)] [string] $source) {
  $script:eventLogSource = $source
} # setEventLogSource


####################################################################################
# Write EventLog Message.
# The variable $script:eventLogSource has be be set before. The source has to be registered on the
# computer with New-EventLog before.
# Parameters:
#     * message (string)
#     * event ID (integer)
#     * entry type (string)
Function writeEventLogInformation ([Parameter(Mandatory=$true)] [string] $msg, [int] $eventId=666, [string] $entryType="Information") {
    Write-EventLog -LogName Application -Source $script:eventLogSource -EntryType $entryType -EventId $eventId -Message $msg
} # writeEventLogInformation




####################################################################################
# Check whether ODBC DSN called $dsn is present with database $database.
# Stop whole script if not OK. Returns DSN if successful.
# Parameters: DSN and database name
Function CheckDSN () {
  Param (
    [Parameter(Mandatory=$true)] [string] $dsn,
    [Parameter(Mandatory=$true)] [string] $database
  )

  # check whether ODBC driver is installed
  $installCount= (Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\* |
                   Where-Object { $_.DisplayName -eq "psqlODBC_x64" } | Measure).Count
  if ($installCount -ne 1) {
    writeErrorMessage ("Software package '" + $script:odbcDriverPackage + "' is not installed.");
    exit 2
  }

  $key='HKLM:\SOFTWARE\ODBC\ODBC.INI\' + $dsn
  $db = ''
  Try {
    $ErrorActionPreference = "Stop"
    # read database property from registry entry of DSN
    $db=(Get-ItemProperty -Path $key -Name Database).Database
  }
  Catch {
    writeDebugMessage $error[0]
    writeDebugMessage "DSN '" + $dsn + "' is not present."
    exit 3
  }
  if ($db -ne $database) {
    writeErrorMessage "DSN '" + $dsn + "' is present, but connected to database '" + $db + "' instead of '" + $database "'."
    exit 4
  }
  return $dsn
} # CheckDSN



####################################################################################
# Translate a host name into its (first) IPv4 address if it can be resolved. IPv6 addresses
# will be ignored. If it cannot be resolved into an IPv4 address, the host name
# itself will be returned unchanged.
Function resolveIPv4Address {
  param([string] $hostname)
  # IPv4: InterNetwork, IPv6: InterNetworkV6
  try {
    $ips = [Net.DNS]::GetHostEntry($hostname).AddressList
    foreach ($ip in $ips) {
      if ($ip.AddressFamily -eq "InterNetwork") {
        return $ip.IpAddressToString
      }
    }
  } catch {}
  return $hostname
} # resolveIPv4Address


####################################################################################
# Get the version number of the currently installed PostgreSQL server.
# Will be like 9.6.6 for 9.x versions, but 10.3 for 10+ versions.
Function getPostgresVersion() {
  $versionString = (& 'C:\Program Files\PostgreSQL\9.6\bin\pg_config.exe' --version)
  $version = [regex]::Match($versionString, '([0-9.]+)$').captures.groups[1].value
  return $version
} # getPostgresVersion




####################################################################################
# Connect with ODBC to PostgreSQL on a different server based on server address and
# database name. Don't forget to close the connection again using $conn.close()
Function openOdbcConnection {
  param(
        [string] $dbServer = "",                # DB Server (either IP or hostname)
        [string] $dbName   = "postgres", # Name of the database
        [string] $userName = "",                # username
        [int]    $portNo = 5432                 # port number
  )

  $local = @("localhost", "127.0.0.1", "::1", $env:ComputerName, "")
  $connString = "Driver={PostgreSQL ANSI(x64)};Server=$dbServer;Port=$portNo;Database=$dbName"
  if ($local -contains $dbServer) {
    $connString += ";sslmode=allow"
  } else {
    $connString += ";sslmode=require"
  }
  if ($userName -ne "") {
    $connString += ";uid=$userName"
  } else {
  $userName = whoami
  $userName = [regex]::Match($userName, '^(.*\\)?(.*)$').captures.groups[2].value
  $connString += ";uid=$userName"
  } # if
  
  try {
    $conn = New-Object System.Data.Odbc.OdbcConnection
    $conn.ConnectionString = $connString
    $conn.open()
  } catch {
    writeLogMessage "ERROR`t openOdbcConnection with connstring: '$connString', $_"
    finish 1
  }
  return $conn
} # openOdbcConnection

####################################################################################
# Execute a query returning a result set over an open ODBC connection and return dataset
Function queryOdbcConnection {
  param(
    [System.Data.Odbc.OdbcConnection] $conn,
    [string] $query,
    [int] $cmdTimeout = -1
  )

  # make command object from SQL query and connection
  $cmd = New-object System.Data.Odbc.OdbcCommand($query,$conn)

  try {
    # set command timeout if parameter is set
    if ($cmdTimeout -ne -1) {
      $cmd.CommandTimeout = $cmdTimeout
    }

    # get dataset from query
    $ds = New-Object system.Data.DataSet
    $dsa = New-Object system.Data.odbc.odbcDataAdapter($cmd)
    $dsa.fill($ds)
    return $ds
  } catch {
    $global:sqlErr = $_.Exception.Message.toString()
    $sqlState = ''
    if ($global:sqlErr -match '"ERROR \[(.*)\]') {
      $sqlState = "SQLSTATE $($matches[1])"
    }
    $sqlMsg = ''
    if ($global:sqlErr -match 'ERROR: ([^;]*);') {
      $sqlMsg = "$($matches[1])"
    }
    if ($sqlState -ne '' -and $sqlMsg -ne '') {
      $sqlMsg = ($sqlMsg -replace '`n',' ')
      $global:sqlErr = "$sqlState - $sqlMsg"
    } else {
      writeLogMessage "Error Message doesn't match pattern to extract SQLSTATE and text."
    }
    writeLogMessage "ERROR`t queryOdbcConnection: Bad SQL query '$query'`n$global:sqlErr"
    finish 1
  }
} # queryOdbcConnection


####################################################################################
# Execute a query not returning a result set over an open ODBC connection and return dataset.
# Returns number of affected rows or -1 on error.
Function execOdbcConnection {
    param(
      [System.Data.Odbc.OdbcConnection] $conn,
      [string] $query,
      [int] $cmdTimeout = -1
    )

    # make command object from SQL command and connection
    $cmd = New-object System.Data.Odbc.OdbcCommand($query,$conn)

    try {
      # set command timeout if parameter is set
      if ($cmdTimeout -ne -1) {
        $cmd.CommandTimeout = $cmdTimeout
      }
      return $cmd.executeNonQuery()
    } catch {
      [string] $global:sqlErr = $_.Exception.Message
      writeLogMessage "ERROR`t execOdbcConnection: '$query'`n$global:sqlErr"
      return -1
    }
} # execOdbcConnection


####################################################################################
# Try to get the version of PostgreSQL using ODBC. If connection is not
# possible or other errors, an empty string is returned.
Function getPgVersionOdbc ([int] $portNo = 5432) {
  $dbserver = 'localhost'
  $dbName = 'postgres'
  $dbUser = ''
  try {
    $conn = openOdbcConnection $dbserver $dbName $dbUser $portNo
    if ($conn -eq $null) {
      return ""
    }
    
    $sql = 'select version()'
    $dataset = queryOdbcConnection $conn $sql
    if ($dataset.Tables) {
      $versionString = $dataset.Tables[0].Rows[0][0]
      $version = [regex]::Match($versionString, '^PostgreSQL ([0-9.]+),').captures.groups[1].value
      return $version
    }
    return ""
  } catch {
    writeLogMessage "ERROR`t getPgVersionOdbc on '$dbserver' for database '$dbName' on port '$portNo', $_"
    return ""
  } finally {
    try {
      $conn.close()
    } catch {}
  }
} # Function getPgVersionOdbc


####################################################################################
# Connect to PostgreSQL database using an ODBC DSN with ADODB.Connection or exit.
# The user calling the script will be authenticated via SSPI. If a user name is provided,
# login will be granted if the current user is authorised to connect as the named
# PostgreSQL user.
# Parameters: DSN (mandatory) and user (optional)
# Returns: established ADODB connection
Function connectPg {
  param(
    [Parameter(Mandatory=$true)] [string] $dsn,         # data source name
    [string] $user = ""                                  # username
  )

  $conn = New-Object -comobject ADODB.Connection
  try {
    if ($user -ne "") {
      $conn.Open($dsn, $user)
    } else {
      $conn.Open($dsn)
    }
    return $conn
  } catch {
    writeErrorMessage "connectPg: $_.Exception"
    exit 1
  }
} # connectPg


####################################################################################
# Execute SQL command and write error messages if command fails.
# Parameters:
#     * ADODB connection
#     * command (string)
#     * showAllErrors (boolean)
# Returns recordset as result of SQL command.
Function execSQL {
  Param (
    [Parameter(Mandatory=$true)] $conn,
    [Parameter(Mandatory=$true)] [string] $sql,
    [boolean] $allErrors
  )
  Try {
    $recordset = $conn.Execute($sql)
    return $recordset
  }
  Catch {
    $msg = "`nSQL: "
    $msg += $sql
    writeErrorMessage ($msg)
    $err = $_.Exception
    writeErrorMessage $err.Message
    if ($allErrors) {
      while( $err.InnerException ) {
        $err = $err.InnerException
        writeErrorMessage $err.Message
      }
    }
  }
} # execSQL


####################################################################################
# Shows records from an ADODB record set using writeLogMessage.
# Parameter: recordset
Function showRecords ($recordSet) {
  writeLogMessage ""
  $recordSet.MoveFirst()
  $result = ""
  foreach ($field in $recordSet.fields) {
    $result += $field.Name
    $result += '   '
  }
  writeLogMessage $result
  while ($recordSet.EOF -ne $true) {
    $result = ""
    foreach ($field in $recordSet.fields) {
      $result += $field.Value.ToString()
      $result += '   '
    }
    $recordSet.MoveNext()
    writeLogMessage $result
  } # while
  writeLogMessage ""
} # showRecords


####################################################################################
# Connect with NPgSql to a PostgreSQL database on a server based on server address and
# database name. Don't forget to close the connection again using $conn.close() as
# this doesn't happen automatically at script end. Using try ... finally may be a
# good idea.
Function openNpgSqlConnection {
  param(
    [parameter(Mandatory=$True)] [string] $dbServer = "", # DB Server (either IP or hostname)
    [string] $dbName   = "postgres",              # Name of the database
    [string] $userName = ""                              # username
  )
  try {
    Add-Type -Path "$PSScriptRoot\Npgsql.dll"
    $connString = "server=$dbServer;port=5432;database=$dbName;pooling=false"
    $connString += ";Trust Server Certificate=true;SSL Mode=Require"
    if ($userName -ne "") {
      $connString += ";username=$userName"
    } # if
    $conn = New-Object Npgsql.NpgsqlConnection
    $conn.ConnectionString = $connString
    $conn.Open()

    return $conn
  } catch {
    writeErrorMessage $_.Exception.Message
  }
} # openNpgSqlConnection


####################################################################################
# Execute a query returning a result set over an open NPgSql connection and return
# the result as a dataset
# The returned dataset can be used with dataset2array (see below) or its rows
# shown using   (queryNpgSQLConnection $conn $query).Tables[0].Rows | Format-Table
Function queryNpgSQLConnection {
    param(
      [parameter(Mandatory=$True)] [Npgsql.NpgsqlConnection] $conn,
      [parameter(Mandatory=$True)] [string] $query,
      [int] $cmdTimeout = -1
    )

    try {
      # make command object from SQL command and connection
      $cmd = $conn.CreateCommand()

      # set command timeout if parameter is set
      if ($cmdTimeout -ne -1) {
        $cmd.CommandTimeout = $cmdTimeout
      }

      $cmd.CommandText = $query
      $adapter = New-Object -TypeName Npgsql.NpgsqlDataAdapter $cmd
      $ds = New-Object -TypeName System.Data.DataSet

      # execute query and fill dataset
      $adapter.Fill($ds)

      # return dataset
      return $ds
    } catch {
      [string] $global:sqlErr = $_.Exception.Message
      writeErrorMessage "Bad SQL query: $cmd`n$global:sqlErr"
    }
} # queryNpgSQLConnection

####################################################################################
# Turn the dataset (as returned from queryNpgSQLConnection) into an array of strings
# consisting of tab-separated values. First line contains field names.
# The return value cat be written to a text file like this:
#  dataset2array $ds | Out-File filename -encoding utf8
Function dataset2array {
  param(
    [parameter(Mandatory=$True)]  $dataset
  )

  $retval = @()
  if ($dataset.Tables) {
    $retval += ([string]::Join("`t",$dataset.Tables[0].Columns.ColumnName))
    foreach ($Row in $dataset.tables[0]) {
      $rowArray = @()
      foreach ($col in $dataset.Tables[0].Columns) {
        $rowArray += "$($Row[$col.ColumnName])"
      }
      $retval += ([string]::Join("`t",$rowArray))
    } # foreach
  } # if
  return $retval
} # dataset2array

####################################################################################
# Turn the dataset (as returned from queryNpgSQLConnection) into an HTML table.
# If an id is provided, the table gets this id.
Function dataset2html {
  param(
    [parameter(Mandatory=$True)]  $dataset,
    [string] $id=""
  )

  [string[]] $numTypes = @('Int16', 'Int32', 'Int64', 'Double', 'Decimal')
  [string[]] $intTypes = @('Int16', 'Int32', 'Int64')
  
  $retval = ""
  if ($dataset.Tables) {
    $retval += "<table "
    if ($id -ne "") {
      $retval += "id='$id' "
    }
    $retval += "border='1'><thead><tr>"
    $retval += ("<th>" + ([string]::Join("</th><th>",$dataset.Tables[0].Columns.ColumnName)) + "</th>")
    $retval += "</tr></thead>"
    $retval += "<tbody>"
    foreach ($Row in $dataset.tables[0]) {
      $htmlRow = "<tr>"
      foreach ($col in $dataset.Tables[0].Columns) {
        [string] $dataTypeName = $col.DataType.Name
        if ($numTypes -contains $dataTypeName) {
          $numVal = $Row[$col.ColumnName]
          if ($intTypes -contains $dataTypeName) {
            $numVal = [string]::Format('{0:N0}', $numVal)
          } else {
            $numVal = [string]::Format('{0:N4}', $numVal)
          }
          $htmlRow += "<td style='text-align: right'>$numVal</td>"
        } else {
          $htmlRow += "<td>$($Row[$col.ColumnName])</td>"
        }
      }
      $htmlRow += "</tr>"
      $retval += $htmlRow
    } # foreach
    $retval += "</tbody></table>"
  } # if
  return $retval
} # dataset2html




####################################################################################
# Execute a query not returning a result set over an open NPgSql connection and return dataset
Function execNpgSQLConnection {
    param(
      [parameter(Mandatory=$True)] [Npgsql.NpgsqlConnection] $conn,
      [parameter(Mandatory=$True)] [string] $query,
      [int] $cmdTimeout = -1
    )

    try {
      # make command object from SQL command and connection
      $cmd = $conn.CreateCommand()

      # set command timeout if parameter is set
      if ($cmdTimeout -ne -1) {
        $cmd.CommandTimeout = $cmdTimeout
      }

      $cmd.CommandText = $query

      # execute query and return result (no of rows affected)
      return $cmd.ExecuteNonQuery()

    } catch {
      $err = $_.Exception
      writeErrorMessage "Bad SQL command: $cmd`n$err.Message"
    }

} # execNpgSQLConnection




####################################################################################
# Stop services related to PostgreSQL.
# In case of failure, finish script if an exit code was provided.
Function stopRelatedServices ([int] $exitCode = -1, [string] $Taskname, [string] $servicename) {
  $msg = "INFO`t Stopping related services ..."
  writeLogMessage $msg
  try {
    if (Get-ScheduledTask -TaskName $Taskname -ErrorAction SilentlyContinue) {
      writeLogMessage "INFO`t Disabling Scheduled Task '$Taskname' ..."
      Disable-ScheduledTask -TaskName $Taskname
      writeLogMessage "INFO`t Scheduled Task '$Taskname' disabled"
    }
    if (Get-Service -Name $servicename -ErrorAction SilentlyContinue) {
      writeLogMessage "INFO`t Stopping and disabling service 'servicename' ..."
      Set-Service $servicename -StartupType Disabled
      Stop-Service $servicename
      $svc = Get-Service $servicename
      $svc.WaitForStatus('Stopped','00:00:30')
      writeLogMessage "INFO`t Service 'servicename' stopped and disabled"
    }
  } catch {
    writeLogMessage "ERROR`t Stopping related services failed: $_"
    writeLogMessage "INFO`t Starting related services again"
    startRelatedServices -exitcode $exitcode
    if ($exitCode -ne -1) {
      finish $exitCode
    }
  }
} # stopRelatedServices


####################################################################################
# Start services related to PostgreSQL.
# In case of failure, finish script if an exit code was provided.
Function startRelatedServices ([int] $exitCode = -1, [switch] $exceptNEWPOSS = $false, [string] $Taskname, [string] $servicename) {
  $msg = "INFO`t Starting related services ..."
  writeLogMessage $msg
  try {
    if (Get-ScheduledTask -TaskName $Taskname -ErrorAction SilentlyContinue) {
      writeLogMessage "INFO`t Enabling Scheduled Task '$Taskname' ..."
      Enable-ScheduledTask -TaskName $Taskname
      writeLogMessage "INFO`t Scheduled Task '$Taskname' enabled"
    }
    if (Get-Service -Name sysmon -ErrorAction SilentlyContinue) {
      writeLogMessage "INFO`t Enabling and starting service '$servicename' ..."
      Set-Service $servicename -StartupType Automatic
      Start-Service $servicename
      $svc = Get-Service $servicename
      $svc.WaitForStatus('Running','00:00:30')
      writeLogMessage "INFO`t Service '$servicename' enabled and started"
    }
  } catch {
    writeLogMessage "ERROR`t Starting related services failed: $_"
    if ($exitCode -ne -1) {
      finish $exitCode
    }
  }
} # startRelatedServices


# Stop service '$pgServiceName' and wait for another minute
Function stopPgService([string] $pgServiceName, [int] $exitCode) {
  # Stop service
  writeLogMessage "INFO`t Stopping and disabling service '$pgServiceName'"
  try {
    Set-Service -Name $pgServiceName -StartupType "Disabled"
    Stop-Service $pgServiceName
    $svc = Get-Service $pgServiceName
    $svc.WaitForStatus('Stopped', '00:00:30')
    writeLogMessage "INFO`t Service '$pgServiceName' stopped and disabled"
  } catch {
    writeLogMessage "ERROR`t '$pgServiceName' hasn't reached status 'STOPPED' after 30 seconds: $_"
    finish $exitCode
  }
} # Function stopPgService

Function StartPgService ([string] $pgServiceName, [int] $pgPort = 5432 , [int] $exitCode = -1) {
  # Check if the service exists
  if (!(Get-Service $pgServiceName -ErrorAction SilentlyContinue)) {
     WriteLogMessage "ERROR`t PostgreSQL service '$pgServiceName' could not be detected"
     if ($exitCode -ne -1) {
      finish $exitCode
     }
  }

  try { 
    # start service (doesn't hurt if already running)
    writeLogMessage "INFO`t Service '$pgServiceName' exists, enabling and starting ..."
    Set-Service -Name $pgServiceName -StartupType "Automatic"
    Start-Service $pgServiceName
    # wait for 30 seconds to become 'Running' 
    $svc = Get-Service $pgServiceName 
    $svc.WaitForStatus('Running','00:00:30')
    writeLogMessage "INFO`t Service '$pgServiceName' is running"
  } catch { 
    writeLogMessage "ERROR`t Service doesn't reach status 'running' after 30 seconds. Error: $_" 
    if ($exitCode -ne -1) {
      finish $exitCode
     }
  } 
  
  # Check if the port can be opened
  if (!(Test-TCPPort 127.0.0.1 $pgPort)) {
     WriteLogMessage "ERROR`t TCP Port $pgPort on localhost seems not to be open"
     if ($exitCode -ne -1) {
      finish $exitCode
     }
  }
} # StartPgService


###################################################################################
# return some rudimentary CSS for inclusion into HTML files
Function getCSS {
  $css = @'
* {
  font-family: Arial,Helvetica, "sans serif";
}

h1, h2, h3 {
  margin-bottom: 0px;
  padding-bottom: 0px;
}

table {
  border-collapse: collapse;
  border: 2px solid #333;
}

tbody tr:nth-child(odd) {
  background: #eee;
}
td {
  padding: 2px;
}

th {
  padding: 5px;
  color: white;
  background-color: #555;
}
'@
      return $css
} # getCSS

##############################################################################
#.SYNOPSIS
# Execute commands using psql.exe
#
#.DESCRIPTION
# Execute commands using psql.exe in one transaction.
# In case of error stop immediately and report the error.
#
# .ENVIRONMENT VARIABLES:
#   PGHOST, PGUSER, PGDATABASE, PGPASSWORD or pgpass file
#
#.PARAMETER sqlCommands
# SQL commands to be executed by psql
#
#.EXAMPLE
# These commands contain an error: column "current_time_" does not exist.
# $cmd = @('select * from pg_roles;', 'select current_date;', 'select current_time_;', 'select current_date;')
# ExecutePSQL $cmd | ForEach {
#   write-host ("RESULT: " + $_)
# }
#  write-host ("psqlError: " + $psqlError)
##############################################################################
Function ExecutePSQL_NoPSErrorHandling {
  Param (
    [Parameter(Mandatory=$true)] [string] $sqlCommands
    , [string] $hostname = "localhost"
    , [string] $database
  )
  $result = @()
  $script:psqlError = "OK"
  
  ($sqlCommands | psql -h $hostname -w -b $database 2>&1) | ForEach { 
    if ($_ -is [System.Management.Automation.ErrorRecord]) {
      if ($psqlError -eq "OK") {
        $Meldung = $_.Exception.Message
        $script:psqlError = $Meldung.ToString()
        writeLogMessage $script:psqlError
      }
    }
    $_
  }
} # ExecutePSQL_NoPSErrorHandling

Function ExecutePSQL {
  Param (
    [Parameter(Mandatory=$true)] [string] $sqlCommands
    , [string] $server = "localhost"
    , [string] $database = "postgres"
    , [string] $user 
    , [string] $PortNo = "5432"
    , [int] $exitCode = 2
  )
  try {
    if ($user) {
      ($sqlCommands | psql -h $server -U $user -p $PortNo -w --echo-errors $database 2>&1) | ForEach-Object {
        if ($_ -match "^ERROR.*") {
          writeLogMessage "ERROR`t ExecutePSQL failed: $_"
          finish $exitCode
        }
      writeLogMessage "$_"
      } # foreach
    } else {
      ($sqlCommands | psql -h $server -p $PortNo -w --echo-errors $database 2>&1) | ForEach-Object { 
        if ($_ -match "^ERROR.*") {
          writeLogMessage "ERROR`t ExecutePSQL failed: $_"
          finish $exitCode
        }
        writeLogMessage "$_"
      } # foreach
    }
  } catch {
    writeLogMessage "ERROR`t ExecutePSQL: Execution of psql failed: $_"
    finish $exitCode
  }
} # ExecutePSQL

function Test-TCPPort {
    param ( [ValidateNotNullOrEmpty()]
    [string] $EndPoint = $(throw "Please specify an EndPoint (Host or IP Address)"),
    [string] $Port = $(throw "Please specify a Port") )
	
    $TimeOut = 1000
    $IP = [System.Net.Dns]::GetHostAddresses($EndPoint)
    $Address = [System.Net.IPAddress]::Parse($IP)
    $Socket = New-Object System.Net.Sockets.TCPClient
    $Connect = $Socket.BeginConnect($Address,$Port,$null,$null)
    Start-Sleep -Seconds 2
    if ( $Connect.IsCompleted ) {
	    $Wait = $Connect.AsyncWaitHandle.WaitOne($TimeOut,$false)
	    if(!$Wait)
	    {
		    $Socket.Close()
		    return $false
	    }
	    else {
		    try {
          $Socket.EndConnect($Connect)
		      $Socket.Close()
		      return $true
        } catch {
          return $false
        }
	    }
    } else {
	    return $false
    }
} # Test-TCPPort

Function Create_ScheduledTask_with_XML() {
  <# Documentation:
  XML-Schema:     https://docs.microsoft.com/en-us/windows/desktop/taskschd/task-scheduler-schema
  Time formats:   http://go.microsoft.com/fwlink/p/?linkid=106886
                  The lexical representation for duration is the [ISO 8601] extended format PnYnMnDTnHnMnS, 
                  where nY represents the number of years, nM the number of months, nD the number of days, 
                  'T' is the date/time separator, nH the number of hours, nM the number of minutes and nS 
                  the number of seconds. The number of seconds can include decimal digits to arbitrary precision.
  #>
      Param(
           [string] $XMLFilePath = "C:\TMP\schtask.xml" # File path for a temporary XML file
          ,[string] $Author 
          ,[Parameter(Mandatory=$true)] [string] $User # Execution security context of Scheduled Task
          ,[string] $Password
          ,[Parameter(Mandatory=$true)] [string] $TaskName
          ,[string] $TaskDescription
          ,[Parameter(Mandatory=$true)] [string] $FilePathofScript # Path to executable Powershell script
          ,[string] $Enabled = "true"
          ,[string] $ExecutionTimeLimit = "PT72H" # Amount of time allowed to complete the task, the format for this string is PnYnMnDTnHnMnS
          ,[string] $StartTime # Time when the first run starts, format is "HH:mm:ss" in 24 hours
          ,[string] $StartDay # Day when the first run starts, format is "yyyy-MM-dd"
          ,[string] $TriggerEnabled = "true"
          ,[string] $TriggerExecutionTimeLimit = "PT3H" # Specifies the maximum amount of time in which the task can be started by the trigger
                                                       # But also it means "Stop task if it runs longer than ..."
          ,[int] $DaysInterval # Repeat every $DaysInterval # of days
          ,[int] $WeeksInterval # Repeat every $WeeksInterval # of weeks
          ,[string[]] $DaysOfWeek # String array of days it repeats for e.g. @("Sunday","Tuesday",...) 
          ,[string] $RepetitionInterval # Repition time interval, the format for this string is PnYnMnDTnHnMnS
          ,[string] $RepitionStopAtDurationEnd = "false"
          ,[string] $Boottrigger # Additional trigger that starts the Scheduled Task after any reboot
          ,[int] $ExitCode = 1
      )
  
      # Sanity check of input parameters
      if($DaysInterval -and $WeeksInterval){
          $msg = "ERROR`t Create-ScheduledTask-with-XML: You speciefied a daily and weekly schedule, but only one kind is possible, therefore STOP!"
          writeLogMessage $msg
          finish $ExitCode
      }
      if($WeeksInterval -and (-Not $DaysOfWeek)){
          $msg = "ERROR`t Create-ScheduledTask-with-XML: You speciefied a weekly schedule, but no -DaysOfWeek, therefore STOP!"
          writeLogMessage $msg
          finish $ExitCode
      }
      if(-Not $Author) { $Author = $User }
  
      $now = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
      if(-Not $StartDay) {
        $day = (Get-Date).ToString("yyyy-MM-dd")
      } else {
        $day = $StartDay
      }
  
      $NameSpaceURI = "http://schemas.microsoft.com/windows/2004/02/mit/task"
  
      try{
          # No tabs, spaces or characters must be between @" and <?xml ... !
          [System.XML.XMLDocument] $schTask = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="$NameSpaceURI">
  <RegistrationInfo>
  <Date>$now</Date>
  <Author>$Author</Author>
  </RegistrationInfo>
  <Triggers>
        <!--Calendar or BootTrigger-->
  </Triggers>
  <Settings>
  <AllowStartOnDemand>true</AllowStartOnDemand>
  <Enabled>$Enabled</Enabled>
  <ExecutionTimeLimit>$ExecutionTimeLimit</ExecutionTimeLimit>
  </Settings>
  <Actions Context="Author">
  <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-WindowStyle Hidden -NonInteractive -file $FilePathofScript</Arguments>
  </Exec>
  </Actions>
</Task>
"@

          # Calendar Trigger to Trigger node if $StartTime is present
          if ($StartTime) {
            $CalendarTrigger_Element = $schTask.CreateElement("CalendarTrigger", $NameSpaceURI)
            
            $CalendarTrigger_StartBoundary_element = $schTask.CreateElement("StartBoundary",$NameSpaceURI)
            $CalendarTrigger_StartBoundary_element.InnerText = "${day}T${StartTime}"
            $CalendarTrigger_Element.AppendChild($CalendarTrigger_StartBoundary_element) | Out-Null
            $CalendarTrigger_enabled_element = $schTask.CreateElement("Enabled",$NameSpaceURI)
            $CalendarTrigger_enabled_element.InnerText = "$TriggerEnabled"
            $CalendarTrigger_Element.AppendChild($CalendarTrigger_enabled_element) | Out-Null
            $CalendarTrigger_ExecutionTimeLimit_element = $schTask.CreateElement("ExecutionTimeLimit",$NameSpaceURI)
            $CalendarTrigger_ExecutionTimeLimit_element.InnerText = "$TriggerExecutionTimeLimit"
            $CalendarTrigger_Element.AppendChild($CalendarTrigger_ExecutionTimeLimit_element) | Out-Null

            $schTask.Task.Triggers.AppendChild($CalendarTrigger_Element) | Out-Null
          }

          # Add Description node to RegistrationInfo node if present
          if($TaskDescription){
              $TaskDescription_Element = $schTask.CreateElement("Description", $NameSpaceURI)
              $TaskDescription_Element.InnerText = $TaskDescription
              
              $schTask.Task.RegistrationInfo.AppendChild($TaskDescription_Element) | Out-Null
          }
  
          # Add DaysInterval node to CalendarTrigger node if present
          if($DaysInterval){
              $ScheduleByDay_element = $schTask.CreateElement("ScheduleByDay",$NameSpaceURI)
              $DaysInterval_element =  $schTask.CreateElement("DaysInterval",$NameSpaceURI)
              $DaysInterval_element.InnerText = $DaysInterval
              $ScheduleByDay_element.AppendChild($DaysInterval_element) | Out-Null
  
              $schTask.Task.Triggers.CalendarTrigger.AppendChild($ScheduleByDay_element) | Out-Null
          }
  
          # Add Weeksintervall node to CalendarTrigger node if present
          if($WeeksInterval){
              $ScheduleByWeek_element = $schTask.CreateElement("ScheduleByWeek",$NameSpaceURI)
              $WeeksInterval_element = $schTask.CreateElement("WeeksInterval",$NameSpaceURI)
              $WeeksInterval_element.InnerText = $WeeksInterval 
              $ScheduleByWeek_element.AppendChild($WeeksInterval_element) | Out-Null
              
              $DaysOfWeek_element = $schTask.CreateElement("DaysOfWeek",$NameSpaceURI)
              foreach($weekday in $DaysofWeek){
                  $Weekday_element = $schTask.CreateElement("$weekday",$NameSpaceURI)
                  $DaysOfWeek_element.AppendChild($Weekday_element) | Out-Null
              }
              $ScheduleByWeek_element.AppendChild($DaysOfWeek_element) | Out-Null
  
              $schTask.Task.Triggers.CalendarTrigger.AppendChild($ScheduleByWeek_element) | Out-Null
          }
  
          # Add Repition node to CalendarTrigger node if present
          if($RepetitionInterval){
              $Repetition_element = $schTask.CreateElement("Repetition",$NameSpaceURI)
              $Interval_element =  $schTask.CreateElement("Interval",$NameSpaceURI)
              $Interval_element.InnerText = $RepetitionInterval
              $Repetition_element.AppendChild($Interval_element) | Out-Null
  
              $StopAtDurationEnd_element =  $schTask.CreateElement("StopAtDurationEnd",$NameSpaceURI)
              $StopAtDurationEnd_element.InnerText = $RepitionStopAtDurationEnd
              $Repetition_element.AppendChild($StopAtDurationEnd_element) | Out-Null
  
              $schTask.Task.Triggers.CalendarTrigger.AppendChild($Repetition_element) | Out-Null
          }

          # Boot trigger to Trigger node if present
          if ($Boottrigger) {
            $Boottrigger_Element = $schTask.CreateElement("BootTrigger", $NameSpaceURI)
           
            $Boottrigger_enabled_element = $schTask.CreateElement("Enabled",$NameSpaceURI)
            $Boottrigger_enabled_element.InnerText = "true"
            $Boottrigger_Element.AppendChild($Boottrigger_enabled_element) | Out-Null

            $schTask.Task.Triggers.AppendChild($Boottrigger_Element) | Out-Null
          }
  
          # Save the temporary XML file
          $schTask.Save($XMLFilePath)
  
      } catch{
          $msg = "ERROR`t Create-ScheduledTask-with-XML: Cannot generate XML file for Scheduled Task $TaskName, therefore STOP!`n $_"
          writeLogMessage $msg
          
          finish $ExitCode
      }
      
          # Register the Scheduled Task with schtasks.exe
          if(-Not $Password){
              & schtasks.exe /CREATE /TN $TaskName /RU $User /XML $XMLFilePath /F | Out-Null
          } else {
              & schtasks.exe /CREATE /TN $TaskName /RU $User /RP $Password /XML $XMLFilePath /F | Out-Null
          }
          if($LASTEXITCODE -ne 0) {
            $msg = "ERROR`t Create-ScheduledTask-with-XML: Cannot register Scheduled Task $TaskName with schtasks.exe, therefore STOP!`n $_"
            writeLogMessage $msg
            finish $ExitCode
          }
  
      try {
        # Remove temporary XML file again
        Remove-Item $XMLFilePath -Force
      } catch {
          $msg = "WARNING`t Create-ScheduledTask-with-XML: Cannot delete temporary XML file $XMLFilePath : `n $_"
          writeLogMessage $msg
      }
  
      $msg = "SUCCESS`t Created Scheduled Task $TaskName"
      writeLogMessage $msg
  
} # Function Create_ScheduledTask_with_XML

# Configuration Functions
Export-ModuleMember -Function getWindowWidth
Export-ModuleMember -Function writeListInWindow

# Network Functions
Export-ModuleMember -Function resolveIPv4Address

# PostgreSQL Functions
Export-ModuleMember -Function getPostgresVersion
Export-ModuleMember -Function checkDSN
Export-ModuleMember -Function connectPg
Export-ModuleMember -Function execSQL
Export-ModuleMember -Function showRecords

Export-ModuleMember -Function openOdbcConnection
Export-ModuleMember -Function queryOdbcConnection
Export-ModuleMember -Function execOdbcConnection
Export-ModuleMember -Function getPgVersionOdbc

Export-ModuleMember -Function openNpgSqlConnection
Export-ModuleMember -Function queryNpgSQLConnection
Export-ModuleMember -Function dataset2array
Export-ModuleMember -Function dataset2html
Export-ModuleMember -Function execNpgSQLConnection

# CSS
Export-ModuleMember -Function getCSS

# Log File Function
Export-ModuleMember -Function setLogFileName

# Output Functions
Export-ModuleMember -Function writeDebugMessage
Export-ModuleMember -Function debugOn
Export-ModuleMember -Function debugOff
Export-ModuleMember -Function writeErrorMessage
Export-ModuleMember -Function writeLogMessage
Export-ModuleMember -Function writeEventLogInformation
Export-ModuleMember -Function setEventLogSource

# Services related Functions
Export-ModuleMember -Function stopRelatedServices
Export-ModuleMember -Function startRelatedServices
Export-ModuleMember -Function stopPgService
Export-ModuleMember -Function startPgService


# psql functions
Export-ModuleMember -Function ExecutePSQL_NoPSErrorHandling
Export-ModuleMember -Function ExecutePSQL

# Exit functions 
Export-ModuleMember -Function finish

# Scheduled Tasks
Export-ModuleMember -Function Create_ScheduledTask_with_XML

# Windows functions
Export-ModuleMember -Function Add_Dir_To_PATH
Export-ModuleMember -Function Test-TCPPort