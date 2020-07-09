<#
.SYNOPSIS
    Create a base backup of a PostgreSQL cluster
.DESCRIPTION
    This script creates a base backup with pg_basebackup. A base backup can 
    be used for a Point-In-Time-Recovcery (PITR).

    The $backupuser needs the Replication attribute in PostgreSQL and the 
    pg_hba.conf file must be confiugred to allow replication connections.

    Requires PostgreSQL Powershell library.
.NOTES
    Author:			Enrico La Torre 
    Date:			  2020-07-02
#>

################################################################################
############################## PROCESS PARAMETERS ##############################
################################################################################
param(
# Connection parameters
[string] $server = "localhost"
,[string] $backupuser = "backup"
,[string] $pgPort = "5432"
# Backup parameters
,[string] $backupdir
,[string] $walmethod = "stream"
,[string] $checkpoint = "fast"
,[int] $keepOldBackups = 2
# p = plain (default), t = tar (compressed)
,[string] $format = "p"
# WAL Archive
,[string] $CleanUpWALArchive # = "Y" for e.g.
,[string] $WALarchiveDir
# PostgreSQL program directory. Version will be evaluated later
,$PgProgDir = "C:\Program Files\PostgreSQL"
# PostgreSQL data directory. Version will be evaluated later
,$PgDataDir = "G:\databases\PostgreSQL"
# Directory for log file
,[string] $logpath
# Directory for 7z.exe utility
,[string] $prog7z
)

################################################################################
########################### CONFIGURATION PARAMETERS ###########################
################################################################################
$lastchange = "2020-07-09 10:19"

# Timestamp for file names
$timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"

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

