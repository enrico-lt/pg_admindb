<#
.SYNOPSIS
  PowerShell Script for Synchronising User Roles from AD to PostgreSQL      
.DESCRIPTION
  The tool scans all AD groups that are mentioned in the configuration file.
  It then compares the list of AD users and AD groups with a list of current
  existent roles in PostgreSQL. It then updates the list of roles in PostgreSQL
  that both lists match.

  Test(Live) groups in the config file will not be scanned in a live(test)
  environment. This means that these groups are not part of the list with AD 
  users and groups. If they still exist in PostgreSQL they will be dropped in 
  order to match the PostgrSQL role and AD users list.
.NOTES
  Date:			    2017-08-14
	Last editor:	Enrico La Torre
#>

################################################################################
########################### CONFIGURATION PARAMETERS ###########################
################################################################################

$lastchange = "2020-05-29"

# Domain (FQDN)
$domainFQDN = (Get-WmiObject win32_computersystem).Domain
$domain = $domainFQDN.Split('.')[0]

# Get config and replace placeholders with location parameters
$configText = Get-Content("$PSScriptRoot\pg_ad_sync_config.xml")
[System.XML.XMLDocument] $config = $configText

# PowerShell library for PostgreSQL
$libname =  $config.settings.lib

# Import PostgreSQL Powershell library
try {
  Import-Module -Name $libname -Force
  $lib = Get-Module -ListAvailable $libname
} catch {
  Throw "ERROR`t Cannot import powershell library '$libname'"
}

# Set log file name
$Logpath = $config.settings.logpath
if(-Not (Test-Path -Path $Logpath)) {New-Item -ItemType Directory -Force -Path $Logpath | Out-Null}
$script:logfile = ''
$scriptName = $MyInvocation.MyCommand.Name
$scriptName = $scriptName -replace '.ps1',''
$scriptName += "-log_{timestamp}.log"
$script:logfile="$Logpath\$scriptname"
setLogFileName -logfile $script:logfile

# Read config file information
$database = $config.settings.database.name
$servername = $config.settings.database.server.host
$pgPort = $config.settings.database.server.port
$username = $config.settings.database.username

#################################################################################
################################### FUNCTIONS ###################################
#################################################################################

# Get domain from distinguished name of an object
Function getDomainFromDN ([Parameter(Mandatory=$true)] [string] $dn) {
  $match = [regex]::Match($dn, ',DC=(.*),DC=(.*)$').captures
  $match.groups[1].value + "." + $match.groups[2].value
} # getDomainFromDN


# Get common name from distinguished name of an object
Function getCNFromDN ([Parameter(Mandatory=$true)] [string] $dn) {
  $match = [regex]::Match($dn, '^CN=(.*?),OU=').captures
  $match.groups[1].value
} # getCNFromDN

# Get list of PostgreSQL roles to ignore - don't delete or update those
Function getRolesToIgnore ([Parameter(Mandatory=$true)] [System.XML.XMLDocument] $config) { 
  
  # Also the groups from the ad/filter node must be added here. Otherwise they would be
  # revoked from db_datareader etc. in the update step.

  foreach ($ir in $groupsToScan) {
    writeLogMessage "INFO`t Group to synchronise: $ir"
    $script:ignore_roles += getCNFromDN -dn $ir
  } 
 
  # groups explicitly named in ignore list
  foreach ($ir in ($config.SelectNodes('//database/ignoredRoles/role/@name'))) {
    writeLogMessage ("INFO`t group to ignore: " + $ir.'#text')
    $script:ignore_roles += $ir.'#text'
  } # foreach
} # getRolesToIgnore

