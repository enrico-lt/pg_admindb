# pg_admindb
The script set pg_admindb let's you deploy a PostgreSQL cluster on Windows Server easily and fast with PowerShell

# Features
- Script guided installation of PostgreSQL 12 and ODBC drive
- pg_admindb as template database with many views to help with adminsitration
- NTFS permissions set on all PostgrSQL related directories
- Synchronize PostgreSQL roles with Active Directory Groups
- Schedueld Backups with pg_dump
- Scheduled maintenance task inspired by the maintenance solution for SQL Server by Ola Hallengren
- Scheduled integrity check of PostgreSQL cluster after an unexpected shutdown
- Scheduled management of log files

# Installation

Copy all files in a directory of you server.
Modify all parametes in the 'Configuration Parameters' section of each script.

If you really want to use this in your environment contact me and I can give you all the details you need to look at.

# Requirements

Windos Server 2016 or up
Commuinity Windows Installer for PostgreSQL 12 from EnterpriseDB
