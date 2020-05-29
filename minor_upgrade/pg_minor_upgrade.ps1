<#
.SYNOPSIS
  Script for a minor upgrade of a local PostgreSQL installation
.DESCRIPTION
 This script serves two purposes.

 A - Option -wrap used

     Purpose: Wrap the contents of a new PostgreSQL program directory version
     to a ZIP file for distributing to other machines. Set the variable
     $pgMajorVersion below in the section CONFIGURATION PARAMETERS.

     Wrap the contents of the directory C:\Program Files\PostgreSQL\{MAJOR}
     to a ZIP file named pg_{MAJOR}.{MINOR}.zip (the new version).

     Before actually doing that, the ACLs of the directory and its 
     contents are saved to a file {MAJOR}.minor.upgrade.acls with UTF8 encoding,
     where the SIDs of the principals have been replaced by symbolic names
     in the format DOMAIN\USER. The file is placed into the directory, so
     that it is contained in the ZIP file.

 B - Option -unwrap used

     Purpose: Unwrap the previously wrapped ZIP file and replace the current
     PostgreSQL program directory by the new version.

     Hint: unwrapping must not be done during business hours.

     Unwrap the contents of the ZIP file pg_{MAJOR}.{MINOR}.zip to the directory
     C:\Program Files\PostgreSQL\{MAJOR}.

     After the unwrapping of the file, the ACLs from the file 
     {MAJOR}.minor.upgrade.acls are read, the symbolic names are mapped to SIDs 
     on the current system and applied to the directory.

     Then the PostgreSQL service is stopped, and the directory 
     C:\Program Files\PostgreSQL\{MAJOR} is renamed to 
     {MAJOR}{MINOR-old} (the existing version). Then the directory 
     C:\Program Files\PostgreSQL\{MAJOR}.minor.upgrade is renamed to 
     C:\Program Files\PostgreSQL\{MAJOR}

     Then, the service 'postgresql' or 'postgresqlMAJOR' is started again and a 
     check for accessibility is performed. Should it fail, the system is reverted
     to the previous version.

 It's the responsibility of the user to make sure that the symbolic names 
 of AD users and groups exist identically on the source and the target machine.
 Numbers of domains are replaced by {domain} in the 
 file, and replaced back on the target machine to the appropriate values.
.NOTES
    Author:			Enrico La Torre 
    Date:			  2020-01-17
#>
################################################################################
############################## PROCESS PARAMETERS ##############################
################################################################################
param(
  [switch] $wrap, 
  [switch] $unwrap
)
# Use always exactly one of the following switches:
#    -wrap
#    -unwrap
# In the case of -wrap the PG program directory will be wrapped to
#    $tempdir\pg_{MAJOR}.{MINOR}.zip
# In the case of -unwrap the PG program directory will be overwritten by
#    data extracted from $tempdir\pg_{MAJOR}.{MINOR}.zip;
# there must be only one file in $tempdir matching this pattern, and the current version
# must be a lower one - downgrades will be refused.


################################################################################
########################### CONFIGURATION PARAMETERS ###########################
################################################################################

$lastchange = "2020-03-31 12:23"

# Major Version
$pgMajorVersion = "12"
$pgPort = 5432

# PostgreSQL service name
$PgService = "postgresql$pgMajorVersion"
# PostgreSQL program directory
$pgProgDir = "C:\Program Files\PostgreSQL\$pgMajorVersion"

# Directory of temporary directory
$tempdir = "C:\TMP"
# Full path of 7z program
$prog7z = 'E:\pg_admindb\minor_upgrade\7-Zip64\7z.exe'

# Directory for log file
$Logpath = "E:\pg_admindb\logs\minor_upgrade"

# PowerShell library for PostgreSQL
$libname = "E:\pg_admindb\lib\powershell_postgresql_lib.psd1"

# Domain (FQDN)
$domainFQDN = (Get-WmiObject win32_computersystem).Domain
$domain = $domainFQDN.Split('.')[0]

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


