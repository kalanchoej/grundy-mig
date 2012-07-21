-- get started by removing any old stuff so it won't interfere with new stuff going in.
DROP SCHEMA IF EXISTS m_gc CASCADE;

-- Create the migration scheme and use the migration tools to build it up
CREATE SCHEMA m_gc;
\i /mnt/evergreen/migration/migration-tools/sql/base/base.sql
select migration_tools.init('m_gc');
select migration_tools.build('m_gc');

-- This is our main table for data manip and prep 
DROP TABLE IF EXISTS m_gc.asset_copy_legacy;
CREATE table m_gc.asset_copy_legacy (
egid BIGINT,
hseq BIGINT,
l_price TEXT,
l_call_num TEXT,
l_barcode TEXT,
l_location TEXT,
l_create_date TEXT) inherits (m_gc.asset_copy);

-- bring in the data from the output of extract_holdings script. Remember that the first three rows of this file
-- need to be deleted
\copy m_gc.asset_copy_legacy(egid, hseq, l_price, l_call_num, l_barcode, l_location, l_create_date) from /mnt/evergreen/migration/GrundyFinal/gc-HOLDINGS.pg

-- Get rid of any whitespace around the fields that may cause us problems later
UPDATE m_gc.asset_copy_legacy SET l_barcode = BTRIM(l_barcode), l_call_num = BTRIM(l_call_num), l_price = BTRIM(l_price), l_location = BTRIM(l_location);

-- We aren't going to import items without barcodes, so just delete them
DELETE FROM m_gc.asset_copy_legacy where l_barcode = '';

-- Set some default values and clean up the price fields
UPDATE m_gc.asset_copy_legacy SET circ_lib = 105, creator = 1, editor = 1, loan_duration = 2, fine_level = 2, price = nullif(replace(replace(l_price, ',', ''), 'p$', ''),'')::numeric(8,2), barcode = l_barcode;

-- Grundy doesn't want to retain any records with these locations so delete them. This is a small number of records
DELETE from m_gc.asset_copy_legacy where l_location = 'Book & Cassette' or l_location = 'Large Print Books (Juvenile)' or l_location = 'Magazines (Juvenile)' or l_location = 'Magnifying glass' or l_location = 'Staff only';

-- Uppercase all the location names to make matching them up easier in the following steps
update m_gc.asset_copy_legacy set l_location = UPPER(l_location);

-- Prep the location matching table
DROP TABLE if exists m_gc.loc_map;
CREATE TABLE m_gc.loc_map ( l_location TEXT, l_circ_mod TEXT, l_shelf TEXT );

-- Bring in the location map from the tab separated sheet (This was made from a worksheet)
\copy m_gc.loc_map from /mnt/evergreen/migration/GrundyFinal/location_map.txt

-- Uppercase these locations as well
update m_gc.loc_map set l_location = UPPER(l_location);

-- I haven't a clue why we create this index...
CREATE unique index m_gc_indx1 on m_gc.loc_map (l_location);

-- I'm also not clear why this didn't just happen earlier when we created the table...
ALTER TABLE m_gc.asset_copy_legacy ADD COLUMN l_circ_mod TEXT, ADD COLUMN l_shelf TEXT;

-- Merge some copy locations per Grundy's worksheet
-- Commenting this section because Grundy wants to keep these locatoins
-- update m_gc.asset_copy_legacy set l_location = replace(l_location, 'FICTION (EASY) RED DOT BOOKS', 'FICTION (CHILDREN/EASY)');
-- update m_gc.asset_copy_legacy set l_location = replace(l_location, 'FICTION (EASY) BLUE DOT BOOKS', 'FICTION (CHILDREN/EASY)');
-- update m_gc.asset_copy_legacy set l_location = replace(l_location, 'FICTION (EASY) GREEN DOT BOOKS', 'FICTION (CHILDREN/EASY)');
-- update m_gc.asset_copy_legacy set l_location = replace(l_location, 'BIOGRAPHY (YOUNG ADULTS)', 'BIOGRAPHY');

-- Wherever the locations in the copy_legacy table match up with the map - set the shelf loc and circ mod to match as well
UPDATE m_gc.asset_copy_legacy a 
  SET l_circ_mod = b.l_circ_mod, l_shelf = b.l_shelf
FROM m_gc.loc_map b
WHERE a.l_location = b.l_location;

-- Now bring the temp value into the circ_modifier field
UPDATE m_gc.asset_copy_legacy
  SET circ_modifier = l_circ_mod;

-- Put the values from the legacy table into the actual copy location staging table
-- This looks kinda fishy. Step 3 of the 2.1 docs look to do this differently
INSERT INTO m_gc.asset_copy_location (name, owning_lib)
  SELECT DISTINCT l_shelf, circ_lib FROM m_gc.asset_copy_legacy;

