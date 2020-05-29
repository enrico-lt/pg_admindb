<#
.SYNOPSIS
  Script for a minor upgrade of a local PostgreSQL installation
.DESCRIPTION
 This script serves two purposes.

 A - Wrap the contents of the directory C:\Program Files\PostgreSQL\MAJORNUMBER
     to a ZIP file named pg_MAJORNUMBER.zip

     Before actually doing that, the ACLs of a the directory and its 
     contents are saved to a file MAJORNUMBER.acls with default encoding,
     where the SIDs of the principals have been replaced by symbolic names
     in the format DOMAIN\USER. The file is placed into the directory, so
     that it is contained in the ZIP file.

     The process is actually the same as the one for a minor upgrade. The
     difference is in the unwrap part.

 B - Unwrap the contents of the ZIP file pg_MAJORNUMBER.zip to the directory
     C:\Program Files\PostgreSQL\MAJORNUMBER. It fails if the target directory
     already exists.

     After the unwrapping of the file, the ACLs from the file MAJORNUMBER.acls
     are read, the symbolic names are mapped to SIDs on the current system and 
     applied to the directory.

     A new service is set up and running.

     The service is fired up and a new cluster with checksums is created. 

 After installing the new version this way, the major upgrade can take place.
 This can be done using the script pg_major_upgade_switch.ps1
.NOTES
    Author:			Enrico La Torre
    Date:			  2020-02-17
#>
################################################################################
############################## PROCESS PARAMETERS ##############################
################################################################################
param(
  # Major Version
  [string] $pgMajorVersion = "12",
  [switch] $wrap, 
  [switch] $unwrap
)
# $pgMajorVersion is the number of the version to wrap/unwrap.
# Use always exactly one of the following switches:
#    -wrap
#    -unwrap
# In the case of -wrap the PG program directory 
# C:\Program Files\PostgreSQL\MAJORVERSION will  be wrapped to 
# C:\TMP\pg_MAJORNUMBER.zip including ACLs.
# In the case of -unwrap the ZIP file C:\TMP\pg_MAJORNUMBER.zip will be 
# extracted to C:\Program Files\PostgreSQL\MAJORVERSION and an empty database 
# cluster will be created.

################################################################################
########################### CONFIGURATION PARAMETERS ###########################
################################################################################

$lastchange = "2020-05-29"

# Port of PostgreSQL cluster
$pgPort = 5433

# PostgreSQL service name
$PgService = "postgresql$pgMajorVersion"
# PostgreSQL program directory
$pgProgDir = "C:\Program Files\PostgreSQL\$pgMajorVersion"
# PostgreSQL data directory
$pgDataDir = "G:\databases\PostgreSQL\$pgMajorVersion"
# Registry file with uninstall information
$regUninstallFile = "$pgProgDir\uninstall_info.reg"

# NTFS permission script
$NTFSscript = "E:\pg_admindb\NTFS_permissions\SetPgNTFSpermissions.ps1"
# Script for creating config files
$ConfigScript = "$PSScriptRoot\config\PostgreSQL12_CreateConfigurationStores.ps1"
# Script for intial configuration of user db
$initconfig = "$PSScriptRoot\config\01_create_pg_admindb"
# Script for creation of event trigger
$EventTriggerScript = "$PSScriptRoot\config\02_event_trigger_owner_to_db_owner.ps1"
# Script for creation of administrative views
$pgInfoScript = "$PSScriptRoot\config\03_pg_info.ps1"

# Directory of installation file for ODBC driver
$installfileLocation = "$PSScriptRoot\src"

# Domain (FQDN)
$domainFQDN = (Get-WmiObject win32_computersystem).Domain
$domain = $domainFQDN.Split('.')[0]

# Service Account for PostgreSQL
$serviceuser = "DOMAIN\USER"
$useronly = "USER"
$pass = Read-Host -Prompt "Please enter password for '$serviceuser'"

# Password for postgres
$env:PGPASSWORD = Read-Host -Prompt "Please enter password for PostgreSQL superuser 'postgres'"

# Directory of temporary directory
$tempdir = "C:\TMP"
# Full path of 7z program
$prog7z = "$PSScriptRoot\7-Zip64\7z.exe"

