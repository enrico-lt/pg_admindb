/*
.SYNOPSIS
    Check the foreign keys of a database for consistency
.DESCRIPTION
    This script scans every foreign key of the databse
	for consistency. It creates a temporary table 'fk_check_results'. If the
	script found bad rows it will be written out to csv file.

    Script needs db_datareader permissions.
.NOTES
    Author:				Enrico La Torre
    Last change:		2020-05-29
*/
DO $$
DECLARE
SQLtext text;
fk_name text;
fK_table text;
fk_column text;
pk_table text;
pk_column text;
fkcolumnarray text[];
pkcolumnarray text[];
col text;
selectstring text;
joinstring text;
wherestring text;
sqlcmd text;
BEGIN
selectstring := 'ARRAY[';
joinstring := '';
wherestring := '';
create TEMPORARY table IF NOT EXISTS fk_check_results ( "FK_ID(Bad)" text[], FK_Table text, FK_Col text, FK_Name text, delstatement text);  
FOR fk_name, fK_table, fk_column, pk_table, pk_column IN
	SELECT -- Get foreign key definition
	c.conname as "FK_Name"
	,conrelid::regclass AS "FK_Table"
	,CASE WHEN pg_get_constraintdef(c.oid) LIKE 'FOREIGN KEY %' THEN substring(pg_get_constraintdef(c.oid), 14, position(')' in pg_get_constraintdef(c.oid))-14) END AS "FK_Column"
	,CASE WHEN pg_get_constraintdef(c.oid) LIKE 'FOREIGN KEY %' THEN substring(pg_get_constraintdef(c.oid), position(' REFERENCES ' in pg_get_constraintdef(c.oid))+12, position('(' in substring(pg_get_constraintdef(c.oid), 14))-position(' REFERENCES ' in pg_get_constraintdef(c.oid))+1) END AS "PK_Table"
	,CASE WHEN pg_get_constraintdef(c.oid) LIKE 'FOREIGN KEY %' THEN substring(pg_get_constraintdef(c.oid), position('(' in substring(pg_get_constraintdef(c.oid), 14))+14, position(')' in substring(pg_get_constraintdef(c.oid), position('(' in substring(pg_get_constraintdef(c.oid), 14))+14))-1) END AS "PK_Column"
	FROM   pg_constraint c
	JOIN   pg_namespace n ON n.oid = c.connamespace
	WHERE  contype IN ('f', 'p')
	AND pg_get_constraintdef(c.oid) LIKE 'FOREIGN KEY %'
LOOP
	IF fk_column LIKE '%,%' THEN -- multi column foreign keys
		RAISE NOTICE 'Multi-column FK! Foreign key columns (%) refrence (%) ', fk_column, pk_column;
		select regexp_split_to_array(fk_column,',.') into fkcolumnarray; -- . is a white space after the , in the column list
		select regexp_split_to_array(pk_column,',.') into pkcolumnarray;
		RAISE NOTICE 'Foreign key columns %', fkcolumnarray;
		RAISE NOTICE 'Reference key columns %', pkcolumnarray;
		RAISE NOTICE 'FK_Table % and PK_TABLE %',fK_table,pk_table;
		FOR i in 1 .. array_upper(fkcolumnarray,1)
		LOOP
		selectstring := selectstring || ', ' || fK_table || '.' || fkcolumnarray[i];
		joinstring := joinstring || ' and ' || fK_table || '.' || fkcolumnarray[i] || ' = ' ||  pk_table || '.' || pkcolumnarray[i];
		wherestring := wherestring || ' and ' || fK_table || '.' || fkcolumnarray[i] || ' IS NOT NULL and ' || pk_table || '.' || pkcolumnarray[i] || ' IS NULL';
		END LOOP;
		SELECT regexp_replace(selectstring,', ','') into selectstring; -- Remove the leading comma in the column selection
		RAISE NOTICE 'select %]  from  % left join % on 1=1 % where 1=1 %;', selectstring,fK_table,pk_table,joinstring,wherestring;
		execute format('insert into fk_check_results SELECT %1$s], ''%2$s'', ''%6$s'', ''%7$s'' 
					, ''DELETE FROM %2$s WHERE (%6$s) = ('' || array_to_string(%1$s],'','') ||'');''  
					FROM %2$s 
					LEFT JOIN %3$s on 1=1 %4$s 
					WHERE 1=1 %5$s;
		',selectstring,fK_table,pk_table,joinstring,wherestring,fk_column,fk_name);
		-- clear process variables
		selectstring := 'ARRAY[';
		joinstring := '';
		wherestring := '';
	ELSE -- single column foreign keys
		execute format('insert into fk_check_results SELECT ARRAY[r.%2$s::text], ''%1$s'', ''%2$s'', ''%5$s''
					, ''DELETE FROM %1$s WHERE %2$s = '' || r.%2$s::text ||'';''
					FROM %1$s r
					LEFT JOIN %3$s p on r.%2$s = p.%4$s
					WHERE p.%4$s IS NULL
					and r.%2$s IS NOT NULL;',fK_table, fk_column, pk_table, pk_column, fk_name);
	END IF;
	RAISE NOTICE 'Scanned foreign key ''%'' on table ''%''', fk_name, fK_table;
END LOOP;
END
$$ language 'plpgsql';

-- Write output of fk_check_results if EXISTS
DO $do$
	DECLARE
	databasename text;
	BEGIN
	SELECT current_database() INTO databasename;
	IF EXISTS (
		SELECT                
		FROM fk_check_results) THEN
		EXECUTE format('COPY fk_check_results TO ''{logpath}\fk_check_results_%1$s.csv'' DELIMITER '','' CSV HEADER;',databasename);
		RAISE EXCEPTION 'Bad Foreign Key rows found in database ''%''!', databasename USING HINT = 'Check the file in {logpath}';
	END IF;
	END
$do$;