UPDATE m_gc.asset_copy_legacy a
  SET location = b.id
  FROM m_gc.asset_copy_location b
  WHERE a.l_shelf = b.name
  and a.circ_lib = b.owning_lib;

-- Move legacy create dates into staging create_date
UPDATE m_gc.asset_copy_legacy SET create_date = l_create_date::date;

-- Set age protection for records that aren't more than 6 months old
UPDATE m_gc.asset_copy_legacy
  SET age_protect = 2
  WHERE create_date::date > (CURRENT_DATE - INTERVAL '6 months')::date;

-- internal barcode dupes
DROP TABLE IF EXISTS m_gc.item_internal_dupes;

-- check for internal barcode dupes and add a prefix
-- SELECT barcode, count(*)
--FROM m_gc.asset_copy
--GROUP BY barcode
--HAVING COUNT(*) > 1;

-- Look for items that have the same barcode so we can get rid of them
CREATE TABLE m_gc.item_internal_dupes
AS SELECT * FROM m_gc.asset_copy_legacy
WHERE barcode IN (
  SELECT barcode FROM m_gc.asset_copy
  GROUP BY BARCODE HAVING COUNT(*) > 1
);

-- Delete the duplicate barcoded items. It doesn't matter which of the copies get deleted so long as one does
DELETE FROM m_gc.asset_copy
WHERE id IN (select id from m_gc.item_internal_dupes);

-- Get rid of call number entries that are missing a copy
DELETE FROM m_gc.asset_call_number
WHERE id NOT in (select call_number FROM m_gc.asset_copy);

-- We aren't importing stat cats so this probably isn't doing anything
DELETE FROM m_gc.asset_stat_cat_entry_copy_map
WHERE owning_copy IN (SELECT id FROM m_gc.item_internal_dupes);

-- dupes with incumbant items
-- SELECT barcode
--   FROM m_gc.asset_copy
--  JOIN asset.copy USING (barcode)
--  WHERE NOT copy.deleted;

-- account for bib merges -- MUST MUST MUST be done PRIOR to populate call numbers step
\echo accounting for bib merging
DROP TABLE IF EXISTS m_gc.merge;
CREATE TABLE m_gc.merge (
lead BIGINT,
sub BIGINT
);
\copy m_gc.merge FROM /mnt/evergreen/migration/GrundyFinal/rpt/gc.merge

UPDATE m_gc.asset_copy_legacy a
SET egid = b.lead
FROM m_gc.merge b
WHERE a.egid = b.sub;

TRUNCATE m_gc.asset_call_number;

INSERT INTO m_gc.asset_call_number ( 
  label, record, owning_lib, creator, editor
  ) SELECT DISTINCT
    l_call_num,
    egid,
    circ_lib, -- GCJN
    1,  -- Admin
    1 -- Admin
    FROM m_gc.asset_copy_legacy AS i WHERE egid <> -1 AND egid 
      IN (SELECT id FROM biblio.record_entry) ORDER BY 1,2,3;

--link call number labels to asset.copy
\echo linking call numbers to asset.copy
UPDATE m_gc.asset_copy_legacy AS i SET call_number = COALESCE(
 (SELECT c.id FROM m_gc.asset_call_number AS c WHERE label = l_call_num AND record = egid AND owning_lib = circ_lib),
  -1
);

update m_gc.asset_copy set circ_modifier = a.code
from config.circ_modifier a
where upper(m_gc.asset_copy.circ_modifier) = upper(a.code);

\echo about to start copying staging values into production tables
BEGIN;
DELETE from action.circulation where target_copy in (select id from asset.copy where circ_lib = 105);
DELETE from asset.copy where circ_lib = 105;
DELETE from asset.copy_location where owning_lib = 105;
\echo inserting copy locations
insert into asset.copy_location
select m_gc.asset_copy_location.*
from m_gc.asset_copy_location
where name not in
(select name
from asset.copy_location
where owning_lib = 105) and name is not null;
-- and maybe 'name is not null'
COMMIT;

BEGIN;
\echo inserting copies
INSERT INTO asset.copy SELECT * FROM m_gc.asset_copy;
\echo inserting call numbers
INSERT INTO asset.call_number SELECT * FROM m_gc.asset_call_number;
COMMIT;

--Clean up bib records after merging has occurred
\echo deleting (logically) merged bibs
BEGIN;
UPDATE biblio.record_entry SET deleted='t' WHERE id IN (SELECT sub FROM m_gc.merge);
COMMIT;

\echo DONE!