# Directory for log file
$Logpath = "E:\pg_admindb\logs\major_upgrade_$pgMajorVersion"

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
$scriptName += "-$pgMajorVersion-log.txt"
New-Item -ItemType Directory -Force -Path $Logpath | Out-Null
$script:logfile="$Logpath\$scriptname"
setLogFileName -logfile $script:logfile


#################################################################################
################################### FUNCTIONS ###################################
#################################################################################

# Find the ZIP file with the contents of the PostgreSQL Program Folder.
# Make sure only one matching file exists.
Function findZipFile ([int] $exitcode) {
  try {
    [string []]$files = Get-ChildItem -Path "$tempdir\*" -Include "pg_${pgMajorVersion}*.zip"
    if ($files.length -eq 0) {
      writeLogMessage "ERROR`t No ZIP file found matching '$tempdir\pg_${pgMajorVersion}*.zip'"
      finish $exitcode
    }
    return $files[0]
  } catch {
    writeLogMessage "ERROR`t findZipFile: $_"
    finish $exitcode
  }
} # Function findZipFile

Function ExtractZipFile ([string] $zipname, [int] $exitcode) {

  $parentDir = Split-Path -Path $pgProgDir -parent
  writeLogMessage "INFO`t Unzipping '$zipName' to '$parentDir'..."
  try{  
    # Jump to parent dir of PostgreSQL program directory for 7z to work
    $oldLocation = Get-Location
    Set-Location -Path $parentDir

    & $prog7z x $zipName -y
    if ($LASTEXITCODE -eq 0) {
      writeLogMessage "INFO`t New program files successfully extracted"
    } else {
      writeLogMessage "ERROR`t Cannot unzip '$zipName': $_"
      finish $exitcode
    }
    # Jump back to previous dir
    Set-Location $oldLocation
  } catch {
    writeLogMessage "ERROR`t Cannot unzip '$zipName': $_"
    finish $exitcode
  }
  # Jump back to previous dir
  Set-Location $oldLocation

} # ExtractZipFile