# Get PostgreSQL version from C:\Program Files\PostgreSQL\MAJOR\include\server\pg_config.h
Function getFullPostgresVersion ([string] $major, [int] $exitcode) {
  $dirName = 'C:\Program Files\PostgreSQL\'
  $dirName += $major
  if (!(Test-Path $dirName -PathType Container)) {
    writeLogMessage "ERROR`t You provided '$major' as Major version of PostgreSQL to getFullPostgresVersion, but directory '$dirName' does not exist."
    finish $exitcode
  }
  $dirName += '\include\server\'
  $fileName = ($dirName + 'pg_config.h')
  if (!(Test-Path $fileName -PathType Leaf)) {
    writeLogMessage "ERROR`t You provided '$major' as Major version of PostgreSQL to getFullPostgresVersion, but file '$fileName' does not exist."
    finish $exitcode
  }
  $regexp = "define PACKAGE_VERSION `"($major.[0-9]+)`""
  $fullVersion = ((Select-String -Path $fileName -pattern $regexp).Matches.Groups[1])
  return $fullVersion
} # Function getFullPostgresVersion

# Rename (existing) directory to a new name. If it fails, try again until $maxWaitSeconds
# are over (default 10 minutes).
# Return TRUE if renaming has succeeded, FALSE otherwise.
Function renameDirWaitTryAgain () {
  param(
    [ValidateScript({Test-Path $_ -PathType 'container'})] [string] $old, 
    [string] $new,
    [int] $maxWaitSeconds = 600
  )
  if (Test-Path $new){
    writeLogMessage "ERROR: Cannot rename directory because '$new' already exists."
    return $False
  } # if

  $totalWaitSecs = 0
  $sleepSecs = 10
  while ($True) {
    try {
      Rename-Item -LiteralPath $old -NewName $new -Force -ErrorAction Stop
      return $True
    } catch {
      writeLogMessage "WARNING`t Renaming of '$old' failed after $totalWaitSecs seconds. Trying again..."
      Start-Sleep $sleepSecs
      $totalWaitSecs += $sleepSecs
      if ($totalWaitSecs -gt $maxWaitSeconds) {
        writeLogMessage "ERROR`t Renaming of '$old' failed: $_"
        return $False
      }
    }
  } # while forever
} # Function renameDirWaitTryAgain
# Copy (unziped) directory to a new name. If it fails, try again until $maxWaitSeconds
# are over (default 10 minutes).
# Return TRUE if renaming has succeeded, FALSE otherwise.
Function copyDirWaitTryAgain () {
  param(
    [ValidateScript({Test-Path $_ -PathType 'container'})] [string] $old, 
    [string] $new,
    [int] $maxWaitSeconds = 600
  )
  if (Test-Path $new){
    writeLogMessage "ERROR: Cannot copy directory because '$new' already exists."
    return $False
  } # if

  $totalWaitSecs = 0
  $sleepSecs = 10
  while ($True) {
    try {
        Copy-Item -Path $old -Destination $new -Recurse -Force -ErrorAction Stop

        #restoreAcls -directory $pgProgDir -exitcode $($exitcode+6)
        #Rename-Item -LiteralPath (restoreAcls -directory $pgProgDir) -NewName (aclFile -directory $new)  -Force -ErrorAction Stop
        #aclFile -directory $new
        #rename *.acls!!!!!
        
        return $True
    } 
    catch {
      writeLogMessage "WARNING`t Copy of '$old' failed after $totalWaitSecs seconds. Trying again..."
      Start-Sleep $sleepSecs
      $totalWaitSecs += $sleepSecs
      if ($totalWaitSecs -gt $maxWaitSeconds) {
        writeLogMessage "ERROR`t Copy of '$old' failed: $_"
        return $False
      }
    }
  } # while forever
} # Function copyDirWaitTryAgain

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
# replacing domain name with {domain}
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
  #$fileName = Split-Path $directory -Leaf
  $fileName += '*.acls'
  $fileName = Get-ChildItem -Path $directory\$fileName -Recurse -Name
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
    finish $exitcode
  }
} # Function saveAcls


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
    finish $exitcode
  }
} # Function restoreAcls