# Get roles including memberships in other roles from database.
# Result is an array of dictionaries consisting of the following fields:
#  String   rolename    name of this role
#  Boolean  canlogin    whether this role can login
#  String[] memberof    roles where this role is member of
Function getPgRoles($conn) {
  $pg_roles = @()
  $query = "
  SELECT r.rolname, 
    r.rolcanlogin,
    '<memberof>'||
    COALESCE ((SELECT xmlagg(('<role>'||b.rolname||'</role>')::xml)
        FROM pg_catalog.pg_auth_members m
        JOIN pg_catalog.pg_roles b ON (m.roleid = b.oid)
        WHERE m.member = r.oid), '') ||
    '</memberof>'
    AS memberof,
    pg_catalog.shobj_description(r.oid, 'pg_authid') AS description
  FROM pg_catalog.pg_roles r
  WHERE r.rolname !~ '^pg_'
  ORDER BY 1;
  "
  $recordsetODBC = queryOdbcConnection -conn $connODBC -query $query
  [System.XML.XMLDocument] $xml = New-Object System.XML.XMLDocument

  try {
    foreach ($row in $recordsetODBC.Tables[0]){
      $xml.LoadXml($row.memberof)
      [string[]] $memberof = $xml.memberof.ChildNodes.innerText
      $role=@{"rolename"=$row.rolname; "description"=$row.description; "canlogin"=($($row.rolcanlogin) -eq 1); "memberof"=$memberof}
      $pg_roles += $role
    }
    return $pg_roles
  } 
  catch {
    writeLogMessage "ERROR`t getPgRoles: $_"
  } 
} # getPgRoles


# Get roles including memberships in groups from Active Directory.
# Scans group and returns list of user members
# Updates script variables:
#    adds all groups found in group to $script:groupsToScan
#    adds/updates users found in group to $script:ad_roles
#    adds $groupDN to variable $script:groupsScanned
# Login names used are samAccountName, maybe it's better to change this to
# UserPrincipalName, if they ever differ.
Function scanGroups ([string] $ADDomainController, [int] $exitcode) {

  while ($script:groupsToScan.count -ne 0) {
  
    $groupDN = $script:groupsToScan[0]

    $membersDN = @()
    writeLogMessage "INFO`t AD Group > $groupDN < "

    try {
      $membersDN = (Get-ADGroup -Identity $groupDN -server $ADDomainController -Properties members).members
    } catch {
      writeLogMessage "INFO`t Group $groupDB can not be scanned"
      finish $($exitcode)
    } 

    # check whether members are groups or users  
    $noOfUsers = 0
    $groupName = getCNFromDN $groupDN
    foreach ($member in $membersDN) {
      writeLogMessage "INFO`t member: '$member'" 
      try {
        $adUser = Get-ADUser -Identity $member -Server $ADDomainController -ErrorAction SilentlyContinue
        $noOfUsers = $noOfUsers + 1
        $samAccountName = $adUser.SamAccountName.ToLower()
        $i = (0..($script:ad_roles.Count-1)) | Where-Object {$script:ad_roles[$_].rolename -eq $samAccountName}
        if ([string]::IsNullOrEmpty($i)) {
          # new role
          $script:ad_roles += @{"rolename"=$samAccountName; "description"=$adUser.name; "canlogin"=$true; memberof=@($groupName)} 
        } else {
          # role already exists, add membership
          $script:ad_roles[$i].memberof+="$groupName"
        } # if
      } catch {
        # check whether member is a group
        try {
          $adGroup = Get-ADGroup -Identity $member -Server $ADDomainController -ErrorAction SilentlyContinue
          writeLogMessage "INFO`t GROUP found: >$adGroup<"
          # If group hasn't been scanned, check whether to add to $groupsToScan
          if (-not ($script:groupsScanned -contains $adGroup)) {
            # If group is not in list of groups to scan, add it
            if (-not ($script:groupsToScan -contains $adGroup)) {
              writeLogMessage "INFO`t Adding group to be scanned >$adGroup<"
              $script:groupsToScan.Add($adGroup.distinguishedName) | Out-Null
            }
          }
          # check whether we already know the group, if not, add to list of AD roles
          $samAccountName = $adGroup.SamAccountName
          $i = (0..($script:ad_roles.Count-1)) | Where-Object {$script:ad_roles[$_].rolename -eq $samAccountName}
          if ([string]::IsNullOrEmpty($i)) {
            $shortDN=($adGroup.distinguishedName -replace "CN=$samAccountName,OU=", "")
            $shortDN=($shortDN -replace ",OU=(.*),DC=$domain.*", ', $1')
            $script:ad_roles += @{
              "rolename"=$samAccountName; 
              "description"=$shortDN;
              "canlogin"=$false; 
              "memberof"=@($groupName)}
          } # if
        } catch {
          # this member is neither a user nor a group, will be ignored
          writeLogMessage "ERROR`t Neither user nor group: >$member<"
          finish $($exitcode+1)
        }
      } # catch 
    } # foreach member

    # Add group itself to the list of ad_roles if not already in list
    try{
      $ScannedGroup = Get-ADGroup -Identity $groupDN -Server $ADDomainController -ErrorAction SilentlyContinue
      $samAccountName = $ScannedGroup.SamAccountName
      $i = (0..($script:ad_roles.Count-1)) | Where-Object {$script:ad_roles[$_].rolename -eq $samAccountName}
      if ([string]::IsNullOrEmpty($i)) {
        $shortDN=($adGroup.distinguishedName -replace "CN=$samAccountName,OU=", "")
        $shortDN=($shortDN -replace ",OU=(.*),DC=$domain.*", ', $1')
        $script:ad_roles += @{
          "rolename"=$samAccountName; 
          "description"=$shortDN;
          "canlogin"=$false; 
          "memberof"=@()} # can not be member of itself
      }
    } catch {
      writeLogMessage "ERROR`t $_"
      finish $($exitcode+2)
    }

    writeLogMessage "INFO`t Group >$groupDN< has been scanned, no of users: $noOfUsers"
    $script:groupsScanned.Add($groupDN) | Out-Null
    $script:groupsToScan.Remove($groupDN) | Out-Null
    writeLogMessage ''
  } # while
} # scanGroups


