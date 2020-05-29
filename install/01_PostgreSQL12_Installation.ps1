<#
.SYNOPSIS
  Installation of PostgreSQL Database
.DESCRIPTION
    This script installs several programs related to PostgreSQL and sets the necessary
    permissions to meet the principle of least privilege.
    
    * psqlODBC - ODBC Driver
    * PostgreSQL - Database Server, using the installer by EnterpriseDB
    * Initializing a new database cluster with checksums and replacing the original one
    * Setting postgres superuser password obtained from password service
    * Replacing configuration files and adding new ones
  
  When any part fails, the script exits with an exit code > 0. Following parts won't 
  be executed.
    
.NOTES
  Last editor:  Enrico La Torre
#>

$lastchange="2020-05-29"

################################################################################
########################### CONFIGURATION PARAMETERS ###########################
################################################################################

$pgVersion = "12"

# Service name of PostgreSQL01
$pgServiceName = "postgresql${pgVersion}"
# Port for PostgreSQL cluster
$pgPort = 5432

# Data directory of PostgreSQL
$PgDataDir="G:\databases\PostgreSQL\$pgVersion"
# Program directory of PostgreSQL
$PgProgDir="C:\Program Files\PostgreSQL\$pgVersion"

# Directory of installation files
$installfileLocation = "E:\pg_admindb\Install"

# Script for creating PostgreSQL configuration files
$CreateConfig = "E:\pg_admindb\config\PostgreSQL12_CreateConfiguration.ps1"

# Script for NTFS permissions
$NTFSscript = "E:\pg_admindb\NTFS_permissions\SetPgNTFSpermissions.ps1"

# Directory for log file
$logpath = "E:\pg_admindb\logs\installation"

# PowerShell library for PostgreSQL
$libname = "E:\pg_admindb\lib\powershell_postgresql_lib.psd1"

# Service Account for PostgreSQL
$serviceuser = "DOMAIN\USER"
$useronly = "USER"

$pass = Read-Host -Prompt "Please enter password for '$serviceuser'"
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

# Set correct NTFS permissions
Function setNTFSPermissions ([string] $filename, [int] $exitCode) {
  writeLogMessage "INFO`t Calling '$filename' to set NTFS permissions..."
  
  $process1 = Start-Process -FilePath "powershell" -ArgumentList "$filename -pgVersion ""$pgVersion"" -logpath ""$logpath""" -Wait -PassThru
	if ($process1.ExitCode -eq 0) {
		writeLogMessage "SUCCESS`t Applied '$filename'"
	}
	else {
		writeLogMessage "ERROR`t Could not apply '$filename', exit code $($process1.ExitCode)"
		finish $exitCode
	}
  #Read-Host "Check NTFS Permissions if you want and press Enter to continue"
} # setNTFSPermissions

Function checkIfAlreadyInstalled() {
  writeLogMessage "INFO`t Checking for previous installation ..."
  $InstallPostgreSQL = $true
  if (Test-Path $PgProgDir) {
    writeLogMessage "WARNING`t Directory '$PgProgDir' already exists. Skipping installation."
    $InstallPostgreSQL = $false
  }
  if (Test-Path $PgDataDir) {
    writeLogMessage "WARNING`t Directory '$PgDataDir' already exists. Skipping installation."
    $InstallPostgreSQL = $false
  }
  if($InstallPostgreSQL -eq $false) {
    finish 1
  }
} # checkIfAlreadyInstalled

# Rename (existing) directory to a new name. If it fails, try again until $maxWaitSeconds
# are over (default 10 minutes).
# Return TRUE if renaming has succeeded, FALSE otherwise.
Function renameDirWaitTryAgain () {
  param(
    [parameter(Mandatory=$True)] [ValidateScript({Test-Path $_ -PathType 'container'})] [string] $old, 
    [Parameter(Mandatory=$true)] [string] $new,
    [int] $maxWaitSeconds = 600
  )
  if (Test-Path $new){
    writeLogMessage "ERROR`t Cannot rename directory because '$new' already exists."
    return $False
  } # if

  $totalWaitSecs = 0
  $sleepSecs = 10
  while ($True) {
    try {
      Rename-Item -LiteralPath $old -NewName $new -Force -EA Stop
      return $True
    } catch {
      write-host "WARNING`t Renaming of '$old' failed after $totalWaitSecs seconds."
      Start-Sleep $sleepSecs
      $totalWaitSecs += $sleepSecs
      if ($totalWaitSecs -gt $maxWaitSeconds) {
        $errMsg = $_.Exception.Message.ToString()
        writeLogMessage "ERROR`t $errMsg"
        return $False
      }
    }
  } # while forever
} # Function renameDirWaitTryAgain


################################################################################
##################################### MAIN #####################################
################################################################################
$ErrorActionPreference = "Stop"

$me=whoami
writeLogMessage ""
writeLogMessage "START (script version dated $lastchange, run by $me )"
writeLogMessage "INFO`t Library Version $($lib.Version.Major).$($lib.Version.Minor), last change $($lib.PrivateData.lastchange)"
writeLogMessage "INFO`t Logfile will be written to $script:logfile"


# checking for previous installation
checkIfAlreadyInstalled