# Find the ZIP file with the contents of the PostgreSQL Program Folder.
# Make sure only one matching file exists.
Function findZipFile ([int] $exitcode) {
  try {
    [string []]$files = Get-ChildItem -Path "$tempdir\*" -Include "pg_${pgMajorVersion}.*.zip"
    if ($files.length -eq 0) {
      writeLogMessage "ERROR`t No ZIP file found matching '$tempdir\pg_${pgMajorVersion}.*.zip'"
      finish $exitcode
    }
    if ($files.length -gt 1) {
      writeLogMessage "ERROR`t More than one ZIP file found matching '$tempdir\pg_${pgMajorVersion}.*.zip'"
      writeLogMessage ("INFO`t Files found: " + ($files -join ", "))
      finish $exitcode
    }
    return $files[0]
  } catch {
    writeLogMessage "ERROR`t findZipFile: $_"
    finish $exitcode
  }
} # Function findZipFile


# Revert to old minor version (in case the new one is not working)
Function revertToOldVersion ([string] $oldFullVersion, [string] $dir, [int] $exitcode) {
  # Stop related services
  stopRelatedServices -exitcode $exitCode
  # Stop service$
  stopPgService -pgServiceName $PgService -exitcode $exitcode
  Set-Service -Name $PgService -StartupType "Automatic" 
  
  # Remove failed directory
  writeLogMessage "INFO`t Removing failed program directory '$dir' ..."
  if (!(removeDirWaitTryAgain -dir $dir)) {
    writeLogMessage "ERROR`t Cannot remove program directory '$dir'. Maybe you can remove it manually later and rename the program directory to its original name."
    finish $($exitcode+1)
  }
  
  # Rename old program directory to become active again
  $oldName = Split-Path $pgProgDir -parent
  $oldName += '\'
  $oldName += $oldFullVersion
  writeLogMessage "INFO`t Renaming old program directory '$oldName' to original name '$pgProgDir' ..."
  if (!(renameDirWaitTryAgain -old $oldName -new $pgProgDir)) {
    writeLogMessage "ERROR`t Old service (PostgreSQL version $oldFullVersion) cannot be re-activated. You're out of luck!"
    finish $($exitcode+2)
  }
   
  # Start service with old version
  StartPgService -pgServiceName $PgService -pgPort $pgPort -exitCode $($exitcode+3)
  # Start related services
  startRelatedServices -exitcode $($exitcode+3)
  
  writeLogMessage "INFO`t Old PostgreSQL (version $oldFullVersion) up and running again."
} # Function revertToOldVersion


