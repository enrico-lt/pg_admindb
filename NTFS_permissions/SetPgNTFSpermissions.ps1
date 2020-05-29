<#
.SYNOPSIS
  Set NTFS permissions on PostgreSQL directories
.DESCRIPTION
  You can specify the covered directories in the CONFIGURATION PARAMETERS part.
  The rules are set in the MAIN part.
.NOTES
  Last editor:  Enrico La Torre
#>
################################################################################
############################## PROCESS PARAMETERS ##############################
################################################################################
param(
# use -WhatIf to show commands, but don't execute
[switch] $WhatIf
,$pgVersion = "12"
# Directory for log file
,$logpath = "E:\pg_admindb\logs\installation"
)
################################################################################
########################### CONFIGURATION PARAMETERS ###########################
################################################################################

$lastchange = "2020-05-29"

# create hash "paths" with one property per path 
$paths = @{}

$paths.progdir         = "C:\Program Files\PostgreSQL\$pgVersion"

$paths.pgdatdir        = "G:\databases\PostgreSQL\$pgVersion"

$paths.logdir          = "E:\pg_admindb\logs"

$paths.backupdir       = "E:\pg_admindb\Backup"
$paths.WALarchive      = "E:\pg_admindb\PostgreSQL-WAL-Archive"

$paths.scriptdir    = "E:\pg_admindb"

$paths.ODBCProgDir  = "C:\Program Files\psqlODBC" 
# Domain (FQDN)
$domainFQDN = (Get-WmiObject win32_computersystem).Domain
$domain = $domainFQDN.Split('.')[0]


# Create user and group variables
# Add all AD accounts to array for sanity check
$ADGroups = @()