# Searches AD for NIT Admin Groups
# The DN looks something like this:
# CN=Common Name,OU=Organisational Unit,OU=Organisational Unit,DC=DOMAIN,DC=loc
Function getDNfromCN ([string] $groupName, [string] $domainFQDN, [string] $ADDomainController, [int] $exitcode) {

  try {
    $groupDN = (Get-ADGroup -Identity $groupName -server $ADDomainController).DistinguishedName
    return $groupDN
  } catch {
    writeLogMessage ("Administrative Group '" + $groupName + "' not found. $_")
    finish $exitcode
  } 
} # getDNfromCN


# Update PostgreSQL roles from Active Directory roles.
#   * create roles not yet in PostgreSQL including memberships
#   * drop roles no longer in Active Directory
#   * update memberships for roles existing in PostgreSQL and Active Directory
#      - grant memberships not yet granted
#      - revoke memberships no longer granted
#      - enable login when Active Directory user
#      - disable login when Active Directory group
# Returns necessary SQL commands as an array of strings.
# $ad_roles have the same structure as $pg_roles. Active Directory users are represented
# as roles with canlogin=true, while groups are represented as roles with canlogin=false.
# IMPORTANT: New Active Directory group roles must appear before other roles being granted the new group role!
Function updatePgRolesFromAdRoles {
  param (
    [Parameter (Mandatory=$true)] $pg_roles, 
    [Parameter (Mandatory=$true)] $ad_roles,
    [Parameter (Mandatory=$true)] $ignore_roles
  ) 
 
  $script:numbers = @{"create" = 0; "drop" = 0; "alter" = 0; "grant" = 0; "revoke" = 0}
 
  $ad_rolenames = $ad_roles.rolename
  $pg_rolenames = $pg_roles.rolename
  
  $commands = @()        # return value: array with all commands to be invoked 
  $createCommands = @()  # create commands, have to be executed first to make sure all objecst exist
  $otherCommands = @()   # other commands (grant, comment), executed later

  <#
    Create commands are always execute before any grant command. The IF EXISTS before the GRANT 
    should not be necessary.
  #>
  
  # Create roles not yet in PostgreSQL including memberships
  foreach ($createRole in ($ad_rolenames | Where-Object {-not ($pg_rolenames -contains $_)})) {
    $currentAdRole = ($ad_roles | Where-Object {$_.rolename -eq $createRole})
    $cmd = 'CREATE ROLE "' + $createRole + '" '
    if ($currentAdRole.canlogin -eq $False) {
      $cmd += 'NO';
    }
    $cmd += 'LOGIN;'
    writeLogMessage "INFO`t SQL: $cmd"
    $createCommands += $cmd; # CREATE ROLE command
    $cmd = 'COMMENT ON ROLE "' + $createRole + '" IS ' + "'" + $currentAdRole.description + "';"
    $createCommands += $cmd; # COMMENT ON command (real name)
    $script:numbers.create++
    
    # Only if current AD role has members
    if (-not ([string]::IsNullOrEmpty($($currentAdRole.memberof)))) {
      foreach($currentADRolemember in $currentAdRole.memberof) {
        $cmd = 'DO
          $do$
          BEGIN
            IF EXISTS (
                SELECT                
                FROM   pg_catalog.pg_roles
                WHERE  rolname = '''+$currentADRolemember+''') THEN
                GRANT "'+$currentADRolemember+'" TO "'+ $createRole + '";
            END IF;
          END
          $do$;'
      writeLogMessage "INFO`t SQL: GRANT IF EXISTS ""$currentADRolemember"" TO ""$createRole"";"
      $otherCommands += $cmd; # GRANT command for memberships
      $script:numbers.grant++
      } # foreach currentADRolemember
    } # if not empty
  } # foreach create
  
  # Update memberships and (no)login for roles existing in PostgreSQL and Active Directory
  foreach ($checkRole in $ad_rolenames | Where-Object {$pg_rolenames -contains $_}) {
    if ($ignore_roles -contains $checkRole) { continue }
    $currentAdRole = ($ad_roles | Where-Object {$_.rolename -eq $checkRole})
    $currentPgRole = ($pg_roles | Where-Object {$_.rolename -eq $checkRole})
    
    # Get current memberships
    $adMemberships = $currentAdRole.memberof
    $pgMemberships = $currentPgRole.memberof
    
    # Grant new memberships
    $grantMemberships  = $adMemberships | Where-Object {-not ($pgMemberships -contains $_)}
    # remove itself - can not grant group to itself
    $grantMemberships  = $grantMemberships | Where-Object {$_ -ne $currentPgRole.rolename}
    if ($grantMemberships) {
      foreach ($gm in $grantMemberships) {
        $cmd = 'DO
          $do$
          BEGIN
            IF EXISTS (
                SELECT                
                FROM   pg_catalog.pg_roles
                WHERE  rolname = '''+$gm+''') THEN
                GRANT "'+$gm+'" TO "'+ $checkRole + '";
            END IF;
          END
          $do$;'
        writeLogMessage "INFO`t SQL: GRANT IF EXISTS ""$gm"" TO ""$checkRole"";"
        $otherCommands += $cmd;
        $script:numbers.grant++
      }
    }
    
    # Revoke obsolete memberships
    $revokeMemberships = $pgMemberships | Where-Object {-not ($adMemberships -contains $_)}
    # remove itself - can not revoke group from itself
    $revokeMemberships  = $revokeMemberships | Where-Object {$_ -ne $currentPgRole.rolename}
    if ($revokeMemberships) {
      foreach ($rm in $revokeMemberships) {
        $cmd = 'DO
          $do$
          BEGIN
            IF EXISTS (
                SELECT                
                FROM   pg_catalog.pg_roles
                WHERE  rolname = '''+$rm+''') THEN
                REVOKE "'+$rm+'" FROM "'+ $checkRole + '";
            END IF;
          END
          $do$;'
          writeLogMessage "INFO`t SQL: REVOKE IF EXISTS ""$rm"" FROM ""$checkRole"";"
        $otherCommands += $cmd;
        $script:numbers.revoke++
      }
    }

    # Set LOGIN or NOLOGIN for role if not current (will hardly happen)
    $adCanlogin = $currentAdRole.canlogin
    $pgCanlogin = $currentPgRole.canlogin
    if ($adCanlogin -ne $pgCanlogin) {
      $cmd = 'ALTER ROLE "' + $checkRole + '" '
      if ($currentAdRole.canlogin -eq $false) { $cmd += 'NO' }
      $cmd += 'LOGIN;'
      writeLogMessage "INFO`t SQL: $cmd"
      $otherCommands += $cmd
      $numbers.alter++
    }
  } # foreach update

  # Drop roles no longer in Active Directory
  foreach ($dropRole in ($pg_rolenames | Where-Object {-not ($ad_rolenames -contains $_)})) {
    if ($ignore_roles -contains $dropRole) { continue }
    $cmd = 'DROP OWNED BY "' + $dropRole + '";'
    $otherCommands += $cmd; # DROP OWNED BY command
    $cmd = 'DROP ROLE "' + $dropRole + '";'
    writeLogMessage "INFO`t SQL: $cmd"
    $otherCommands += $cmd; # DROP ROLE command
    $script:numbers.drop++
  } # foreach drop
  
  $commands = $createCommands + $otherCommands
  return $commands
} # updatePgRolesFromAdRoles


