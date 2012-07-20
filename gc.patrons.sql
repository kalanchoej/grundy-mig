BEGIN;

-- Create staging table.
CREATE TABLE patrons (
	patron_id int, barcode text, last_name text, first_name text, email text, address_type text, street1 text, street2 text, 
	city text, province text, country text, postal_code text, phone text, profile int, 
	ident_type int, home_ou int, claims_returned_count int DEFAULT 0, usrname text, 
	net_access_level int DEFAULT 2, password text
); 

--Copy records from your import text file
COPY patrons (patron_id, last_name, first_name, email, address_type, street1, street2, city, province, country, postal_code, phone, password) 
	FROM 'data/patrons.csv' 
		WITH CSV HEADER;  


--Insert records from the staging table into the actor.usr table.
INSERT INTO actor.usr (
	profile, usrname, email, passwd, ident_type, ident_value, first_given_name, family_name, 
	day_phone, home_ou, claims_returned_count, net_access_level) 
	SELECT profile, patrons.usrname, email, password, ident_type, patron_id, first_name, 
	last_name, phone, home_ou, claims_returned_count, net_access_level FROM patrons;

--Insert records from the staging table into the actor.usr table.
INSERT INTO actor.card (usr, barcode) 
	SELECT actor.usr.id, patrons.barcode 
	FROM patrons 
		INNER JOIN actor.usr 
			ON patrons.usrname = actor.usr.usrname;

--Update actor.usr.card field with actor.card.id to associate active card with the user:
UPDATE actor.usr 
	SET card = actor.card.id 
	FROM actor.card 
	WHERE actor.card.usr = actor.usr.id;

--INSERT records INTO actor.usr_address from staging table.
INSERT INTO actor.usr_address (usr, street1, street2, city, state, country, post_code) 
	SELECT actor.usr.id, patrons.street1, patrons.street2, patrons.city, patrons.province, 
	patrons.country, patrons.postal_code 
	FROM patrons 
	INNER JOIN actor.usr ON patrons.usrname = actor.usr.usrname;


--Update actor.usr mailing address with id from actor.usr_address table.:
UPDATE actor.usr 
	SET mailing_address = actor.usr_address.id, billing_address = actor.usr_address.id 
	FROM actor.usr_address 
	WHERE actor.usr.id = actor.usr_address.usr;

COMMIT;