# Wrap the PostgreSQL Program directory including ACLs in a file to $tempdir
Function wrapPgProgDir ([int] $exitcode) {
  
  writeLogMessage "INFO`t Wrapping PostgreSQL program directory '$pgProgDir'"
  $fullVersion = getFullPostgresVersion -major $pgMajorVersion -exitcode $exitcode
  writeLogMessage "INFO`t Full PostgreSQL version to be wrapped: $fullVersion"
  
  # Stop related services
  stopRelatedServices -exitcode $($exitCode+1)
  # Stop postgresql service
  stopPgService -pgServiceName $pgService -exitcode $($exitCode+2)
  Set-Service -Name $PgService -StartupType "Automatic" 

  # Rename program directory that it can be extracted in an other PG program directory
  $parentDir = Split-Path $pgProgDir -parent
  $newName = $parentDir
  $newName += '\'
  $newName += $fullVersion
  $newName += '.minor.upgrade'
  writeLogMessage "INFO`t Renaming PostgreSQL program directory from '$pgProgDir' to '$newName' ..."
  if (!(renameDirWaitTryAgain -old $pgProgDir -new $newName)) {
    writeLogMessage "ERROR`t Cannot rename existing PostgreSQL program directory. Giving up."
    finish $($exitcode+3)
  }

  # Saving ACLS on old program directory 
  saveAcls -directory $newName -exitcode $($exitcode+4)

  $zipName = "$tempdir\pg_"
  $zipName += $fullVersion
  $zipName += '.zip'
  # Delete wrapped file if exists 
  if (Test-Path $zipName) {
    try {
      Remove-Item $zipName -Force -ErrorAction Stop
    } catch {
      writeLogMessage "ERROR`t Cannot remove old ZIP file '$zipName': $_"
      finish $($exitcode+5)
    }
  }
  writeLogMessage "INFO`t Creating ZIP file '$zipName' ..."
  try {
    & $prog7z a -r $zipName $newName
    if ($LASTEXITCODE -eq 0) {
      writeLogMessage "SUCCESS`t PostgreSQL Program directory (version $fullVersion) wrapped to '$zipName'. Done."
    } else {
      writeLogMessage "ERROR`t wrapPgProgDir with '$prog7z'. Last exit code is '$LASTEXITCODE' $_"
      finish $($exitcode+6)
    }
  
  # Rename the new program directory back to its original name that the service can start again
  writeLogMessage "INFO`t Renaming PostgreSQL program directory from '$newName' to '$pgProgDir' ..."
  if (!(renameDirWaitTryAgain -old $newName -new $pgProgDir)) {
    writeLogMessage "ERROR`t Cannot rename existing PostgreSQL program directory. Giving up."
    finish $($exitcode+7)
  }

  # Start the PostgreSQL service again
  StartPgService -pgServiceName $PgService -pgPort $pgPort -exitCode $($exitcode+8)
  # Start related services
  startRelatedServices -exitcode $($exitcode+9)
  } catch {
    writeLogMessage "ERROR`t wrapPgProgDir with '$prog7z': $_ "
    finish $($exitcode+10)
  }
} # Function wrapPgProgDir


