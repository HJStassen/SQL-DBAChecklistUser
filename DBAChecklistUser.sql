
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF (OBJECT_ID('dbo.sp_DbaChecklistUser') IS NULL) EXEC('CREATE PROCEDURE dbo.sp_DbaChecklistUser AS SELECT 1')
GO

ALTER procedure [dbo].[sp_DbaChecklistUser]
(   --
    @OutputType VARCHAR(20) = 'TABLE' ,
    @SkipChecksServer NVARCHAR(256) = NULL ,
    @SkipChecksDatabase NVARCHAR(256) = NULL ,
    @SkipChecksSchema NVARCHAR(256) = NULL ,
    @SkipChecksTable VARCHAR(256) = NULL ,
    @ReportOnOwnership INT = 0,
    @IgnorePrioritiesBelow INT = NULL ,
    @IgnorePrioritiesAbove INT = NULL ,
    @Help TINYINT = 0 ,
    @Version INT = NULL OUTPUT,
    @VersionRevision INT = NULL OUTPUT,
    @VersionDate     DATETIME = NULL OUTPUT,
    @NativeDomain    nvarchar(128)=NULL, 
    --@HelpUrl       NVARCHAR(128)= 'file:///C:/Dev/DBAChecklistUser/DBAChecklistUser.html#'
    @HelpUrl         NVARCHAR(128)= 'http://localhost/DBAChecklistUser/DBAChecklistUser.html#'
)
 
as
BEGIN
/*  HJ Stassen stass@nerina.co.za
    0.5 changes from 0.4 
    made provision for case sensititive SQL installations
    Check for AD users, removed checks on built in users

    0.6 changes from 0.5   
    fix on login users on sql 2000, where the Security_entity = ''

    0.7 Changes from 0.6 - 11 November 2020
    Split between SQL Login and SQL user(ad account) and ad group

    0.8 Changes from 0.7 - 27 June 2021
    various small changes, and adding the urls for the initial support page
*/

/*  enhancements to do
    Write articles on background of checks, and add to the html document
    Report on objects owned by specific login, and provide scripts to remove access
    disable logins/users, check ownership, remove if owned
    check any deviations from "standard" public role. 
    maybe fix backward compatibility on AD account check on SQL 2000
    change cursors where possible to spforeachdatabase
    Check newer SQL, Azure and linux versions
*/