################################################################################
##################################### MAIN #####################################
################################################################################
$ErrorActionPreference = "Stop"

# Numbers about how many roles are modified
#$numbers = @{"create" = 0; "drop" = 0; "alter" = 0; "grant" = 0; "revoke" = 0}

$me=whoami
writeLogMessage ""
writeLogMessage "START (script version dated $lastchange, run by $me )"
writeLogMessage "INFO`t Library Version $($lib.Version.Major).$($lib.Version.Minor), last change $($lib.PrivateData.lastchange)"
writeLogMessage "INFO`t Logfile will be written to $script:logfile"
  
# Get the DC
try{
  $ADDomainController = (Get-ADDomainController -Discover -Domain $domainFQDN).name + ':3268'
  writeLogMessage "INFO`t Contacting ADDomainController '$ADDomainController'"
} catch {
  writeLogMessage "ERROR`t Can not contact a Domain Controller: $_"
  finish 1
}

################################################################################

# These ArrayLists contain distinguished names of groups to be scanned and those already scanned
$groupsScanned = New-Object System.Collections.ArrayList
$groupsToScan  = New-Object System.Collections.ArrayList

$dngroups = ($config.settings.ad.filter.ChildNodes | Where-Object {$_.LocalName -eq "group"}).dn
# Remove test groups if live
if(-Not $testenvironment) {
  $dngroups = $dngroups | Where-Object {$_ -notmatch ".*TEST.*"}
} 
foreach ($group in $dngroups) {
  if ($group -ne "") {
    # Remove live groups if test
    if($testenvironment){
      $groupCN = getCNFromDN -dn $group
      # Is there in the set of dngroups a group that has the same name but TEST at the end?
      if ($dngroups -match "$groupCN.*TEST.*") {
        continue
      } 
    }
    $groupsToScan.Add($group) | Out-Null
  }
}