# Installation of psqlODBC
try {
  WriteLogMessage "INFO`t Installing psqlODBC ..."
  $ODBCfile = Get-ChildItem -Path $installfileLocation\* -Include *.exe | Where-Object {$_.Name -match "psqlODBC"}
  if (-Not $ODBCfile) {
    $msg = "ERROR`t No installation file for ODBC driver found at $installfileLocation. Installation cannot proceed."
    writeLogMessage $msg
    finish 2
  }
  $odbcprocess = Start-Process $ODBCfile.FullName -ArgumentList "/passive /norestart /log $logpath\psqlODBC_setup.txt" -wait -PassThru
  if ($odbcprocess.ExitCode -ne 0) {
    writeLogMessage "ERROR`t ODBC driver installation failed! STOP"
    finish 3
  }
  WriteLogMessage "INFO`t psqlODBC '$ODBCfile' installed successfully"
} catch {
  writeLogMessage "ERROR`t Installation of psqlODBC failed! ERROR: $_"
  finish 2
}

# Installation of PostgreSQL using the EnterpriseDB installation package
try {
  WriteLogMessage "INFO`t Installing PostgreSQL ..."
  $installfile = Get-ChildItem -Path $installfileLocation\* -Include *.exe | Where-Object {$_.Name -match "postgresql"} 
  if (-Not $installfile) {
    $msg = "ERROR`t No installation file for PostgreSQL found at $installfileLocation. Installation cannot proceed."
    writeLogMessage $msg
    finish 3
  }
  $installProcess = Start-Process $installfile.FullName -ArgumentList "--mode unattended --unattendedmodeui minimalWithDialogs --superpassword $env:PGPASSWORD --servicename $pgServiceName --serviceaccount $serviceuser --servicepassword $pass --datadir $PgDataDir --serverport $pgPort --install_runtimes no --disable-components stackbuilder --enable_acledit 1" -Wait -PassThru
  if ($installProcess.ExitCode -ne 0) {
    writeLogMessage "ERROR`t PostgreSQL installation failed! STOP"
    finish 3
  }
  WriteLogMessage "INFO`t PostgreSQL installed successfully"
} catch {
  writeLogMessage "ERROR`t Installation of PostgreSQL failed! ERROR: $_"
  finish 3
}

# Initialize a new DB cluster to enable checksums
writeLogMessage "INFO`t Initialize a new DB cluster to enable checksums" 
try {
  stopPgService -pgServiceName $pgServiceName -exitCode 4
  $TempPgDataDir = $PgDataDir + "-2"
  # Create the new cluster with checksums
  writeLogMessage "INFO`t initdb of cluster with checksums..."
  Start-Process "$PgProgDir\bin\initdb.exe" -ArgumentList "--auth=trust -k -D $TempPgDataDir -E unicode -U postgres" -Wait
  # Remove the old cluster which has been created without checksums
  Remove-Item -path $PgDataDir -Force -Recurse
  Start-Sleep -seconds 15
  if (Test-Path -path $PgDataDir) {
    Remove-Item -path $PgDataDir -Force -Recurse -ErrorAction Stop
  }
  # Rename the new cluster to the original name
  renameDirWaitTryAgain -old $TempPgDataDir -new $PgDataDir
  WriteLogMessage "INFO`t New db cluster with data checksums has been created."
  # Create dummy directories for NTFS script to work correctly
  writeLogMessage "INFO`t Creating dummy files for NTFS script..."
  New-Item -ItemType directory -Path $PgDataDir\conf.d -Force | Out-Null 
  New-Item -ItemType directory -Path $PgDataDir\log -Force | Out-Null 
  New-Item -ItemType file -Path $PgDataDir\postmaster.opts -Force | Out-Null 
  New-Item -ItemType file -Path $PgDataDir\ssl-cert-snakeoil.key -Force | Out-Null 
  New-Item -ItemType file -Path $PgDataDir\ssl-cert-snakeoil.pem -Force | Out-Null 
  # Apply NTFS permissions
  setNTFSPermissions -filename $NTFSscript -exitCode 9
  # Start PostgreSQL
  StartPgService -pgServiceName $pgServiceName -pgPort $pgPort -exitCode 5
  Set-Service $pgServiceName -description "Provides PostgreSQL Database Service"
} catch {
  WriteLogMessage "ERROR`t New db cluster with data checksum could not be created: $($_.Exception)"
  finish 6
}

# Set password for superuser 'postgres'
try {
  WriteLogMessage "INFO`t Setting default password ..."
  & "$PgProgDir\bin\psql.exe" -U postgres -c "ALTER USER postgres PASSWORD '$env:PGPASSWORD'" postgres
} catch {
  WriteLogMessage "ERROR`t Could not set default password"
  WriteLogMessage "ERROR`t $($_.Exception)"
  finish 604
}

# Create configuration files
try {
  stopPgService -pgServiceName $pgServiceName -exitCode 4
 
  # Execute script for creation of config files
  writeLogMessage "INFO`t Creating config files"
  $CreateConfig = Start-Process -FilePath "powershell" -ArgumentList $CreateConfig -Wait -PassThru
  if ($CreateConfig.ExitCode -ne 0) {
    writeLogMessage "ERROR`t  The config files could not be created with '$CreateConfig'. Exit code $($CreateConfig.ExitCode)"
    finish 7
  }
  # Apply NTFS permissions
  setNTFSPermissions -filename $NTFSscript -exitCode 9
  # Start PostgreSQL
  StartPgService -pgServiceName $pgServiceName -exitCode 5
} catch {
  WriteLogMessage "ERROR`t Could not create configuration files"
  WriteLogMessage "ERROR`t $($_.Exception)"
  finish 8
}

# Add the PostgreSQl binary directory to the PATH environment variable
writeLogMessage "INFO`t Adding directory '$PgProgDir\bin' with PostgreSQL tools to PATH."
Add_Dir_To_PATH "$PgProgDir\bin" -prepend -exitcode 10

WriteLogMessage "SUCCESS`t Installation of PostgreSQL completed. Initial configuration should follow."
finish 0