/* 
--Generic Call 
-- Just execute it, no need to add parameters
exec sp_DbaChecklistUser  

--Check for previous Domain logins(after domain migrations) - replace the YOURDOMAIN with your current domain
exec sp_DbaChecklistUser 
    @NativeDomain='YOURDOMAIN'

--Only report on Priority 20 errors
exec sp_DbaChecklistUser 
    @IgnorePrioritiesBelow = 20, 
    @IgnorePrioritiesAbove = 20 

*/

    SET NOCOUNT ON;
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
    SELECT @Version = 0, @VersionRevision = 8, @VersionDate = '20210627'
    DECLARE @ServerName NVARCHAR (50)
    SET @ServerName = @@Servername +'\'
    SET @ServerName = SUBSTRING(@ServerName, 1, PATINDEX('%\%', @ServerName) -1)
 
    IF @Help = 1 
        BEGIN 
        PRINT '
    /*
    sp_DbaChecklistUser v0.8 - 27 June 2021
    */'
        END
    ELSE  /*IF @Help = 1 */
        BEGIN
        IF @OutputType = 'SCHEMA'
            BEGIN
            SELECT @Version AS Version,
            FieldList = 'tbc'

            END
        ELSE /* IF @OutputType = 'SCHEMA' */
            BEGIN        
            /*
            We start by creating #DBACLUserResults.
            */
            declare @DBName varchar(200)
            declare @StringToExecute1  nvarchar(4000)
            declare @StringToExecute2  nvarchar(4000)

            set @IgnorePrioritiesBelow = isnull(@IgnorePrioritiesBelow, 0)
            set @IgnorePrioritiesAbove = isnull(@IgnorePrioritiesAbove , 255)
            SET @ReportOnOwnership = ISNULL (@ReportOnOwnership,0)

            IF OBJECT_ID('tempdb..#DBACLUserResults') IS NOT NULL
                DROP TABLE #DBACLUserResults;
            CREATE TABLE #DBACLUserResults
                (
                    ID INT IDENTITY(1, 1) ,
                    CheckID INT ,
                    ServerName NVARCHAR(128) ,
                    DatabaseName NVARCHAR(128) ,
                    UserName NVARCHAR(128) ,
                    Priority TINYINT ,
                    FindingsGroup VARCHAR(50) ,
                    Finding VARCHAR(200) ,
                    URL VARCHAR(200) ,
                    Details NVARCHAR(4000) , 
                    Script1 NVARCHAR(4000) ,
                    Script2 NVARCHAR(4000) 
                  )
            IF OBJECT_ID('tempdb..#DBACLSrvrUsers') IS NOT NULL
                DROP TABLE #DBACLSrvrUsers;
            CREATE TABLE #DBACLSrvrUsers
                ( 
                    [UserSID] [varbinary](85),
                    [UserName] NVARCHAR(128),
                    [UserType] [nvarchar](60),
                    [SecurityEntity] [nvarchar](128),
                    [SecurityType] [varchar](15),
                    [StateDesc] [nvarchar](60)
                )          
                        
            IF OBJECT_ID('tempdb..#DBACLDBUsers') IS NOT NULL
                DROP TABLE #DBACLDBUsers;
            CREATE TABLE #DBACLDBUsers
                ( 
                    DBName NVARCHAR(128), 
                    UserName NVARCHAR(128), 
                    UserType NVARCHAR(128), 
                    UserSID [varbinary](85),
                    db_owner int not null
                )
                
            IF OBJECT_ID('tempdb..#DBACLServices') IS NOT NULL
                DROP TABLE #DBACLServices;
            CREATE TABLE #DBACLServices
                ( 
                    ServiceName NVARCHAR(128)
                )
                
            IF (@ReportOnOwnership=1)
                BEGIN
                IF OBJECT_ID('tempdb..#DBACLObjectOwners') IS NOT NULL
                    DROP TABLE #DBACLObjectOwners;
                CREATE TABLE #DBACLObjectOwners
                    ( 
                        DBName NVARCHAR(128), 
                        ObjectName NVARCHAR(128),
                        ObjectOwner NVARCHAR(128)
                    )
                END 
                
            /*
            You can build your own table with a list of checks to skip. Refer to SP_DBACL.
            */
            IF OBJECT_ID('tempdb..#SkipChecks') IS NOT NULL
                DROP TABLE #SkipChecks;
            CREATE TABLE #SkipChecks
                (
                  DatabaseName NVARCHAR(128) ,
                  CheckID INT ,
                  ServerName NVARCHAR(128)
                );
            CREATE CLUSTERED INDEX IX_CheckID_DatabaseName ON #SkipChecks(CheckID, DatabaseName);

            IF @SkipChecksTable IS NOT NULL
                AND @SkipChecksSchema IS NOT NULL
                AND @SkipChecksDatabase IS NOT NULL
                BEGIN
                SET @StringToExecute1 = 'INSERT INTO #SkipChecks(DatabaseName, CheckID, ServerName )
                SELECT DISTINCT DatabaseName, CheckID, ServerName
                FROM ' + QUOTENAME(@SkipChecksDatabase) + '.' + QUOTENAME(@SkipChecksSchema) + '.' + QUOTENAME(@SkipChecksTable)
                    + ' WHERE ServerName IS NULL OR ServerName = SERVERPROPERTY(''ServerName'');'
                EXEC(@StringToExecute1)
                END

            /* now let us do some work - check the users on the server */
            /* get the roles and permissions - the method depends on the sql version*/
     
            IF  (SUBSTRING (@@VERSION ,1, 25) > 'Microsoft SQL Server 2000')
                Begin
                insert into #DBACLSrvrUsers
                    ( [UserSID], [UserName], [UserType], [SecurityEntity], [SecurityType], [StateDesc] )
                Select [UserSID], [UserName], [UserType], [SecurityEntity], [SecurityType], [StateDesc]  from
                ( select
                        spr.sid as UserSID, 
                        spr.name as UserName,
                        spr.type_desc as UserType,
                        spm.permission_name collate SQL_Latin1_General_CP1_CI_AS as SecurityEntity,
                        'permission' as SecurityType,
                        spm.state_desc as StateDesc
                    from sys.server_principals spr
                    inner join sys.server_permissions spm
                    on spr.principal_id = spm.grantee_principal_id
                    where    (spr.type in ('s', 'u') ) and 
                            (spm.permission_name = 'CONNECT SQL')  

                    Union   -- see to make this better
                        select distinct 
                        sl.sid as UserSID, 
                        sl.name as UserName,
                        'AD_GROUP' as UserType,
                        'CONNECT SQL' as SecurityEntity,
                        'permission' as SecurityType,
                        'GRANT' StateDesc
                    from syslogins sl
                    where  isntgroup = 1
 
                    union all

                    select
                        sp.sid as UserSID,
                        sp.name as User_name,
                        sp.type_desc as UserType,
                        spr.name as SecurityEntity,
                        'role membership' as SecurityType,
                        null as StateDesc
                    from sys.server_principals sp
                    inner join sys.server_role_members srm
                    on sp.principal_id = srm.member_principal_id
                    inner join sys.server_principals spr
                    on srm.role_principal_id = spr.principal_id
                    where sp.type in ('s', 'u') )ServerAccounts            
                END
            ELSE -- SQL 2000 or prior
                BEGIN
                insert into #DBACLSrvrUsers 
                    ( [UserSID], [UserName], [UserType], [SecurityEntity], [SecurityType], [StateDesc] )
                Select [UserSID], [UserName], [UserType], [SecurityEntity], [SecurityType], [StateDesc]  from
                (    select
                        sl.sid as UserSID, 
                        sl.name as UserName,
                        'SQL_LOGIN' as UserType,
                        '' as SecurityEntity,
                        'permission' as SecurityType,
                        '' StateDesc  
                    from syslogins sl
                    where sl.isntname = 0
                    
                    UNION
                    
                    select
                        sl.sid as UserSID, 
                        sl.name as UserName,
                        'WINDOWS_LOGIN' as UserType,
                        '' as SecurityEntity,
                        'permission' as SecurityType,
                        '' StateDesc
                    from syslogins sl
                    where sl.isntuser = 1
                    
                    UNION
                    
                    select
                        sl.sid as UserSID, 
                        sl.name as UserName,
                        'AD_GROUP' as UserType,
                        '' as SecurityEntity,
                        'permission' as SecurityType,
                        '' StateDesc
                    from syslogins sl
                    where  isntgroup = 1
                    )ServerAccounts    
                END                            

            /* now let us do some work - check the users in each db*/
            DECLARE DBName_Cursor CURSOR FOR 
                select name 
                from master.dbo.sysdatabases 
                where name not in ('mssecurity','tempdb') 
                Order by name

            OPEN DBName_Cursor
            FETCH NEXT FROM DBName_Cursor INTO @DBName
            WHILE @@FETCH_STATUS = 0
                BEGIN

                Set @StringToExecute1 = ' Insert into #DBACLDBUsers( DBName, UserName, UserType, UserSID, db_owner ) '+
                    ' SELECT '+''''+@DBName +''''+ ' as DBName ,UserName, ''SQL_LOGIN'', s.UserSID, '+  
                    ' Max(CASE RoleName WHEN ''db_owner'' THEN 1 ELSE 0 END) AS db_owner '+
                    ' from (select b.name as UserName, b.sid as UserSID, c.name as RoleName '+ 
                    ' from ['+ @DBName+'].dbo.sysusers b  '+
                    ' left outer join [' + @DBName+'].dbo.sysmembers a '+
                    ' on b.uid = a.memberuid left outer join ['+@DBName +'].dbo.sysusers c '+
                    ' on a.groupuid = c.uid where b.hasdbaccess=1 and b.issqluser=1 and ISNULL (b.sid , 0x00) not IN  (0x00, 0x01) )s '+
                    ' Group by UserName, UserSID '+
                    ' order by UserName '
                    
                Execute (@StringToExecute1)
                --print @StringToExecute1
             
                Set @StringToExecute1 = ' Insert into #DBACLDBUsers( DBName, UserName, UserType, UserSID, db_owner ) '+
                    ' SELECT '+''''+@DBName +''''+ ' as DBName ,UserName, ''WINDOWS_LOGIN'', s.UserSID, '+  
                    ' Max(CASE RoleName WHEN ''db_owner'' THEN 1 ELSE 0 END) AS db_owner '+
                    ' from (select b.name as UserName, b.sid as UserSID, c.name as RoleName '+ 
                    ' from ['+ @DBName+'].dbo.sysusers b  '+
                    ' left outer join [' + @DBName+'].dbo.sysmembers a '+
                    ' on b.uid = a.memberuid left outer join ['+@DBName +'].dbo.sysusers c '+
                    ' on a.groupuid = c.uid where b.hasdbaccess=1 and b.isntuser = 1)s '+
                    ' Group by UserName, UserSID '+
                    ' order by UserName '
 
                Execute (@StringToExecute1)
                --print @StringToExecute1
             
                Set @StringToExecute1 = ' Insert into #DBACLDBUsers( DBName, UserName, UserType, UserSID, db_owner ) '+
                    ' SELECT '+''''+@DBName +''''+ ' as DBName ,UserName, ''AD_GROUP'', s.UserSID, '+  
                    ' Max(CASE RoleName WHEN ''db_owner'' THEN 1 ELSE 0 END) AS db_owner '+
                    ' from (select b.name as UserName, b.sid as UserSID, c.name as RoleName '+ 
                    ' from ['+ @DBName+'].dbo.sysusers b  '+
                    ' left outer join [' + @DBName+'].dbo.sysmembers a '+
                    ' on b.uid = a.memberuid left outer join ['+@DBName +'].dbo.sysusers c '+
                    ' on a.groupuid = c.uid where b.hasdbaccess=1 and b.isntgroup = 1)s '+
                    ' Group by UserName, UserSID '+
                    ' order by UserName '                
            
                Execute (@StringToExecute1)    
                --print @StringToExecute1            
             
                IF (@ReportOnOwnership=1)
                    BEGIN                        
                    Set @StringToExecute2 = ' Insert into #DBACLObjectOwners (    DBName, ObjectName, ObjectOwner) '+
                        ' SELECT '+''''+@DBName +''''+ ' as DBName , SO.name ObjectName  ,  SU.name ObjectOwner '+
                        ' FROM [' + @DBName + '].dbo.sysobjects SO ' +
                        ' INNER JOIN [' + @DBName + '].dbo.sysusers SU ON so.uid  = su.uid AND su.status <> 0 ' +
                        ' WHERE SO.UID NOT IN (1,3,4)  ' --su.uid <> 1 '
                        
                    Execute (@StringToExecute2)
                    END

                FETCH NEXT FROM DBName_Cursor INTO @DBName
                END

            CLOSE DBName_Cursor
            DEALLOCATE DBName_Cursor

            --select * from #DBACLDBUsers where Username like '%ss%' 
            /* Check1 - Elevated server roles*/
            IF NOT EXISTS ( SELECT  1
                            FROM    #SkipChecks
                            WHERE   DatabaseName IS NULL AND CheckID = 1 )
                BEGIN
                -- unchecked 
                Insert into #DBACLUserResults
                        ( CheckID, ServerName, DatabaseName, UserName, [Priority], FindingsGroup, Finding, URL, Details )
                select 1 as CheckID, 
                        @@Servername ServerName, 
                        Null as DatabaseName,     
                        SAcc.UserName, 
                        5 as Priority, 
                        'Security' as FindingsGroup, 
                        'AD - or server group have elevated rights to the Server - ' +SAcc.SecurityEntity  as Finding, 
                        'C01.01.01.' as URL, 
                        'On server [' + @@servername + '] the AD - or server group [' +SAcc.UserName+ '] have the role [' + SAcc.SecurityEntity +']' as Details
                from    #DBACLSrvrUsers SAcc
                where    ('role membership' = SecurityType ) and 
                        (SAcc.UserName not in ('NT AUTHORITY\\SYSTEM', 'SA')) and 
                        (UserType = 'AD_GROUP')                
                                
                Insert into #DBACLUserResults
                        ( CheckID, ServerName, DatabaseName, UserName, [Priority], FindingsGroup, Finding, URL, Details )
                select 1 as CheckID, 
                        @@Servername ServerName, 
                        Null as DatabaseName,     
                        SAcc.UserName, 
                        6 as Priority, 
                        'Security' as FindingsGroup, 
                        'SQL User have elevated rights to the Server - ' +SAcc.SecurityEntity  as Finding, 
                        'C01.01.02.' as URL, 
                        'On server [' + @@servername + '] the SQL User [' +SAcc.UserName+ '] have the role [' + SAcc.SecurityEntity +']' as Details
                from    #DBACLSrvrUsers SAcc
                where    ('role membership' = SecurityType ) and 
                        (SAcc.UserName not in ('NT AUTHORITY\\SYSTEM', 'SA')) and 
                        (SAcc.UserName not like 'NT SERVICE%') and -- ignore service accounts
                        (UserType = 'WINDOWS_LOGIN')

                Insert into #DBACLUserResults
                        ( CheckID, ServerName, DatabaseName, UserName, [Priority], FindingsGroup, Finding, URL, Details )
                select 1 as CheckID, 
                        @@Servername ServerName, 
                        Null as DatabaseName,     
                        SAcc.UserName, 
                        7 as Priority, 
                        'Security' as FindingsGroup, 
                        'SQL Login have elevated rights to the Server - ' +SAcc.SecurityEntity  as Finding, 
                        'C01.01.03.' as URL, 
                        'On server [' + @@servername + '] the SQL login [' +SAcc.UserName+ '] have the role [' + SAcc.SecurityEntity +']' as Details
                from    #DBACLSrvrUsers SAcc
                where    ('role membership' = SecurityType ) And 
                        (SAcc.UserName not in ('NT AUTHORITY\\SYSTEM', 'SA')) and 
                        (UserType = 'SQL_LOGIN' )

                END

            /* Check2 - Elevated Database roles*/
            IF NOT EXISTS ( SELECT  1
                            FROM    #SkipChecks
                            WHERE   DatabaseName IS NULL AND CheckID = 2 )
                BEGIN
                -- AD Group with dbo
                 Insert into #DBACLUserResults
                        (CheckID, ServerName, DatabaseName, UserName, [Priority], FindingsGroup, Finding, URL, Details )
                select 2 CheckID, 
                        @@Servername ServerName, 
                        DBR.DBName as DatabaseName,     
                        DBR.UserName, 
                        10 as Priority, 
                        'Security' as FindingsGroup, 
                        'AD - or server group have DBO (database owner) rights to the database' as Finding, 
                        'C01.02.01.' as URL, 
                        'On server [' + @@servername + '] in database ['+DBR.DBName+'] the AD Group [' +DBR.UserName+ '] have DBO rights to the database access' as Details
                from    #DBACLDBUsers DBR
                where    (db_owner = 1) and (DBR.UserName <> 'dbo') and (UserType = 'AD_GROUP')
                
                -- AD user (sql user) with dbo
                 Insert into #DBACLUserResults
                        (CheckID, ServerName, DatabaseName, UserName, [Priority], FindingsGroup, Finding, URL, Details )
                select 2 CheckID, 
                        @@Servername ServerName, 
                        DBR.DBName as DatabaseName,     
                        DBR.UserName, 
                        11 as Priority, 
                        'Security' as FindingsGroup, 
                        'SQL User have DBO (database owner) rights to the database' as Finding, 
                        'C01.02.02.' as URL, 
                        'On server [' + @@servername + '] in database ['+DBR.DBName+'] the SQL User [' +DBR.UserName+ '] have DBO rights to the database access' as Details
                from    #DBACLDBUsers DBR
                where    (db_owner = 1) and (DBR.UserName <> 'dbo') and (UserType = 'WINDOWS_LOGIN')

                --SQL Login with dbo
                 Insert into #DBACLUserResults
                        (CheckID, ServerName, DatabaseName, UserName, [Priority], FindingsGroup, Finding, URL, Details )
                select 2 CheckID, 
                        @@Servername ServerName, 
                        DBR.DBName as DatabaseName,     
                        DBR.UserName, 
                        12 as Priority, 
                        'Security' as FindingsGroup, 
                        'SQL Login have DBO (database owner) rights to the database' as Finding, 
                        'C01.02.03.' as URL, 
                        'On server [' + @@servername + '] in database ['+DBR.DBName+'] the SQL Login [' +DBR.UserName+ '] have DBO rights to the database access' as Details
                from    #DBACLDBUsers DBR
                where    (db_owner = 1) and (DBR.UserName <> 'dbo') and (UserType = 'SQL_LOGIN')
                         
                END

            /* Check3 - Database OWNER <> SA*/
            IF NOT EXISTS ( SELECT  1
                            FROM    #SkipChecks
                            WHERE   DatabaseName IS NULL AND CheckID = 3 )
                BEGIN
                IF  (SUBSTRING (@@VERSION ,1, 25) > 'Microsoft SQL Server 2000')
                    Begin
                     Insert into #DBACLUserResults
                            (CheckID, ServerName, DatabaseName, UserName, [Priority], FindingsGroup, Finding, URL, Details, Script1, Script2  )
                    select 3 CheckID, 
                            @@Servername ServerName, 
                            [name] AS DatabaseName,     
                            SUSER_SNAME(owner_sid) AS UserName, 
                            15 as Priority, 
                            'Security' as FindingsGroup, 
                            'SQL user or login is the owner of the database' as Finding, 
                            'C01.03.01.' as URL, 
                            'On server [' + @@servername + '] in database ['+[name] +'] the login [' +SUSER_SNAME(owner_sid)+ '] is the owner of the database' as Details, 
                            'ALTER AUTHORIZATION ON DATABASE::['+[name] +'] TO sa' AS Script1, 'to refine' AS Script2
                                FROM    sys.databases
                                WHERE   SUSER_SNAME(owner_sid) <> SUSER_SNAME(0x01)
            
                    -- and now for the ones without a 'real owner'
                    Insert into #DBACLUserResults
                            (CheckID, ServerName, DatabaseName, UserName, [Priority], FindingsGroup, Finding, URL, Details, Script1, Script2  )
                    select 3 CheckID, 
                            @@Servername ServerName, 
                            [name] AS DatabaseName,     
                            'Unknown' AS UserName, 
                            15 as Priority, 
                            'Security' as FindingsGroup, 
                            'Invalid SQL user or login is the owner of the database' as Finding, 
                            'C01.03.02.' as URL, 
                            'On server [' + @@servername + '] in database ['+[name] +'] the login [' +SUSER_SNAME(sid)+ '] is the owner of the database' as Details, 
                            'EXEC ['+[name] + '].dbo.sp_changedbowner  @loginame = ''sa'' --no user match' AS Script1 , '' as script2
                                FROM    sysdatabases
                                WHERE   isnull (SUSER_SNAME(sid), 'Unknown') = 'Unknown'
                    end
                else
                    Begin
                    Insert into #DBACLUserResults
                            (CheckID, ServerName, DatabaseName, UserName, [Priority], FindingsGroup, Finding, URL, Details, Script1, Script2  )
                    select 3 CheckID, 
                            @@Servername ServerName, 
                            [name] AS DatabaseName,     
                            SUSER_SNAME(sid) AS UserName, 
                            15 as Priority, 
                            'Security' as FindingsGroup, 
                            'SQL user or login is the owner of the database' as Finding, 
                            'C01.03.01.' as URL, 
                            'On server [' + @@servername + '] in database ['+[name] +'] the login [' +SUSER_SNAME(sid)+ '] is the owner of the database' as Details, 
                            'EXEC ['+[name] + '].dbo.sp_changedbowner ''sa'' --SQL 2000' AS Script1 , '' as script2
                                FROM    sysdatabases
                                WHERE   SUSER_SNAME(sid) <> SUSER_SNAME(0x01)
            
                    -- and now for the ones without a 'real owner'
                    Insert into #DBACLUserResults
                            (CheckID, ServerName, DatabaseName, UserName, [Priority], FindingsGroup, Finding, URL, Details, Script1, Script2  )
                    select 3 CheckID, 
                            @@Servername ServerName, 
                            [name] AS DatabaseName,     
                            'Unknown' AS UserName, 
                            15 as Priority, 
                            'Security' as FindingsGroup, 
                            'Invalid SQL user or login is the owner of the database' as Finding, 
                            'C01.03.02.' as URL, 
                            'On server [' + @@servername + '] in database ['+[name] +'] the login [' +SUSER_SNAME(sid)+ '] is the owner of the database' as Details, 
                            'EXEC ['+[name] + '].dbo.sp_changedbowner  @loginame = ''sa'' --no user match' AS Script1 , '' as script2
                                FROM    sysdatabases
                                WHERE   isnull (SUSER_SNAME(sid), 'Unknown') = 'Unknown'
                                
                    end                
                END

            /* Check4 - User has connection rights to the server, but no database access*/
            IF NOT EXISTS ( SELECT  1
                            FROM    #SkipChecks
                            WHERE   DatabaseName IS NULL AND CheckID = 4 )
                BEGIN
                
                -- domain Groups
                Insert into #DBACLUserResults
                    ( CheckID, ServerName, DatabaseName, UserName, [Priority], FindingsGroup, Finding, URL, Details, Script1, Script2 )
                select 4 AS CheckID, 
                    @@Servername ServerName, 
                    Null as DatabaseName,     
                    SAcc.UserName, 
                    20 as Priority, 
                    'Consistency and Integrity' as FindingsGroup, 
                    'AD group have connection rights to the server, but no database access' as Finding, 
                    'C01.04.01.' as URL, 
                    'On server [' + @@servername + '] the AD Group [' +SAcc.UserName+ '] have connection rights to the server, but no database access was granted.' as Details, 
                    'USE master; ALTER User [' +SAcc.UserName+ '] DISABLE;' Script1, 
                    'exec master.dbo.sp_revokelogin  N''' +SAcc.UserName+ ''' -- todo add check for disabled'  Script2    
                from #DBACLSrvrUsers SAcc left outer join #DBACLDBUsers dbroles on SAcc.UserName =  dbroles.UserName
                where dbroles.UserName is null  AND SAcc.UserName like  '%[\]%'
                group by SAcc.UserName
                having (COUNT (*) = 1) and ( sum(case when ((SecurityEntity = 'AD_GROUP') or (SecurityEntity = '')) then  1 else 0 end) = 1)    
                order by 1 

                -- domain accounts
                Insert into #DBACLUserResults
                    ( CheckID, ServerName, DatabaseName, UserName, [Priority], FindingsGroup, Finding, URL, Details, Script1, Script2 )
                select 4 AS CheckID, 
                    @@Servername ServerName, 
                    Null as DatabaseName,     
                    SAcc.UserName, 
                    21 as Priority, 
                    'Consistency and Integrity' as FindingsGroup, 
                    'SQL User have connection rights to the server, but no database access' as Finding, 
                    'C01.04.02.' as URL, 
                    'On server [' + @@servername + '] the SQL User [' +SAcc.UserName+ '] have connection rights to the server, but no database access was granted.' as Details, 
                    'USE master; ALTER User [' +SAcc.UserName+ '] DISABLE;' Script1, 
                    'exec master.dbo.sp_revokelogin  N''' +SAcc.UserName+ ''' -- todo add check for disabled'  Script2    
                from #DBACLSrvrUsers SAcc left outer join #DBACLDBUsers dbroles on SAcc.UserName =  dbroles.UserName
                where dbroles.UserName is null  AND SAcc.UserName like  '%[\]%'
                group by SAcc.UserName
                having (COUNT (*) = 1) and ( sum(case when ((SecurityEntity = 'WINDOWS_LOGIN') or (SecurityEntity = '')) then  1 else 0 end) = 1)    
                order by 1 

                -- SQL Login
                Insert into #DBACLUserResults
                    ( CheckID, ServerName, DatabaseName, UserName, [Priority], FindingsGroup, Finding, URL, Details, Script1, Script2 )
                select 4 AS CheckID, 
                    @@Servername ServerName, 
                    Null as DatabaseName,     
                    SAcc.UserName, 
                    22 as Priority, 
                    'Consistency and Integrity' as FindingsGroup, 
                    'User have connection rights to the server, but no database access' as Finding, 
                    'C01.04.03.' as URL, 
                    'On server [' + @@servername + '] the login [' +SAcc.UserName+ '] have connection rights to the server, but no database access was granted.' as Details, 
                    'USE master; ALTER LOGIN [' +SAcc.UserName+ '] DISABLE;' Script1, 
                    'drop login [' +SAcc.UserName+ '] -- todo add check for disabled'  Script2        
                    --'exec master.dbo.sp_revokelogin  N''' +SAcc.UserName+ ''' -- todo add check for disabled'  Script2        
                from #DBACLSrvrUsers SAcc left outer join #DBACLDBUsers dbroles on SAcc.UserName =  dbroles.UserName
                where dbroles.UserName is null AND SAcc.UserName not like  '%[\]%'
                group by SAcc.UserName
                having (COUNT (*) = 1) and ( sum(case when ((SecurityEntity = 'SQL_LOGIN') or (SecurityEntity = '')) then  1 else 0 end) = 1)
                order by 1 
                         
                END

            /* Check5 - account has database Access but no connection rights to the server*/
            IF NOT EXISTS ( SELECT  1
                            FROM    #SkipChecks
                            WHERE   DatabaseName IS NULL AND CheckID = 5 )
                BEGIN
                -- domain accounts
                Insert into #DBACLUserResults
                        ( ServerName, DatabaseName, UserName, [Priority], FindingsGroup, Finding, URL, Details, Script1, Script2  )
                select @@Servername ServerName, 
                        dbroles.DBName as DatabaseName,     
                        dbroles.UserName, 
                        30 as Priority, 
                        'Consistency and Integrity' as FindingsGroup, 
                        'AD - or server group has db access but not server login' as Finding, 
                        'C01.04.04.' as URL, 
                        'On server [' + @@servername + '] in DB [' + dbroles.DBName + '] the AD Group [' +dbroles.UserName+ '] have rights on the db, but no server access. ' as Details, 
                        'CREATE LOGIN [' +dbroles.UserName+ '] FROM WINDOWS WITH DEFAULT_DATABASE=[master], DEFAULT_LANGUAGE=[us_english];' as Script1, 
                        ' '  as Script2
                    from #DBACLDBUsers dbroles  left outer join #DBACLSrvrUsers SAcc on   dbroles.UserName = SAcc.UserName
                    where (SAcc.UserName is null) and (dbroles.UserName <> 'dbo')
                      AND (dbroles.UserType = 'AD_Group') 
                      and (dbroles.UserName not like 'NT AUTHORITY\%')
                                                                                          
                Insert into #DBACLUserResults
                        ( ServerName, DatabaseName, UserName, [Priority], FindingsGroup, Finding, URL, Details, Script1, Script2  )
                select @@Servername ServerName, 
                        dbroles.DBName as DatabaseName,     
                        dbroles.UserName, 
                        31 as Priority, 
                        'Consistency and Integrity' as FindingsGroup, 
                        'SQL User has db access but not server login' as Finding, 
                        'C01.04.05.' as URL, 
                        'On server [' + @@servername + '] in DB [' + dbroles.DBName + '] the SQL User [' +dbroles.UserName+ '] have rights on the db, but no server access. ' as Details, 
                        'CREATE LOGIN [' +dbroles.UserName+ '] FROM WINDOWS WITH DEFAULT_DATABASE=[master], DEFAULT_LANGUAGE=[us_english];' as Script1, 
                        ' '  Script2
                    from #DBACLDBUsers dbroles  left outer join #DBACLSrvrUsers SAcc on   dbroles.UserName = SAcc.UserName
                    where (SAcc.UserName is null) and (dbroles.UserName <> 'dbo')
                      AND (dbroles.UserType = 'WINDOWS_LOGIN')

                -- sql accounts
                Insert into #DBACLUserResults
                        ( ServerName, DatabaseName, UserName, [Priority], FindingsGroup, Finding, URL, Details, Script1, Script2  )
                select @@Servername ServerName, 
                        dbroles.DBName as DatabaseName,     
                        dbroles.UserName, 
                        32 as Priority, 
                        'Consistency and Integrity' as FindingsGroup, 
                        'SQL Login has db access but not server login' as Finding, 
                        'C01.04.06.' as URL, 
                        'On server [' + @@servername + '] in DB [' + dbroles.DBName + '] the SQL login [' +dbroles.UserName+ '] have rights on the db, but no server access. ' as Details, 
                        'USE [' + dbroles.DBName + ']; ALTER LOGIN [' +dbroles.UserName+ '] DISABLE;' Script1, 
                        ' exec [' + dbroles.DBName + '].dbo.sp_revokedbaccess N''' +dbroles.UserName+ ''' -- todo add check for disabled'  Script2
                        --'USE [' + dbroles.DBName + ']; DROP Schema [' +dbroles.UserName+ '] ; DROP Login [' +dbroles.UserName+ '] ; -- todo add check for disabled'  Script2
                     from #DBACLDBUsers dbroles  left outer join #DBACLSrvrUsers SAcc on   dbroles.UserName = SAcc.UserName
                    where (SAcc.UserName is null) and (dbroles.UserName <> 'dbo')
                      AND (dbroles.UserType = 'SQL_LOGIN')
                                            
                delete FROM #DBACLUserResults
                WHERE DatabaseName = 'msdb' AND
                      UserName = 'MS_DataCollectorInternalUser' AND 
                      [Priority] = 20 AND 
                      FindingsGroup = 'Consistency and Integrity' AND 
                      Finding = 'User has db access but not server login'  
                      
                END

            /* Check6 - User is a sql login, has server and database Access but the SID differs*/
            IF NOT EXISTS ( SELECT  1
                            FROM    #SkipChecks
                            WHERE   DatabaseName IS NULL AND CheckID = 6 )
                BEGIN
                Insert into #DBACLUserResults
                        ( ServerName, DatabaseName, UserName, [Priority], FindingsGroup, Finding, URL, Details, Script1, Script2  )
                select @@Servername ServerName, 
                        dbroles.DBName as DatabaseName,     
                        dbroles.UserName, 
                        40 as Priority, 
                        'Consistency and Integrity' as FindingsGroup, 
                        'SQL Login SID different between db and server' as Finding, 
                        'C01.04.07.' as URL, 
                        'On server [' + @@servername + '] and DB [' + dbroles.DBName + '] the login [' +SAcc.UserName+ '] have different SIDS.' as Details, 
                        'USE [' + dbroles.DBName + ']; exec SP_Change_users_login ''auto_fix'' , ''' +SAcc.UserName+ ''';' Script1, 
                        '--thats it'  Script2
                    from #DBACLSrvrUsers SAcc inner join #DBACLDBUsers dbroles on SAcc.UserName =  dbroles.UserName
                    where dbroles.UserSID <> SAcc.UserSID
                    and dbroles.UserName not like  '%[\]%'
                END

            /* if the nativeDomain has been specified - look for acounts in a different domain*/
            if (@NativeDomain is not null)
                Begin
                set @NativeDomain = UPPER(@NativeDomain)
                /* Check7 - Server User has a non-native Domain Account */
                IF NOT EXISTS ( SELECT  1
                                FROM    #SkipChecks
                                WHERE   DatabaseName IS NULL AND CheckID = 7 )
                    BEGIN
                    Insert into #DBACLUserResults
                            ( ServerName, DatabaseName, UserName, [Priority], FindingsGroup, Finding, URL, Details, Script1, Script2 )
                    select @@Servername ServerName, 
                            Null as DatabaseName,     
                            SAcc.UserName, 
                            50 as Priority, 
                            'Non-Native Domain Access' as FindingsGroup, 
                            'Non-Native Domain Access' as Finding, 
                            'C01.04.08.' as URL, 
                            'On server [' + @@servername + '] the login [' +SAcc.UserName+ '] does not belong to the native domain. ' as Details, 
                            'USE master; ALTER User [' +SAcc.UserName+ '] DISABLE;' Script1, 
                            'EXEC master.dbo.sp_revokelogin @loginame = N''' +SAcc.UserName+ ''' ; -- todo add check for disabled'  Script2
                        from   #DBACLSrvrUsers SAcc 
                        where SAcc.UserName like '%[\]%' and SAcc.UserName not like ( @NativeDomain+'[\]%')AND 
                              (SAcc.UserName NOT LIKE 'NT AUTHORITY[\]%') AND 
                              (SAcc.UserName NOT LIKE 'NT SERVICE[\]%') AND 
                              (SAcc.UserName NOT LIKE @ServerName+'[\]%')
                    END

                /* Check8 - db User has a non-native Domain Account */
                IF NOT EXISTS ( SELECT  1
                                FROM    #SkipChecks
                                WHERE   DatabaseName IS NULL AND CheckID = 8 )
                    BEGIN
                    Insert into #DBACLUserResults
                            ( ServerName, DatabaseName, UserName, [Priority], FindingsGroup, Finding, URL, Details, Script1, Script2 )
                    select @@Servername ServerName, 
                            dbroles.DBName as DatabaseName,     
                            dbroles.UserName, 
                            50 as Priority, 
                            'Non-Native Domain Access' as FindingsGroup, 
                            'Non-Native Domain Access' as Finding, 
                            'C01.04.09.' as URL, 
                            'On server [' + @@servername + '] in DB [' + dbroles.DBName + '] the login [' +dbroles.UserName+ '] does not belong to the native domain. ' as Details, 
                            'USE [' + dbroles.DBName + ']; ALTER LOGIN [' + dbroles.UserName + '] DISABLE;' Script1, 
                            'USE [' + dbroles.DBName + ']; sp_revokedbaccess [' + dbroles.UserName + '] ; -- todo add check for disabled'  Script2
                        from #DBACLDBUsers dbroles   
                        where dbroles.UserName like '%[\]%' and dbroles.UserName not like ( @NativeDomain+'[\]%') AND 
                              (dbroles.UserName NOT LIKE 'NT AUTHORITY[\]%') AND 
                              (dbroles.UserName NOT LIKE 'NT SERVICE[\]%') AND 
                              (dbroles.UserName NOT LIKE @ServerName+'[\]%')
                    END

                End 

            /* if the check has been specified, it lists all owners. this can make for a looonng list. 
               for future, i will modify it to report on a single account's objects, */
            if (@ReportOnOwnership = 1)  
                Begin
                /* Check9 - object owners */
                
                IF NOT EXISTS ( SELECT  1
                                FROM    #SkipChecks
                                WHERE   DatabaseName IS NULL AND CheckID = 9 )
                    BEGIN
                    Insert into #DBACLUserResults
                            ( ServerName, DatabaseName, UserName, [Priority], FindingsGroup, Finding, URL, Details, Script1, Script2 )
                    select @@Servername ServerName, 
                            SAcc.DBName  as DatabaseName,     
                            SAcc.ObjectOwner UserName, 
                            60 as Priority, 
                            'Ownership' as FindingsGroup, 
                            'User owned objects' as Finding, 
                            'C01.05.' as URL, 
                            'On server [' + @@servername + '] in DB [' + SAcc.DBName + '] the login [' +SAcc.ObjectOwner+ '] owns object [' + SAcc.ObjectName + ']' as Details, 
                            '' Script1, 
                            '' Script2
                        from   #DBACLObjectOwners SAcc   
                    END
                End 
    
                /* Check10 - domain names found in AD
                exec sp_DbaChecklistUser        
                    @IgnorePrioritiesBelow = 46,
                    @IgnorePrioritiesAbove = 55 
                */                
    
                IF NOT EXISTS ( SELECT  1
                            FROM    #SkipChecks
                            WHERE   DatabaseName IS NULL AND CheckID = 10 )
                    BEGIN
                    
                    DECLARE @DomainName NVARCHAR(128) = ''
                    declare @UserType  nvarchar(60) = ''
                    DECLARE DomainName_Cursor CURSOR FOR 
                    select  DISTINCT SAcc.UserName DomainName , UserType
                    from    #DBACLSrvrUsers SAcc 
                    where    (SAcc.UserType in ('WINDOWS_LOGIN', 'AD_GROUP')) AND
                            (SAcc.UserName NOT LIKE 'NT SERVICE\%')

                    IF OBJECT_ID('tempdb..#DBACLDomainNames') IS NOT NULL
                        DROP TABLE #DBACLDomainNames;
                    CREATE TABLE #DBACLDomainNames
                        (
                            AccountName NVARCHAR(128) ,
                            AccountType NVARCHAR(60) ,
                            AccountPriv NVARCHAR(20) ,
                            AccountMap  NVARCHAR(128) ,
                            AccountPerm NVARCHAR(30) 
                          )

                    OPEN DomainName_Cursor 
                    FETCH NEXT FROM DomainName_Cursor INTO @DomainName, @UserType
                    WHILE @@FETCH_STATUS = 0
                        BEGIN
                         
                        BEGIN TRY 
                            INSERT INTO #DBACLDomainNames  EXEC  master.dbo.xp_logininfo @DomainName     
                        END TRY
                        BEGIN CATCH        
                            if (@UserType = 'AD_GROUP')
                                Begin
                                Insert into #DBACLUserResults
                                        ( ServerName, DatabaseName, UserName, [Priority], FindingsGroup, Finding, URL, Details )
                                values (@@Servername , 
                                        Null ,     
                                        @DomainName  , 
                                        70 , 
                                        'AD Group does not exist in AD'  , 
                                        'AD Group does not exist in AD' , 
                                        'C01.06.01.'  , 
                                        'On server [' + @@servername + '], the AD Group ['+@DomainName +'] is not matched in AD ' )
                                End 
                            Else
                                Begin
                                Insert into #DBACLUserResults
                                        ( ServerName, DatabaseName, UserName, [Priority], FindingsGroup, Finding, URL, Details )
                                values (@@Servername , 
                                        Null ,     
                                        @DomainName  , 
                                        71 , 
                                        'SQL User does not exist in AD'  , 
                                        'SQL User does not exist in AD' , 
                                        'C01.06.02.'  , 
                                        'On server [' + @@servername + '], the SQL User ['+@DomainName +'] is not matched in AD ' )
                                End
                        END Catch
                        FETCH NEXT FROM DomainName_Cursor INTO @DomainName, @UserType
                        END

                    CLOSE DomainName_Cursor
                    DEALLOCATE DomainName_Cursor
                    End
                        
            /* CHECK99 what service accounts are you using */
            IF NOT EXISTS ( SELECT  1
                            FROM    #SkipChecks
                            WHERE   DatabaseName IS NULL AND CheckID = 99 )
                BEGIN
                /*build up a table of services that we want to check in the registry for*/
                /*first make provision for default and named instances*/
                if upper(@@SERVICENAME )= 'MSSQLSERVER'
                    Begin
                    Insert into #DBACLServices (ServiceName) values ('Mssqlserver')
                    Insert into #DBACLServices (ServiceName) values ('MssqlFDLauncher')
                    Insert into #DBACLServices (ServiceName) values ('SQLServerAgent')
                    End 
                else
                    Begin
                    Insert into #DBACLServices (ServiceName) values ('Mssql$'+@@SERVICENAME)
                    Insert into #DBACLServices (ServiceName) values ('MssqlFDLauncher$'+@@SERVICENAME)
                    Insert into #DBACLServices (ServiceName) values ('SQLAgent$'+@@SERVICENAME)
                    end 
                    
                Insert into #DBACLServices (ServiceName) values ('MsDtsServer100')
                Insert into #DBACLServices (ServiceName) values ('reportserver')                 
                Insert into #DBACLServices (ServiceName) values ('SQLBrowser')
                Insert into #DBACLServices (ServiceName) values ('mssqlserverADHelper100')
                Insert into #DBACLServices (ServiceName) values ('mssqlserverOlapService')
                Insert into #DBACLServices (ServiceName) values ('SQLWriter')
    
                DECLARE @ServiceName varchar(250) -- the service we want to check for
                DECLARE @ServiceAccountName varchar(250) -- the account under which it runs
                Declare @ServiceFullRegistry varchar(300) -- and the complete path in the registry
            
                /* now let us do some work - check for each service under which account it runs*/
                DECLARE ServiceName_Cursor CURSOR FOR 
                    select ServiceName 
                    from #DBACLServices 

                OPEN ServiceName_Cursor 
                FETCH NEXT FROM ServiceName_Cursor INTO @ServiceName
                WHILE @@FETCH_STATUS = 0
                    BEGIN
                    /* read from the registry by executing master.dbo.xp_instance_regread*/
                    set @ServiceAccountName = ''
                    -- if ever the registry settings changes in OS version - you will need to change the registry path
                    set @ServiceFullRegistry = N'SYSTEM\CurrentControlSet\Services\' + @ServiceName 
                    EXECUTE master.dbo.xp_instance_regread
                    N'HKEY_LOCAL_MACHINE',
                    @ServiceFullRegistry,  
                    N'ObjectName',
                    @ServiceAccountName OUTPUT,
                    N'no_output'
                     
                    Insert into #DBACLUserResults
                            ( ServerName, DatabaseName, UserName, [Priority], FindingsGroup, Finding, URL, Details )
                    values (@@Servername , 
                            Null ,     
                            @ServiceAccountName  , 
                            90 , 
                            'Service Accounts'  , 
                            'Service accounts' , 
                            'C01.07.'  , 
                            'On server [' + @@servername + '], the SQL related service ['+@ServiceName +'] runs under the  [' +@ServiceAccountName+ '] Account. ' )

                    FETCH NEXT FROM ServiceName_Cursor INTO @ServiceName
                    END

                CLOSE ServiceName_Cursor
                DEALLOCATE ServiceName_Cursor
            
                /* check if it is a node on a cluster - because then you will have to check each node in the cluster for the service accounts*/
                If (SERVERPROPERTY('IsClustered') = 1)
                    Begin
                    Insert into #DBACLUserResults
                            ( ServerName, DatabaseName, UserName, [Priority], FindingsGroup, Finding, URL, Details )
                    values (@@Servername , 
                            Null ,     
                            @ServiceAccountName  , 
                            99 , 
                            'Service Accounts'  , 
                            'Cluster' , 
                            'C01.07.'  , 
                            '[' + @@servername + '], is a cluster, so you will need to check on each node for the service accounts. ' )
                    End
                END                
                
            SELECT  ServerName, DatabaseName, UserName, Priority, FindingsGroup, Finding, @HelpUrl + URL AS URL, Details, Script1, Script2
            FROM    #DBACLUserResults
            WHERE   (Priority between @IgnorePrioritiesBelow and @IgnorePrioritiesAbove) AND
                    (UserName <> 'BUILTIN\Administrators')
            order by 4, 5, 6, 1, 2, 3
            End
        end 
   
End