# Search for distinguished names of Groups with common names from the config file in AD and add them to groups to be scanned
$cngroups = ($config.settings.ad.filter.ChildNodes | Where-Object {$_.LocalName -eq "cngroup"}).cn
# Remove test groups if live
if(-Not $testenvironment) {
  $cngroups = $cngroups | Where-Object {$_ -notmatch "TEST"}
}
foreach ($cn in $cngroups) {
  $groupDN = getDNfromCN -groupName $cn -domainFQDN $domainFQDN -ADDomainController $ADDomainController -exitcode 2
  if ($groupDN -ne "") {
    # Remove live groups if test
    if($testenvironment){
      # Is there in the set of cngroups a group that has the same name but TEST at the end?
      if ($cngroups -match "$cn.*TEST.*") {
        continue
      } 
    }
    $groupsToScan.Add($groupDN) | Out-Null
  }
}
writeLogMessage ("INFO`t Initially there are " + $groupsToScan.count + " groups to be scanned.")

################################################################################

# Get roles from config that don't need to be updated
$script:ignore_roles = @()
getRolesToIgnore -config $config
writeLogMessage "INFO`t No of IGNORED ROLES: $($ignore_roles.count)"

# Connect to PostgreSQL database
$connODBC = openOdbcConnection -dbServer $servername -dbName $database -portNo $pgPort -userName $username

