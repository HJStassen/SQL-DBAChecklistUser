# SQL-DBAChecklistUser
SQL server checks on users

Some SQL checks of mine (wrapped together in a stored procedure) to do various SQL Server user security and consistency checks:
<ul>
  <li>Elevated server rights(AD or server group, SQL User, SQL Login)</li>
  <li>Elevated Database rights(AD or server group, SQL User, SQL Login)</li>
  <li>Database Ownership not sa</li>
  <li>Server connection access but no database cccess(AD or server group, SQL User, SQL Login)</li>
  <li>Database access without server connection access(AD or server group, SQL User, SQL Login)</li>
  <li>Different SID on server and database(SQL Login)</li>
  <li>None-native domain access (AD or server group, SQL User)</li>
  <li>Check back to AD if exists ((AD or server group, SQL User)</li>
  <li>for information - accounts the various services runs under. </li>
<ul>
  <p> 
   The project started off many years ago at home when I was trying to resolve user inconsistencies between SQL database access. Every time as i hit a snag at home, or work, I would edit it. One day I hit the sp_blitz routimes of Bbrent Ozar, I realised that it might be a nice format to display the results. this is definitely a work in progress - I only work on it when i have to resolve an issue. Nothing fancy, it just works for me. Maybe it will work for you. If there is a need for it, I will amend the documentation. If you are half a DBA, like me, the stuff will make sense anyway. 
  </p>
  <p>
    Some of the issues I faced in the past are multiple domain migrations and multiple SQL server platform migration, many of those on inherited databases that existed prior to SQL server 2000. and it was on multiple SQL server instances. </p>
  <p>
    I have capped it at SQL 2000, and you will need to exclude some stuff for it to work on SQL2000. I dont have a SQL 2000 instance at home anymore, so if you want it to work on SQL server 2000, just exclude the valid AD account checks, and the registry checks. 
    </p>
  <p>
    I have leaped and jumped in the past, sometimes locking me out of SQL. (removing builtin\administrators from sysadmin, oops) Take care and review the suggested scripts before you run them. This is in the realm of stuff where you cannot take a proper backup - err on the dise of caution. Save the results to an excel sheet if you have to 
    </p>
