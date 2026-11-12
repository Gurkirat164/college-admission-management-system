-- Every table now has a primary key. login_attempt was a keyless log: two attempts from the same
-- address and email in the same microsecond were indistinguishable rows. A surrogate identity key
-- makes each attempt addressable without changing how attempts are recorded or counted.
SET search_path = admission, pg_catalog, public;

ALTER TABLE login_attempt
  ADD COLUMN attempt_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY;