$serviceAccount = "$domain\USER"
$ADGroups       +=  $serviceAccount.Split('\')[1]

$ADSyncTaskuser = $serviceaccount
$ADGroups       +=  $ADSyncTaskuser.Split('\')[1]

$backupUser = $serviceaccount
$ADGroups   +=  $backupUser.Split('\')[1]

$supportgroup       = "$domain\USERGROUP"
$ADGroups          +=  $supportgroup.Split('\')[1]

# User group which is superuser
$admin      = "DOMAIN\GROUP"
# Windows built-in user
$ntSystem          = "NT AUTHORITY\System"
$trustedInstaller  = "NT SERVICE\TrustedInstaller"
$Administrators    = "BUILTIN\Administrators"
$Users             = "BUILTIN\Users"

# Owner object for directories and files
$Owner = New-Object System.Security.Principal.NTAccount("BUILTIN\Administrators")

# PowerShell library for PostgreSQL
$libname = "E:\pg_admindb\lib\powershell_postgresql_lib.psd1"

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

Function CheckIfADObjectExists ([string[]] $ADObjects, [int] $exitcode) {

  foreach ($object in $ADObjects) {
    try {
      Get-ADGroup -Identity $object | Out-Null
    } catch {
      try {
        Get-ADUser -Identity $object | Out-Null
      } catch {
        writeLogMessage "ERROR`t AD object '$object' does not exist in your domain '$domain'!"
        finish $exitcode
      } # catch if user
    } # catch if group
  } # foreach
  writeLogMessage "INFO`t All AD groups and users checked"
} # Function CheckIfADObjectExists

Function newAccessRule () {
  # Create new access rule object and return it
  Param (
    [Parameter(Mandatory=$true)] [string[]] $argList
  )
  if ($argList.Contains("ListDirectory")) {
    $argList += "None"
  } else {
    $argList += "ContainerInherit, ObjectInherit"
  }
  $argList += "None"
  $argList += "Allow"
  return New-Object System.Security.AccessControl.FileSystemAccessRule -ArgumentList $argList
} # Function newAccessRule

Function SetACL () {
  # Set the $aclObject for the $path, unless script option -WhatIf is set.
  Param (
     [string] $path
    ,[System.Security.AccessControl.FileSystemSecurity] $aclObject
    ,[int] $exitcode
  )

  if ($script:WhatIf) { return }
  if (-Not(Test-Path $path)) {
    WriteLogMessage "WARNING`t '$path' does not exist." 
    return
  }

  try {
    Set-Acl -path $path -AclObject $aclObject -ErrorAction Stop 
  } catch {
    writeLogMessage "ERROR`t Could not set ACL permissions on path '$path' $_"
    writeLogMessage "INFO`t Resetting ACLS on path '$path' whith icacls.exe and trying to set again"
    # Reset the ACL
    $process = Start-Process -FilePath icacls -ArgumentList """$path"" /reset /T" -Wait -PassThru -NoNewWindow
    if ($process.ExitCode -ne 0) {
    writeLogMessage "ERROR`t The exit code from 'icacls' for path '$path' is '$($process.ExitCode)'. Therefore stop!"
    finish $exitcode
    }
    # Try to set the rules again
    try {
      Set-Acl -path $path -AclObject $aclObject -ErrorAction Stop
    } catch {
      writeLogMessage "ERROR`t Could not set ACL permissions on path '$path' again, after resetting with icacls.exe" 
      writeLogMessage "ERORR`t You are out of luck $_"
      finish $exitcode
    } # catch 2nd try
  }  # catch 1st try
} # Function SetACL

Function removeAuthenticatedUsersPermissions ([string[]] $pathList) {
  $user = "NT AUTHORITY\Authenticated Users"

  writeLogMessage "`nremoving wrong access rights from role '$user'."
  foreach ($path in $pathList) {
    $acl = (Get-Item $path).GetAccessControl('Access')
    foreach ($access in $acl.access) {
      foreach ($value in $access.IdentityReference.Value) {
        if ($value -eq $user) {
          writeLogMessage "  removing entry with '$($access.FileSystemRights)' for '$($access.IdentityReference.Value)' from '$path'"
          $acl.RemoveAccessRule($access) | Out-Null
        }
      }
    }
    Set-Acl -Path $path -AclObject $acl
  }
  writeLogMessage "removed wrong access rights from role '$user'."
} # Function removeAuthenticatedUsersPermissions


################################################################################
##################################### MAIN #####################################
################################################################################
$ErrorActionPreference = "Stop"

$me=whoami
writeLogMessage ""
writeLogMessage "START (script version dated $lastchange, run by $me )"
writeLogMessage "INFO`t Library Version $($lib.Version.Major).$($lib.Version.Minor), last change $($lib.PrivateData.lastchange)"
writeLogMessage "INFO`t Logfile will be written to $script:logfile"

if($WhatIf) {
  writeLogMessage ""
  writeLogMessage "INFO`t -WhatIf is true"
  writeLogMessage ""
}
writeLogMessage "INFO`t Checking existence of AD groups..."
CheckIfADObjectExists -ADObjects $ADGroups -exitcode 1

# Rules for program directory
$rule_prog = @()
$rule_prog += NewAccessRule @($ntSystem, "FullControl")
$rule_prog += NewAccessRule @($admin, "FullControl")
$rule_prog += NewAccessRule @($backupUser, "FullControl")
$rule_prog += NewAccessRule @($serviceAccount, "FullControl")

$grouplist = @($supportgroup)
foreach ($group in $groupList) {
  #$rule_prog += NewAccessRule @($group, "ListDirectory")
  $rule_prog += NewAccessRule @($group, "ReadAndExecute")
}

# Rules for data directory
$rule_data = $rule_prog

# Rules for backup and WAL archive directory
$rule_backup = @()
$rule_backup += NewAccessRule @($ntSystem, "FullControl")
$rule_backup += NewAccessRule @($admin, "FullControl")
$rule_backup += NewAccessRule @($backupUser, "Modify")
$rule_backup += NewAccessRule @($serviceAccount, "Modify")
foreach ($group in $groupList) {
  $rule_backup += NewAccessRule @($group, "ReadAndExecute")
}

# Rules for log directory
$rule_log = @()
$rule_log += NewAccessRule @($ntSystem, "FullControl")
$rule_log += NewAccessRule @($admin, "FullControl")
$rule_log += NewAccessRule @($ADSyncTaskuser, "Modify")
$rule_log += NewAccessRule @($serviceAccount, "Modify")
foreach ($group in $groupList) {
  $rule_log += NewAccessRule @($group, "ReadAndExecute")
}

# Rules for script directory
$rule_script = @()
$rule_script += NewAccessRule @($ntSystem, "FullControl")
$rule_script += NewAccessRule @($admin, "FullControl")
$rule_script += NewAccessRule @($ADSyncTaskuser, "ReadAndExecute")
$rule_script += NewAccessRule @($serviceAccount, "ReadAndExecute")
foreach ($group in $groupList) {
  $rule_script += NewAccessRule @($group, "ReadAndExecute")
}

# Rules for ODBC program directory
$rule_odbc = @()
$rule_odbc += NewAccessRule @($ntSystem, "FullControl")
$rule_odbc += NewAccessRule @($admin, "FullControl")
$rule_odbc += NewAccessRule @($ADSyncTaskuser, "ReadAndExecute")
$rule_odbc += NewAccessRule @($serviceAccount, "ReadAndExecute")
foreach ($group in $groupList) {
  $rule_odbc += NewAccessRule @($group, "ReadAndExecute")
}


$acl=@{}
writeLogMessage "INFO`t Applying NTFS rules"
foreach ($d in $paths.GetEnumerator()) {

  $prop = $($d.Name) # Name of hash map element
  $dir = $($d.Value) # Real path
  $acl.$prop = New-Object -TypeName System.Security.AccessControl.DirectorySecurity

  # All directories and files should inherit from parent directory
  $acl.$prop.SetAccessRuleProtection($false, $false)
  $acl.$prop.SetOwner($Owner)

  # Rule set for data directory 
  if ($d.Name -eq "pgdatdir") { 
    # Directory should not inherit from parent directory
    $acl.$prop.SetAccessRuleProtection($true, $false) 
    $rule_set = $rule_data
  }
  # Rule set for program directory 
  if ($d.Name -eq "progdir") {
    # Directory should not inherit from parent directory
    $acl.$prop.SetAccessRuleProtection($true, $false)
    $rule_set = $rule_prog
  }
  # Rule set for backup and WAL archive directory
  if ($d.Name -in ("backupdir","WALarchive")) {
    $rule_set = $rule_backup
  } 
  # Rule set for log directory 
  if ($d.Name -eq "logdir") {
    $rule_set = $rule_log
  }
  # Rule set for script directory
  if ($d.Name -eq "scriptdir") {
    $rule_set = $rule_script
  }
  # Rule set for ODBC program directory
  if ($d.Name -eq "ODBCProgDir") {
    $rule_set = $rule_odbc
  }

  writeLogMessage "`t Path: $dir, Owner: $($acl.$prop.Owner)"
  try {
    foreach ($r in $rule_set) {
      writeLogMessage "INFO`t $($r.IdentityReference): $($r.FileSystemRights)"
      $acl.$prop.AddAccessRule($r)
    }
    setACL -path $dir -aclObject $acl.$prop -exitcode 2
  } catch {
    writeLogMessage "ERROR`t Error applying general rule: $_"
    finish 3 
  }

} # foreach path in paths

writeLogMessage "SUCCESS`t All NTFS permissions have been set successfully."

finish 0