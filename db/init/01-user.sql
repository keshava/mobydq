/*Connect to database*/
\connect mobydq



/*Create function to get Id of the current user based on his database user role*/
/*This is used to update the created_by_id and updated_by_id columns*/
CREATE OR REPLACE FUNCTION base.get_current_user_id()
RETURNS INTEGER AS $$
DECLARE
    user_id INTEGER;
BEGIN
    IF CURRENT_USER LIKE 'user_%' THEN
      SELECT SUBSTRING(CURRENT_USER, 6) INTO user_id;
    ELSE
      SELECT 1 INTO user_id;
    END IF;
    RETURN user_id;
END;
$$ language plpgsql;

COMMENT ON FUNCTION base.get_current_user_id IS
'Function used to get Id of the current user based on his database user role.';



/*Create table user*/
CREATE TABLE base.user (
    id SERIAL PRIMARY KEY
  , email TEXT NOT NULL UNIQUE
  , password TEXT
  , role TEXT NOT NULL DEFAULT 'standard'
  , flag_active BOOLEAN DEFAULT TRUE
  , created_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP
  , updated_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP
  , created_by_id INTEGER DEFAULT base.get_current_user_id()
  , updated_by_id INTEGER DEFAULT base.get_current_user_id()
);

COMMENT ON TABLE base.user IS
'Users information.';

/*Add circular reference to user table*/
ALTER TABLE base.user ADD CONSTRAINT user_created_by_id_fkey FOREIGN KEY (created_by_id) REFERENCES base.user(id);
ALTER TABLE base.user ADD CONSTRAINT user_updated_by_id_fkey FOREIGN KEY (updated_by_id) REFERENCES base.user(id);

CREATE TRIGGER user_update_updated_date BEFORE UPDATE
ON base.user FOR EACH ROW EXECUTE PROCEDURE
base.update_updated_date();



/*Create function to hash password column*/
CREATE OR REPLACE FUNCTION base.hash_password()
RETURNS TRIGGER AS $$
BEGIN
    NEW.password = crypt(NEW.password, gen_salt('bf', 8));
    RETURN NEW;
END;
$$ language plpgsql;

COMMENT ON FUNCTION base.hash_password IS
'Function used to hash password when creating a user.';

/*Triggers must be created before inserting default user below to ensure password is hashed*/
CREATE TRIGGER user_hash_password BEFORE INSERT
ON base.user FOR EACH ROW EXECUTE PROCEDURE
base.hash_password();



/*Create composite type to generate JWT*/
CREATE TYPE base.token AS (
    email TEXT,
    role TEXT,
    aud TEXT  --audience
);

/*Create function to authenticate users*/
CREATE OR REPLACE FUNCTION base.authenticate_user(user_email TEXT, user_password TEXT)
RETURNS base.token AS $$
DECLARE
    user_account base.user;
BEGIN
    SELECT a.*
    INTO user_account
    FROM base.user a
    WHERE a.email = user_email
    AND flag_active = true;

    IF user_account.password = crypt(user_password, user_account.password) THEN
        RETURN (
            user_account.email,  --email
            'user_' || user_account.id,  --role
            'postgraphile'  --audience
        )::base.token;
    ELSE
        RETURN NULL;
    END IF;
END;
$$ language plpgsql strict security definer;

COMMENT ON FUNCTION base.authenticate_user IS
'Function used to authenticate users.';



/*Create default user*/
/*User is required to be able to create the default user group later*/
/*Must be created before other triggers to avoid conflicts*/
INSERT INTO base.user (email, password, role) VALUES ('admin', 'admin', 'admin');
CREATE ROLE user_1 WITH CREATEROLE;



/*Create function to update updated_by_id column*/
CREATE OR REPLACE FUNCTION base.update_updated_by_id()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_by_id = base.get_current_user_id();
    RETURN NEW;
END;
$$ language plpgsql;

COMMENT ON FUNCTION base.update_updated_by_id IS
'Function used to automatically update the updated_by_id column in tables.';

CREATE TRIGGER user_updated_by_id BEFORE UPDATE
ON base.user FOR EACH ROW EXECUTE PROCEDURE
base.update_updated_by_id();



/*Create function to create database user in pg_roles table when user is created in user table*/
CREATE OR REPLACE FUNCTION base.create_user()
RETURNS TRIGGER AS $$
BEGIN
    -- Create database user
    EXECUTE 'CREATE ROLE user_' || NEW.id || ' WITH CREATEROLE';

    -- Grant permission
    EXECUTE 'GRANT ' || NEW.role || ' TO user_' || NEW.id;

    -- Assign default user group
    INSERT INTO base.user_group_user (user_id) VALUES (NEW.id);
    RETURN NEW;
END;
$$ language plpgsql;

COMMENT ON FUNCTION base.create_user IS
'Function used to automatically create a database user in pg_roles tables when user is created in user table.';

CREATE TRIGGER user_create_user AFTER INSERT
ON base.user FOR EACH ROW EXECUTE PROCEDURE
base.create_user();



/*Create function to update user permissions in pg_roles table*/
CREATE OR REPLACE FUNCTION base.update_user_permission()
RETURNS TRIGGER AS $$
BEGIN
    -- Update permission
    IF OLD.role <> NEW.role THEN
        -- Revoke permission
        EXECUTE 'REVOKE ' || OLD.role || ' FROM user_' || OLD.id;

        -- Grant permission
        EXECUTE 'GRANT ' || NEW.role || ' TO user_' || NEW.id;
    END IF;
    RETURN NEW;
END;
$$ language plpgsql;

COMMENT ON FUNCTION base.update_user_permission IS
'Function used to automatically update permissions of a user in pg_roles table.';

CREATE TRIGGER user_update_user_permission BEFORE UPDATE
ON base.user FOR EACH ROW EXECUTE PROCEDURE
base.update_user_permission();