# Unwrap the PostgreSQL Program directory from $tempdir and restore ACLs
Function unwrapPgProgDir ([int] $exitcode) {

  # Check time of day - unwrapping must not run during business hours
  $now = get-date -format "HHmm"
  if ($now -gt "0600" -and $now -lt "2200") {
    writeLogMessage "ERROR`t This script must not be executed during business hours (0600 to 2200)."
    finish $exitCode
  } 

  # Get the old minor and major version number
  [string] $oldFullVersion = getFullPostgresVersion -major $pgMajorVersion -exitcode $($exitcode+1)
  $oldFullVersion -match '.*\.([0-9]+)$' | Out-Null
  [int] $oldMinorVersion = $Matches[1]
  
  # Get the new minor and major version number
  $zipName = findZipFile -exitcode $($exitcode+2)
  $zipName -match 'pg_.*\.([0-9]+)\.zip' | Out-Null
  [int] $newMinorVersion = $Matches[1]
  $zipName -match 'pg_([0-9.]+)\.zip' | Out-Null
  [string] $newFullVersion = $Matches[1]
  
  if (!($newMinorVersion -gt $oldMinorVersion)) {
    writeLogMessage "ERROR`t new PostgreSQL version ($newFullVersion) not newer than old version ($oldFullVersion)"
    finish $($exitcode+3)
  }

  # Unpack the ZIP file
  $parentDir = Split-Path $pgProgDir -parent
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
      finish $($exitcode+4)
    }
    # Jump back to previous dir
    Set-Location $oldLocation
  } catch {
    writeLogMessage "ERROR`t Cannot unzip '$zipName': $_"
    finish $($exitcode+5)
  }

  # Restore the ACLs
  $parentDir = Split-Path $pgProgDir -parent
  $oldName = $parentDir
  $oldName += '\'
  $oldName += $newFullVersion + '.minor.upgrade'
  restoreAcls -directory $oldName -exitcode $($exitcode+6)
  
  # Stop related services
  stopRelatedServices -exitcode $($exitCode+7)
  # Stop postgresql service
  stopPgService -pgServiceName $pgService -exitcode $($exitCode+8)
  Set-Service -Name $PgService -StartupType "Automatic" 

  # Rename existing program directory
  $parentDir = Split-Path $pgProgDir -parent
  $newName = $parentDir
  $newName += '\'
  $newName += $oldFullVersion
  writeLogMessage "INFO`t Renaming PostgreSQL program directory from '$pgProgDir' to '$newName' ..."
  if (!(renameDirWaitTryAgain -old $pgProgDir -new $newName)) {
    writeLogMessage "ERROR`t Cannot rename existing PostgreSQL program directory. Giving up."
    StartPgService -pgServiceName $PgService -pgPort $pgPort -exitCode $($exitCode+9)
    startRelatedServices -exitcode $($exitCode+9)
    finish $($exitcode+9)
  }

  # Rename extracted program directory
  $parentDir = Split-Path $pgProgDir -parent
  $oldName = $parentDir
  $oldName += '\'
  $oldName += $newFullVersion + '.minor.upgrade'
  writeLogMessage "INFO`t Renaming extracted PostgreSQL program directory from '$oldName' to '$pgProgDir' ..."
  if (!(renameDirWaitTryAgain -old $oldName -new $pgProgDir)) {
    writeLogMessage "ERROR`t Cannot rename existing PostgreSQL program directory. Proceed with copy from '$oldName' to '$pgProgDir' ..."
    if (!(copyDirWaitTryAgain -old $oldName -new $pgProgDir)) {
      writeLogMessage "ERROR`t Cannot copy '$oldName' program directory. Giving up."
      writeLogMessage "INFO`t Reverting back to previous version '$oldFullVersion'"
      revertToOldVersion -oldFullVersion $oldFullVersion -dir $oldName -exitcode $($exitcode+10)
      finish $($exitcode+10)
    }
  }
 
  # Start the PostgreSQL service again
  # Use special exit code -1 that a fail does not terminate the script
  StartPgService -pgServiceName $PgService -pgPort $pgPort -exitCode -1

  if (-Not ((Get-Service -Name $PgService).Status -eq "Running")) {
    writeLogMessage "ERROR`t Cannot start service '$PgService' for upgraded PostgreSQL installation ($newFullVersion)"
    writeLogMessage "ERROR`t Reverting back to previous version '$oldFullVersion'"
    revertToOldVersion -oldFullVersion $oldFullVersion -dir $pgProgDir -exitcode $($exitcode+13)
  }

  # Start related services
  startRelatedServices -exitcode $($exitcode+11)

  writeLogMessage "SUCCESS`t New PostgreSQL version ($newFullVersion) up and running"
} # Function unwrapPgProgDir


################################################################################
##################################### MAIN #####################################
################################################################################
$ErrorActionPreference = "Stop"

$me=whoami
writeLogMessage ""
writeLogMessage "START (script version dated $lastchange, run by $me )"
writeLogMessage "INFO`t Library Version $($lib.Version.Major).$($lib.Version.Minor), last change $($lib.PrivateData.lastchange)"
writeLogMessage "INFO`t Logfile will be written to $script:logfile"

# Check whether we are "NT Authority\System"
if ($me -ne "NT Authority\System") {
  writeLogMessage "ERROR`t This script has to be executed as 'NT Authority\System'"
  finish 601
}

# Check if 7z is available
if (!(Test-Path $prog7z)) {
  writeLogMessage "ERROR`t Program 7z.exe cannot be found at '$prog7z'. Please install first."
  finish 697
}

if ($wrap) {
  if ($unwrap) {
    writeLogMessage "ERROR`t Both switches -wrap and -unwrap must not be used at the same time!"
    finish 699
  }
  wrapPgProgDir -exitcode 602
  finish 0
}

if ($unwrap) {
  if (-Not (Test-Path -Path $tempdir)) {New-Item -ItemType Directory -Force -Path $tempdir | Out-Null}
  unwrapPgProgDir -exitcode 603
  finish 0
} else {
  writeLogMessage "ERROR`t This script needs exactly one of the switches  -wrap or -unwrap!"
  finish 698
}
# end of script