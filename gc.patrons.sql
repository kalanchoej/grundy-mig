BEGIN;

-- Create staging table.
CREATE TABLE m_gc.patrons (
	patron_id int, barcode text, last_name text, first_name text, email text, address_type text, street1 text, street2 text, 
	city text, province text, country text DEFAULT 'US', postal_code text, phone text, profile int DEFAULT 14, 
	ident_type int DEFAULT 3, home_ou int DEFAULT 105, claims_returned_count int DEFAULT 0, usrname text, 
	net_access_level int DEFAULT 2, password text, l_profile text
); 

--Copy records from your import text file
COPY m_gc.patrons (patron_id, l_profile, last_name, first_name, email, address_type, street1, street2, city, province, country, postal_code, phone, password) 
	FROM '/mnt/evergreen/migration/GrundyFinal/data/patrons.csv' 
		WITH CSV HEADER;  

-- Make a table to map grundy patron types to eg values
CREATE TABLE m_gc.patrons_profile_map (
	old text,
	new text
);
\copy m_gc.patrons_profile_map FROM /mnt/evergreen/migration/GrundyFinal/patron_profile_map.txt

-- update the profile values with the EG values from the mapping table
UPDATE m_gc.patrons a
  SET l_profile = b.new
  FROM m_gc.patrons_profile_map b
  WHERE a.l_profile = b.old;

-- Move the text values into the intervalues matching from the production table
UPDATE m_gc.patrons a
  SET profile = b.id
  FROM permission.grp_tree b
  where a.l_profile = b.name;

-- Give the usrname column the barcode value...
UPDATE m_gc.patrons
  SET usrname = patron_id;

UPDATE m_gc.patrons
  SET barcode = patron_id;

UPDATE m_gc.patrons
  SET password = patron_id;

UPDATE m_gc.patrons SET phone = regexp_replace(phone, '[^\d-]', '', 'g');

--Insert records from the staging table into the actor.usr table.
INSERT INTO actor.usr (
	profile, usrname, email, passwd, ident_type, ident_value, first_given_name, family_name, 
	day_phone, home_ou, claims_returned_count, net_access_level) 
	SELECT profile, patrons.usrname, email, password, ident_type, patron_id, first_name, 
	last_name, phone, home_ou, claims_returned_count, net_access_level FROM m_gc.patrons;

--Insert records from the staging table into the actor.usr table.
INSERT INTO actor.card (usr, barcode) 
	SELECT actor.usr.id, m_gc.patrons.barcode 
	FROM m_gc.patrons 
		INNER JOIN actor.usr 
			ON m_gc.patrons.usrname = actor.usr.usrname;

--Update actor.usr.card field with actor.card.id to associate active card with the user:
UPDATE actor.usr 
	SET card = actor.card.id 
	FROM actor.card 
	WHERE actor.card.usr = actor.usr.id;

--INSERT records INTO actor.usr_address from staging table.
INSERT INTO actor.usr_address (usr, street1, street2, city, state, country, post_code) 
	SELECT actor.usr.id, m_gc.patrons.street1, m_gc.patrons.street2, m_gc.patrons.city, m_gc.patrons.province, 
	m_gc.patrons.country, m_gc.patrons.postal_code 
	FROM m_gc.patrons 
	INNER JOIN actor.usr ON m_gc.patrons.usrname = actor.usr.usrname;


--Update actor.usr mailing address with id from actor.usr_address table.:
UPDATE actor.usr 
	SET mailing_address = actor.usr_address.id, billing_address = actor.usr_address.id 
	FROM actor.usr_address 
	WHERE actor.usr.id = actor.usr_address.usr;

COMMIT;