# Remove (existing) directory. If it fails, try again until $maxWaitSeconds
# are over (default 10 minutes).
# Return TRUE if renaming has succeeded, FALSE otherwise.
Function removeDirWaitTryAgain () {
    param(
      [string] $dir, 
      [int] $maxWaitSeconds = 600
    )
    $totalWaitSecs = 0
    $sleepSecs = 10
    while ($True) {
      try {
        Remove-Item -Path $dir -Recurse -Force -ErrorAction Stop
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

Function getPgMajorVersion ([int] $portNo = 5432, [string] $user) {
    $version = getPgVersionOdbc -portNo $portNo -dbUser $user
    if ($version -eq "") {
      return ""
    }
    return [regex]::Match($version, '^(.*)\.[0-9]+$').captures.groups[1].value
} # Function getPgMajorVersion

Function deleteOldBackupFiles () {

    param(
      [string] $backupdir
      ,[string] $filter
      ,[int] $keepOldFiles = 2
      ,[int] $exitcode
    )
  
    try {
        writeLogMessage "INFO`t Deleting objects in '$backupdir' with filter '$filter'. Keeping $keepOldFiles objects ..."
        # Get all old files
        $filenameArray = Get-ChildItem -Path "$backupdir" -Filter "$filter"
        # $keepOldFiles+1 to account for the object created in the current run
        while ($filenameArray.Count -gt $($keepOldFiles+1)) {
            # Delete the oldest one
            $del = $filenameArray | Sort-Object -Property CreationTime | Select-Object -First 1 
            if (!(removeDirWaitTryAgain -dir $del.FullName)) {
                writeLogMessage "ERROR`t Failed to remove '$del'"
                finish $exitcode
            } 
            # Get updated list and repeat
            $filenameArray = Get-ChildItem -Path "$backupdir" -Filter "$filter"
        }           
    } catch {
      writeLogMessage "ERROR`t deleteOldBackupFiles: $_"
      finish $exitcode
    }
} # Function deleteOldBackupFiles

Function CompressDirectory () {

    param(
        [string] $prog7z
        ,[string] $dir
        ,[int] $exitcode
    )

    # Location for 7.exe to run
    $DirectoryParent = Split-Path -Path $dir -Parent

    writeLogMessage "INFO`t Compressing directory '$dir'"
    try {
        # Set-Location important for 7z
        $oldLocation = Get-Location
        Set-Location -Path $DirectoryParent
        $zipname = ($dir + '.7z')
        & $prog7z a -r $zipName "$dir\*"
        if ($LASTEXITCODE -eq 0) {
            Set-Location -Path $oldLocation
            writeLogMessage "INFO`t Base backup ($script:backuplabel) compressed to '$zipName'. Done."
            writeLogMessage "INFO`t Removing uncomrpessed backup directory '$dir'"
            if (!(removeDirWaitTryAgain -dir $dir)) {
                writeLogMessage "ERROR`t Failed to remove directory '$dir'."
                finish $($exitcode+1)
            }
        } else {
            writeLogMessage "ERROR`t Failed to compress '$dir'  with '$prog7z'. Last exit code is '$LASTEXITCODE'"
            Set-Location -Path $oldLocation
            finish $($exitcode+2)
        }
    } catch {
        writeLogMessage "ERROR`t Failed to compress '$dir'  with '$prog7z'. Last exit code is '$LASTEXITCODE'. $_"
        finish $($exitcode+2) 
    }
} # Function CompressDirectory

Function pg_create_basebackup () {

    param(
        [string] $computer = "localhost"
        ,[string] $user = "backup" 
        ,[string] $portNo = "5432"
        ,[string] $backupdir
        ,[string] $format = "p"
        ,[string] $walmethod = "stream"
        ,[int] $keepOldBackups
        ,[string] $prog7z
        ,[string] $checkpoint = "fast"
        ,[int] $exitcode
    )
    # Process input parameters
    if ($format -eq 't') {
        $gzipswitch = "--gzip"
    }

    try {
        # Query cluster running with given port
        $PgVersion = getPgMajorVersion -portNo $portNo -user $user
        # Set program directory for major version
        $script:PgBinDir="$PgProgDir\$pgVersion\bin"
        # Set correct data directory 
        $PgDataDir = "$PgDataDir\$pgVersion"
        # Set backup label
        $script:backuplabel = "pg_basebackup\${env:COMPUTERNAME}\pgVersion=$PgVersion\$PgDataDir\$timestamp"
        
        # Backup directories
        $backupdirHead = "$backupdir\${env:COMPUTERNAME}"
        $backupdirBase = "$backupdir\${env:COMPUTERNAME}\pg_basebackup_$timestamp\$PgVersion"
        # Create backup directory if not exist
        if (-Not (Test-Path -Path $backupdirBase -PathType Container -ErrorAction SilentlyContinue)) {
            New-Item -ItemType Directory -Force -Path $backupdirBase | Out-Null
        }
        # Directory name without pgVersion leaf directory
        $backupdirBaseParent = Split-Path -Path $backupdirBase -Parent

        writeLogMessage "INFO`t Executing pg_basebackup for cluster '$PgDataDir'"
        writeLogMessage "INFO`t pg_basebackup.exe -h $computer -U $user -p $portNo -w -v -D $backupdirBase $gzipswitch --wal-method=$walmethod --checkpoint=$checkpoint --progress --label=$script:backuplabel"
        $bb_proc = Start-Process -FilePath "$script:PgBinDir\pg_basebackup.exe" -ArgumentList "-h $computer -U $user -p $portNo -w -v -D $backupdirBase --format=$format $gzipswitch --wal-method=$walmethod --checkpoint=$checkpoint --progress --label=$script:backuplabel" -Wait -PassThru -NoNewWindow -RedirectStandardError "$backupdirBaseParent\stderr.txt" -RedirectStandardOutput "$backupdirBaseParent\stdout.txt"
    } catch {
        writeLogMessage "ERROR`t pg_basebackup process failed: $_"
    } finally {
        $stdout = Get-Content -Path "$backupdirBaseParent\stdout.txt"
        writeLogMessage "INFO`t Standard output:"
        foreach ($line in $stdout ) { 
            writeLogMessage "$line"
        }
        $stderr = Get-Content -Path "$backupdirBaseParent\stderr.txt"
        writeLogMessage "INFO`t Standard error:"
        foreach ($line in $stderr ) { 
            writeLogMessage "$line"
        }
        # Remove temporary log files again
        Remove-Item -Path "$backupdirBaseParent\stdout.txt" -Force
        Remove-Item -Path "$backupdirBaseParent\stderr.txt" -Force
    }

    if ($bb_proc.ExitCode -ne 0) {
        writeLogMessage "ERROR`t Exit code of pg_basebackup is '$($bb_proc.ExitCode)'. Check log file."
        writeLogMessage "INFO`t Removing failed backup '$backupdirBaseParent'"
        if (!(removeDirWaitTryAgain -dir $backupdirBaseParent)) {
            writeLogMessage "ERROR`t Failed to remove directory '$backupdirBaseParent'."
        }
        finish $exitcode
    } elseif ($bb_proc.ExitCode -eq 0) {
        CompressDirectory -prog7z $prog7z -dir $backupdirBaseParent -exitcode $($exitcode+1)
        writeLogMessage "SUCCESS`t pg_basebackup of '$PgDataDir'"
        deleteOldBackupFiles -backupdir $backupdirHead -keepOldFiles $keepOldBackups -filter "*.7z" -exitcode $($exitcode+2)
    } 

} # pg_create_basebackup

Function pg_cleanup_WAL_archive () {

    param(
        [string] $WALarchiveDir
        ,[int] $keepOldBackups
        ,[string] $prog7z
        ,[int] $exitcode 
    )

    # -1 on $keepOldBackups because we only need the WAL files between (!) the last $keepOldBackups (for e.g. 2) base backups
    $keepOldBackups = $keepOldBackups -1

    try {
        # Using $script:PgBinDir, $script:backuplabel from Function pg_create_basebackup
        writeLogMessage "INFO`t Executing pg_archivecleanup on archive directory '$WALarchiveDir'"
        writeLogMessage "INFO`t Backup label '$script:backuplabel'"

        # Get the .backup file in WAL archive directory with the correct $script:backuplabel
        Get-ChildItem -Path $WALarchiveDir -Include "*.backup" -Recurse | ForEach-Object {  If ((Get-Content $_.FullName) -match $script:backuplabel.Replace("\","\\")) { $cleanupFileFullName = $_.FullName } } 

        if (($cleanupFileFullName -eq '') -or ($null -eq $cleanupFileFullName)) {
            writeLogMessage "ERROR`t Failed to clean up WAL archive. No valid '.backup' file found in '$WALarchiveDir'"
            finish $exitcode
        }
        # Get file name only for pg_archivecleanup.exe
        $cleanupFile = Split-Path -Path $cleanupFileFullName -Leaf
    } catch {
        writeLogMessage "ERROR`t pg_archivecleanup process failed: $_"
        finish $exitcode
    }

    try {
        writeLogMessage "INFO`t $script:PgBinDir\pg_archivecleanup.exe -n $WALarchiveDir $cleanupFile"
        $ac_proc = Start-Process -FilePath "$script:PgBinDir\pg_archivecleanup.exe" -ArgumentList "-n $WALarchiveDir $cleanupFile" -Wait -PassThru -NoNewWindow -RedirectStandardError "$backupdir\stderr_ac.txt" -RedirectStandardOutput "$backupdir\stdout_ac.txt"

        # StandardOutput showing all WAL files that are included in the current base backup but needed for PITR with previous base backup
        $stdout = Get-Content -Path "$backupdir\stdout_ac.txt"
        writeLogMessage "INFO`t Standard output:"
        foreach ($line in $stdout ) { 
            writeLogMessage "INFO`t Moving '$line'"
        }
        $stderr = Get-Content -Path "$backupdir\stderr_ac.txt"
        writeLogMessage "INFO`t Standard error:"
        foreach ($line in $stderr ) { 
            writeLogMessage "$line"
        }
        # Remove temporary log files again
        Remove-Item -Path "$backupdir\stdout_ac.txt" -Force
        Remove-Item -Path "$backupdir\stderr_ac.txt" -Force

        if ($ac_proc.ExitCode -ne 0) {
            writeLogMessage "ERROR`t Exit code of pg_archivecleanup is '$($ac_proc.ExitCode)'. Check log file."
            finish $($exitcode+1)
        }

        # Move old archived WAL files from previous base backup to subdirectory
        # Create subdirectory if not exist
        if (-Not (Test-Path -Path "$WALarchiveDir\WAL_before_BaseBackup_$timestamp" -PathType Container -ErrorAction SilentlyContinue)) {
            New-Item -ItemType Directory -Force -Path "$WALarchiveDir\WAL_before_BaseBackup_$timestamp" | Out-Null
        }
        # Moving files 
        Move-Item -Path $stdout -Destination "$WALarchiveDir\WAL_before_BaseBackup_$timestamp" -Force
        # Compress old WAL files
        CompressDirectory -prog7z $prog7z -dir "$WALarchiveDir\WAL_before_BaseBackup_$timestamp" -exitcode $($exitcode+2)
        # Delete old subdirectories
        deleteOldBackupFiles -backupdir $WALarchiveDir -keepOldFiles $keepOldBackups -filter "WAL_before_BaseBackup_*.7z" -exitcode $($exitcode+3)

        writeLogMessage "SUCCESS`t pg_archivecleanup on archive directory '$WALarchiveDir'"
        # Delete old .backup files
        deleteOldBackupFiles -backupdir $WALarchiveDir -keepOldFiles $keepOldBackups -filter "*.backup" -exitcode $($exitcode+4)
    } catch {
        writeLogMessage "ERROR`t pg_archivecleanup process failed: $_"
    }
} # pg_cleanup_WAL_archive

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

# Check if 7z is available
if (-Not (Test-Path -Path $prog7z -ErrorAction SilentlyContinue)) {
    writeLogMessage "ERROR`t Failed to find mandatory program '$prog7z'"
    finish 1
}

# Create backup directory if not exist
if (-Not (Test-Path -Path $backupdir -PathType Container -ErrorAction SilentlyContinue)) {
    New-Item -ItemType Directory -Force -Path $backupdir | Out-Null
}
# Create new basebackups 
pg_create_basebackup -computer $server -user $backupuser -portNo $pgPort -backupdir $backupdir -format $format -walmethod $walmethod -checkpoint $checkpoint -keepOldBackups $keepOldBackups -prog7z $prog7z -exitcode 10

# Delete all old archived WAL files that are now obsolete with the basebackup
if ($CleanUpWALArchive) {
    pg_cleanup_WAL_archive -WALarchiveDir $WALarchiveDir -keepOldBackups $keepOldBackups -prog7z $prog7z -exitcode 20
}

finish 0