writeLogMessage "INFO`t Conntected to database:"
$recordsetODBC = queryOdbcConnection -conn $connODBC -query "SELECT current_database(), current_user"
foreach ($item in $recordsetODBC.Tables[0]){
  writeLogMessage "INFO`t database: $($item.current_database)`t user: $($item.current_user)"
}

# Get current roles from PostgreSQL
$pg_roles = getPgRoles -conn $connODBC
writeLogMessage ("INFO`t No of PG ROLES: " + $pg_roles.count)

# Get current roles from ActiveDirectory
WriteLogMessage "INFO`t Getting AD roles - this may take some time ..."
# This Array contains all users with group memberships
$script:ad_roles = @()
scanGroups -ADDomainController $ADDomainController -exitcode 3
writeLogMessage ("INFO`t No of AD ROLES: " + $ad_roles.count)
writeLogMessage ''

# Remove live groups if test and test groups if live
if($testenvironment){
  # Remove live groups that have a test sibling
  $filteredOut = $ad_roles | Where-Object { ($ad_roles.rolename -match "$($_.rolename)") -and ($ad_roles.rolename -match "$($_.rolename).*TEST.*") }
  if($filteredOut) {
    writeLogMessage "INFO`t Since testenvironment is '$testenvironment' the following groups are not synchronized:"
    foreach ($fo in $filteredOut.rolename ) {
      writeLogMessage "INFO`t $fo"
    } # foreach
  }
  # The inner expression returns all groups that have sibling with .*TEST.* at the end. The -Not operator returns the opposite.
  $ad_roles = $ad_roles | Where-Object { -Not ( ($ad_roles.rolename -match "$($_.rolename)") -and ($ad_roles.rolename -match "$($_.rolename).*TEST.*") ) }
} else {
  # Remove test groups
  $filteredOut = $ad_roles | Where-Object { $_.rolename -match ".*TEST.*" }
  if($filteredOut) {
    writeLogMessage "INFO`t Since testenvironment is '$testenvironment' the following groups are not synchronized:"
    foreach ($fo in $filteredOut.rolename ) {
      writeLogMessage "INFO`t $fo"
    } # foreach
  } 
  $ad_roles = $ad_roles | Where-Object { $_.rolename -notmatch ".*TEST.*" }
}

# Sanity check
if ($ad_roles.count -eq 0) {
  writeLogMessage "No AD roles found"
  finish 4
}
if ($pg_roles -eq 0) {
  writeLogMessage "No PostgreSQL roles found"
  finish 5
}
    
writeLogMessage ''
writeLogMessage "INFO`t UPDATE PG ROLES FROM AD..." 
$cmds = updatePgRolesFromAdRoles -pg_roles $pg_roles -ad_roles $ad_roles -ignore_roles $ignore_roles

foreach ($cmd in $cmds) {
  queryOdbcConnection -conn $connODBC -query $cmd | Out-Null
}

# Write summary of SQL commands to log file if switch is set
$msg = "INFO`t "
$numbers.keys | ForEach-Object {
  $msg += ($_ + ": " + $numbers[$_] + "`t")
}
writeLogMessage $msg

$connODBC.close()

finish 0