# Map a user (or group) name to an SID on the current system
Function UserName2Sid () {
  Param (
    [Parameter(Mandatory=$true)] [string] $userName, 
    [string] $domain
  )
  if ($domain -ne '') {
    $userName = $userName.replace('{domain}', $domain)
  }
  $domain,$user = $userName.split('\')
  try {
    $objUser = New-Object System.Security.Principal.NTAccount($domain, $user)
    $strSID = $objUser.Translate([System.Security.Principal.SecurityIdentifier])
    return $strSID.Value
  } catch {
    writeLogMessage "ERROR`t Username '$userName' unknown on this machine: $_"
    return ""
  }
} # UserName2Sid

# Map an SID on the current system to a (symbolic) user (or group) name,
# replacing domain with {domain}
Function Sid2UserName () {
  Param (
    [Parameter(Mandatory=$true)] [string] $sid,
    [string] $domain
  )
  try {
    $objSID = New-Object System.Security.Principal.SecurityIdentifier ($sid)
    $objUser = $objSID.Translate([System.Security.Principal.NTAccount])
    $userName = $objUser.Value
    if ($domain -ne '') {
      $userName = $userName.replace($domain, '{domain}')
    }
    return $userName
  } catch {
    writeLogMessage "ERROR`t SID '$sid' unknown on this machine: $_"
    return ""
  }
} # Sid2UserName

# Read saved SID-based ACLs from a file and write name-based ACLs to a new file.
Function replaceSidWithUsername ($fromFile, $toFile, [int] $exitCode) {
  # Read file with ACLs
  try {
    $acls = Get-Content -Path $fromFile -Encoding Unicode
  } catch {
    writeLogMessage "ERROR`t replaceSidWithUsername Cannot read file '$fromFile': $_"
    finish $exitcode
  }

  # Get all SIDs (unique).
  [regex]$re = 'S[0-9-]{5,}'
  $sids = $re.Matches($acls) | Select-Object -uniq

  # Get user names for all known SIDs
  $UserNames = @{}
  foreach ($sid in $sids) {
    $userName = Sid2UserName -sid $sid -domain $domain
    if ($userName -ne "") {
      $UserNames.add($sid, $userName)
    }
  }
  
  # Replace all SIDs with user names
  foreach ($sid in $UserNames.Keys) {
    try {
      $acls = $acls.replace($sid, ">>$($UserNames[$sid])<<")
    } catch {
      writeLogMessage "ERROR`t Cannot translate SID '$sid' to a user name: $_"
    }
  }
  
  #  Write result to file
  try {
    $acls | Set-Content -Path $toFile -Encoding UTF8
  } catch {
    writeLogMessage "ERROR`t replaceSidWithUsername Cannot write file '$toFile': $_"
  }
} # Function replaceSidWithUsername


# Read saved name-based ACLs from a file and write SID-based ACLs to a new file.
Function replaceUsernameWithSid ($fromFile, $toFile, [int] $exitcode) {
  # Read file with ACLs
  try {
    $acls = Get-Content -Path $fromFile -Encoding UTF8
  } catch {
    writeLogMessage "ERROR`t replaceUsernameWithSid Cannot read file '$fromFile': $_"
    finish $exitcode
  }
  
  # Get all user ids (unique).
  [regex]$re = '>>.*?<<'    # non-greedy regular expression
  [string[]]$userNames = $re.Matches($acls) | Select-Object -uniq
  
  # Get SIDs for all user names
  $Sids = @{}
  foreach ($userName in $userNames) {
    $user = $userName.replace('>>', '').replace('<<','')
    $sid = UserName2Sid -username $user -domain $domain
    if ($sid -ne "") {
      $Sids.add($userName, $sid)
    }
  }
  
  # Replace all user names with SIDs
  foreach ($userName in $Sids.Keys) {
    try {
      $acls = $acls.replace($userName, "$($Sids[$userName])")
    } catch {
      writeLogMessage "ERROR`t replaceUsernameWithSid Cannot translate user name '$userName' to a SID: $_"
    }
  }
  
  #  Write result to file
  try {
    $acls | Set-Content -Path $toFile -Encoding Unicode
  } catch {
    writeLogMessage "ERROR`t replaceUsernameWithSid Cannot write file '$toFile': $_"
  }
} # Function replaceUsernameWithSid 

# Generate the ACL file name for a directory
Function aclFile ($directory) {
  $fileName = Split-Path $directory -Leaf
  $fileName += '.acls'
  $filePath = "$directory\$fileName"
  return $filePath
} # Function aclFile

# Save ACLs of a directory to a file in the directory named after it.
Function saveAcls($directory, [int] $exitcode) {
  $aclFile = aclFile -directory $directory
  $tmpFile = "$tempdir\temp.acls"
  try {
    writeLogMessage "INFO`t Saving ACLs of '$directory' to '$aclFile'"
    & icacls $directory /save $tmpFile /T /C /Q
    replaceSidWithUsername -fromFile $tmpFile -tofile $aclFile -exitCode $exitcode
    Remove-Item $tmpFile
    writeLogMessage "INFO`t It's ok if it says '0 files processed' above"
    $fileSize = (get-item $aclFile).length
    writeLogMessage "INFO`t ACL save finished. ACL file has length '$fileSize'"
  } catch {
    writeLogMessage "ERROR`t saveAcls Cannot save ACLs to '$aclFile': $_ "
  }
} # Function saveAcls

# Save Uninstall information from registry to a file in the program directory.
Function saveUninstallInformation ($exitCode) {
  & reg export "HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Uninstall\PostgreSQL $pgMajorVersion" $regUninstallFile /y
  if ($LASTEXITCODE -ne 0) {
    writeLogMessage "ERROR: Cannot save Uninstall information from registry to '$regUninstallFile'. $_"
    finish $exitCode
  }
} # Function saveUninstallInformation


# Restore ACLs of a directory from a file in the directory named after it.
Function restoreAcls($directory, [int] $exitcode) {
  $aclFile = aclFile -directory $directory
  $tmpFile = "$tempdir\temp.acls"
  try {
    writeLogMessage "INFO`t Restoring ACLs of directory '$directory'"
    replaceUsernameWithSid -fromFile $aclFile -toFile $tmpFile -exitcode $exitcode
    $parentDir = Split-Path $directory -parent
    & icacls $parentDir /restore $tmpFile /C /Q
    Remove-Item $tmpFile
    writeLogMessage "INFO`t ACLs restored"
  } catch {
    writeLogMessage "ERROR`t Cannot restore ACLs from '$aclFile': $_"
  }
} # Function restoreAcls

Function createPgService ([int] $exitcode) {
  try {
    $binPath = '\"' + (Split-Path -Path $pgProgDir -parent) +'\' # 'C:\Program Files\PostgreSQL\'
    $binPath += $pgMajorVersion
    $binPath += '\bin\pg_ctl.exe\" runservice -N \"'
    $binPath += $PgService
    $binPath += '\" -D \"'+ (Split-Path -Path $pgDataDir -parent) +'\' # G:\databases\PostgreSQL\
    $binPath += $pgMajorVersion
    $binPath += '\" -w'

    # Call sc.exe to create service. Service depends on RpcSs service
    $depend = "RpcSs"   # Remote Procedure Call
    & sc.exe create $PgService binPath= $($binPath) depend= "$depend" obj= "$serviceuser" DisplayName= "$PgService" password= "$pass"
    if ($LASTEXITCODE -eq 0) {
      writeLogMessage "INFO`t Service '$PgService' created"
    } else {
      writeLogMessage "ERROR`t Cannot create PostgreSQL service '$PgService'. sc.exe last exit code is '$LASTEXITCODE', $_"
      finish $exitcode
    }
    # set service description
    $description = "Provides PostgreSQL database service For NEWPOSS"
    Set-Service $PgService -description $description
  } catch {
    writeLogMessage "ERROR`t Cannot create PostgreSQL service: $_"
    finish $exitcode
  }
} # createPgService


Function setPermissions ([int] $exitcode) {
  try {
    # Create missing directories
    writeLogMessage "INFO`t Creating log and conf.d folders"
    If (-Not (Test-Path -Path "$pgDataDir\log")) { New-Item -ItemType directory -Path $pgDataDir\log -ea SilentlyContinue | Out-Null } 
    If (-Not (Test-Path -Path "$pgDataDir\conf.d")) { New-Item -ItemType directory -Path $pgDataDir\conf.d -ea SilentlyContinue | Out-Null } 

    # Create dummy files
    writeLogMessage "INFO`t Creating postmaster and dummy sslfiles"
    If (-Not (Test-Path -Path "$pgDataDir\postmaster.opts")) { New-Item -ItemType file -Path $pgDataDir\postmaster.opts -ea SilentlyContinue | Out-Null } 
    If (-Not (Test-Path -Path "$pgDataDir\ssl-cert-snakeoil.key")) { New-Item -ItemType file -Path $pgDataDir\ssl-cert-snakeoil.key -ea SilentlyContinue | Out-Null } 
    If (-Not (Test-Path -Path "$pgDataDir\ssl-cert-snakeoil.pem")) { New-Item -ItemType file -Path $pgDataDir\ssl-cert-snakeoil.pem -ea SilentlyContinue | Out-Null } 
  
    # Correct permissions
    writeLogMessage "INFO`t Setting NTFS permissions for PostgreSQL version '$pgMajorVersion'..."
    $process0 = Start-Process -FilePath "powershell" -ArgumentList "$NTFSscript -pgVersion ""$pgMajorVersion"" -logpath ""$Logpath""" -Wait -PassThru -NoNewWindow
    if ($process0.ExitCode -ne 0) {
    writeLogMessage "ERROR`t The exit code from $NTFSscript is '$($process0.ExitCode)'. Check logfile of the script at '$Logpath'"
    finish $exitcode
    }
  } catch {
    writeLogMessage "ERROR`t setPermissions $_"
    finish $exitcode
  }
} # setPermissions

Function setSuperuserPassword ([int] $exitcode) {
  # Set password for superuser 'postgres'
  try {
    WriteLogMessage "INFO`t Setting password for PostgreSQL superuser account 'postgres' ..."

    $psqlExe = "C:\Program Files\PostgreSQL\${pgMajorVersion}\bin\psql.exe"
    & $psqlExe -h localhost -U postgres -p $pgPort -c "ALTER USER postgres PASSWORD '$env:PGPASSWORD'" postgres 2>&1 | ForEach-Object {
      if ($_ -match "^ERROR.*") {
        writeLogMessage "ERROR`t ExecutePSQL failed: $_"
        finish $exitCode
      }
    writeLogMessage "INFO`t $_"
    } # ForEach-Object 
  } catch {
    writeLogMessage "ERROR`t Could not set password for role 'postgres' $_"
    Exit $exitCode
  }
} # Function setSuperuserPassword


Function createDbCluster ([int] $exitcode) {

    $argList = "--auth=trust --data-checksums -D $pgDataDir -E unicode -U postgres"
    writeLogMessage "INFO`t Creating DB cluster with '$argList'"
    $initdb = Start-Process -FilePath $pgProgDir\bin\initdb.exe -ArgumentList "$argList" -Wait -NoNewWindow -PassThru

    if ($initdb.ExitCode -eq 0) {
      writeLogMessage "INFO`t Cluster created successfully"
     } else {
      writeLogMessage "ERROR`t Cannot create new DB cluster for PostgreSQL '$pgMajorVersion'. $_"
      finish $exitcode
    }  
} # Function createDbCluster


Function portTo5433 ([int] $exitcode) {

  $autoConf = "$pgDataDir\postgresql.auto.conf"
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

Function createPostgreSQLConfig ([int] $exitcode) {
  
  writeLogMessage "INFO`t Creating configuration files for PostgreSQL"
  $process = Start-Process -FilePath "powershell" -ArgumentList "$ConfigScript" -Wait -PassThru -NoNewWindow
  if ($process.ExitCode -ne 0) {
  writeLogMessage "ERROR`t The exit code from '$ConfigScript' is '$($process.ExitCode)'. Check logfile of the script at '$Logpath'"
  finish $exitcode
  }

} # Function createPostgreSQLConfig

Function setInitialConfiguration ([int] $exitcode) {

  writeLogMessage "INFO`t Setting initial configuration for user database"
  $process = Start-Process -FilePath "powershell" -ArgumentList "$initconfig" -Wait -PassThru -NoNewWindow
  if ($process.ExitCode -ne 0) {
  writeLogMessage "ERROR`t The exit code from '$initconfig' is '$($process.ExitCode)'. Check logfile of the script at '$Logpath'"
  finish $exitcode
  }

} # Function setInitialConfiguration

Function CreateEventTrigger ([int] $exitcode) {

  # Execute only if script exists
  if ($EventTriggerScript) {
    writeLogMessage "INFO`t Create event trigger for db_owner concept"
    $process = Start-Process -FilePath "powershell" -ArgumentList "$EventTriggerScript" -Wait -PassThru -NoNewWindow
    if ($process.ExitCode -ne 0) {
      writeLogMessage "ERROR`t The exit code from '$EventTriggerScript' is '$($process.ExitCode)'. Check logfile of the script at '$Logpath'"
      finish $exitcode
    }
  } else {
    writeLogMessage "INFO`t There is no script for creation of event trigger. Skipping"
  }

} # Function CreateEventTrigger

Function CreateAdministrativeViews ([int] $exitcode) {

  # Execute only if script exists
  if ($pgInfoScript) {
    writeLogMessage "INFO`t Create event trigger for db_owner concept"
    $process = Start-Process -FilePath "powershell" -ArgumentList "$pgInfoScript" -Wait -PassThru -NoNewWindow
    if ($process.ExitCode -ne 0) {
      writeLogMessage "ERROR`t The exit code from '$pgInfoScript' is '$($process.ExitCode)'. Check logfile of the script at '$Logpath'"
      finish $exitcode
    }
  } else {
    writeLogMessage "INFO`t There is no script for creation of administrative Views. Skipping"
  }

} # Function CreateAdministrativeViews

Function createShortcutPgAdmin ([int] $exitcode) {

  $TargetFile = "C:\Program Files\PostgreSQL\${pgMajorVersion}\pgAdmin 4\bin\pgAdmin4.exe"
  $ShortcutFile = "$env:Public\Desktop\pgAdmin4.lnk"
  writeLogMessage "INFO`t Creating shortcut for pgAdmin as '$ShortcutFile'" 
  try {
    $WScriptShell = New-Object -ComObject WScript.Shell
    $Shortcut = $WScriptShell.CreateShortcut($ShortcutFile)
    $Shortcut.TargetPath = $TargetFile
    $Shortcut.Save()
  } catch {
    writeLogMessage "ERROR`t Cannot create shortcut for pgAdmin. $_"
    finish $exitcode
  }  
   
} # createShortcutPgAdmin

Function InstallODBCdriver ([int] $exitcode) {

  try {
    WriteLogMessage "INFO`t Installing psqlODBC ..."
    $ODBCfile = Get-ChildItem -Path $installfileLocation\* -Include *.exe | Where-Object {$_.Name -match "psqlODBC"}
    if (-Not $ODBCfile) {
      $msg = "ERROR`t No installation file for ODBC driver found at $installfileLocation. Installation cannot proceed."
      writeLogMessage $msg
      finish $exitcode
    }
    $odbcprocess = Start-Process $ODBCfile.FullName -ArgumentList "/passive /norestart /log $logpath\psqlODBC_setup.txt" -wait -PassThru
    if ($odbcprocess.ExitCode -ne 0) {
      writeLogMessage "ERROR`t ODBC driver installation failed! STOP"
      finish $exitcode
    }
    WriteLogMessage "INFO`t psqlODBC '$ODBCfile' installed successfully"
  } catch {
    writeLogMessage "ERROR`t Installation of psqlODBC failed! ERROR: $_"
    finish $exitcode
  }
  
} # InstallODBCdriver

# Remove (existing) directory. If it fails, try again until $maxWaitSeconds
# are over (default 10 minutes).
# Return TRUE if renaming has succeeded, FALSE otherwise.
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

Function RemoveInstallationIfExists ([int] $exitcode) {

    # Delete service if already exists
    if (Get-Service -Name $PgService -ErrorAction SilentlyContinue) {
      writeLogMessage "WARNING`t Service '$PgService' already exists. Will overwrite..."
      stopPgService -pgServiceName $PgService -$exitCode $exitcode
      & sc.exe delete $PgService
      if ($LASTEXITCODE -eq 0) {
        writeLogMessage "INFO`t Service '$PgService' deleted"
      } else {
        writeLogMessage "ERROR`t Cannot create PostgreSQL service '$PgService'. sc.exe last exit code is '$LASTEXITCODE', $_"
        finish $exitcode
      }
    }

    # Drop program directory if already exists
    if (Test-Path $pgProgDir) {
      writeLogMessage "WARNING`t Program directory '$pgProgDir' already exists. Will overwrite..."
      if(!(removeDirWaitTryAgain -dir $pgProgDir)){ 
        writeLogMessage "ERROR`t Cannot remove program directory '$pgProgDir'"
        finish  $exitcode
      }
    }

    # Drop data directory if already exists
    if (Test-Path $pgDataDir) {
      writeLogMessage "WARNING`t Data directory '$pgDataDir' already exists. Will overwrite..."
      if(!(removeDirWaitTryAgain -dir $pgDataDir)){ 
        writeLogMessage "ERROR`t Cannot remove program directory '$pgDataDir'"
        finish  $exitcode
      }
    }
} # RemoveInstallationIfExists

# Wrap the PostgreSQL Program directory including ACLs in a file to C:\TMP
Function wrapPgProgDir ([int] $exitcode) {

  # Saving NTFS permissions
  saveAcls -directory $pgProgDir -exitcode $($exitcode+1)
  
  writeLogMessage "INFO`t Saving Uninstall information from registry to file '$regUninstallFile'"
  saveUninstallInformation -exitcode $($exitcode+2)
  
  # Remove old ZIP file (if present), then create ZIP file
  $zipName = "$tempdir\pg_"
  $zipName += $pgMajorVersion
  $zipName += '.zip'
  if (Test-Path $zipName) {
    try {
      Remove-Item $zipName -Force -ErrorAction Stop
    } catch {
      writeLogMessage "ERROR`t Cannot remove old ZIP file '$zipName': $_"    
      finish $($exitcode+3)
    }
  }
  writeLogMessage "INFO`t Creating ZIP file '$zipName' ..."

  & $prog7z a -r $zipName $pgProgDir
  if ($LASTEXITCODE -eq 0) {
  writeLogMessage "SUCCESS`t PostgreSQL Program directory (version $pgMajorVersion) wrapped to $zipName. Done."
  } else {
    writeLogMessage "ERROR`t wrapPgProgDir with '$prog7z'. Last exit code is '$LASTEXITCODE' $_"
    finish $($exitcode+4)
  }
} # Function wrapPgProgDir


# Unwrap the PostgreSQL Program directory from $tempdir and restore ACLs and install PostgrSQL manually
Function unwrapPgProgDir ([int] $exitcode) { 
  
  # If the script is executed again by LANDESK it automatically removes the last failed installation
  RemoveInstallationIfExists -exitcode $($exitcode+1)

  # Install latest ODBC driver
  InstallODBCdriver -exitcode $($exitcode+2)

  # Find the ZIP file
  $zipName = findZipFile -exitcode $($exitcode+3)
  
  # Unpack the ZIP file
  ExtractZipFile -zipname $zipname -exitcode $($exitcode+4)
  
  # Restore the ACLs
  restoreAcls -directory $pgProgDir -exitcode $($exitcode+5)
  
  # Create new service entry
  createPgService -exitcode $($exitcode+6)
  
  # Create new database cluster
  createDbCluster -exitcode $($exitcode+7)
  
  # Set correct NTFS permissions
  setPermissions -exitcode $($exitcode+8)
  
  # Set port to 5433 in postgresql.auto.conf
  portTo5433 -exitcode $($exitcode+9) 

  # Start the service manually and check for connection
  startPgService -pgServiceName $PgService -pgPort $pgPort -exitCode $($exitcode+10)

  # Set password for superuser 'postgres'
  setSuperuserPassword -exitCode $($exitcode+11)
  
  # Create all custom PostgreSQL config files
  createPostgreSQLConfig -exitcode $($exitcode+12)
  
  # Create user database and roles
  setInitialConfiguration -exitcode $($exitcode+13) 

  # Create event trigger for db_owner concept
  CreateEventTrigger -exitcode $($exitcode+14)

  # Create administrative views 
  CreateAdministrativeViews -exitcode $($exitcode+15)

  # Restart PostgreSQL service
  stopPgService -pgServiceName $PgService -exitCode $($exitcode+16)
  startPgService -pgServiceName $PgService -pgPort $pgPort -exitCode $($exitcode+17)

  # Add the PostgreSQl binary directory to the PATH environment variable
  writeLogMessage "INFO`t Adding directory '$PgProgDir\bin' with PostgreSQL tools to PATH."
  Add_Dir_To_PATH "$PgProgDir\bin" -prepend -exitcode 18

  # Create shortcut to pgAdmin
  createShortcutPgAdmin -exitcode $($exitcode+19)
  
  # Put Uninstall information into the registry
  WriteLogMessage "INFO`t Putting uninstall information from '$regUninstallFile' into the registry ... "
  & reg import $regUninstallFile
  if ($LASTEXITCODE -ne 0) {
    writeLogMessage "ERROR`t Last exitcode of reg.exe is '$LASTEXITCODE'. Therefore Stop!"
    finish $($exitcode+20)
  }
 
  # Stop new PostgreSQL service until day of migration
  stopPgService -pgServiceName $PgService -exitCode $($exitcode+21)
  writeLogMessage "INFO`t New service '$PgService' is left stopped and disabled until day of migration"

  writeLogMessage "SUCCESS`t PostgreSQL program directory (version $pgMajorVersion) unwrapped to '$pgProgDir'"
  writeLogMessage "SUCCESS`t New cluster created. Database service '$PgService' is running on port '$pgPort'. Done"

} # Function unwrapPgProgDir


############################################################################################
########################################## MAIN ############################################
############################################################################################
$ErrorActionPreference = "Stop"

$me=whoami
writeLogMessage ""
writeLogMessage "START (script version dated $lastchange, run by $me )"
writeLogMessage "INFO`t Library Version $($lib.Version.Major).$($lib.Version.Minor), last change $($lib.PrivateData.lastchange)"
writeLogMessage "INFO`t Logfile will be written to $script:logfile"

# Check whether we are 'NT Authority\System'
if ($me -ne "NT Authority\System") {
  writeLogMessage "ERROR`t This script has to be executed as 'NT Authority\System'"
  finish 601
}

# Check if 7z is available
if (!(Test-Path $prog7z)) {
  writeLogMessage "ERROR`t Program 7z.exe cannot be found. Please install first."
  finish 697
}

if ($wrap) {
  if ($unwrap) {
    writeLogMessage "ERROR`t Both switches -wrap and -unwrap must not be used at the same time!"
    finish 699
  }
  wrapPgProgDir -exitcode 600
  finish 0
}

if ($unwrap) {
  unwrapPgProgDir -exitcode 600
  finish 0
} else {
  writeLogMessage "ERROR`t This script needs exactly one of the switches  -wrap or -unwrap!"
  finish 698
}
# end of script