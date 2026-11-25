-- Restore an installation administrator who can sign in, directly in the
-- database: for when nobody who administers the installation can sign in.
--
-- No application code runs (it is protected and not run by hand). The account
-- gets the installation-admin flag and a one-use link, valid for an hour, that
-- its holder opens at https://<host>/password/<token> to set the password; the
-- application checks the password policy and stores the hash. Only the
-- SHA-256 of the token is written here, as the application stores every link.
--
-- An existing account keeps its teams: its password is cleared (which ends
-- its sessions), its personal repository keys are revoked, and it is made
-- active. An account that signs in through single sign-on is refused: an
-- account signs in one way only, so name a new one.
--
-- Variables (psql -v):
--   username    the account to restore or create
--   token_hash  sha256 of the token, 64 lowercase hex digits
--   team_slug   the installation's own team (DEFAULT_TEAM_SLUG, normally
--               "default"); the link is filed under it, and any team serves
--
-- On a Docker Compose host:  ./scansuite recover <username>
-- Elsewhere (Cloud SQL):     docs/reference/platform-administration.md, "Locked out"

\set ON_ERROR_STOP on

BEGIN;

-- The DO block below cannot read psql variables, so they go through
-- transaction settings. \gset keeps the result off the screen.
SELECT set_config('scansuite.recover_username', :'username', true) AS username,
       set_config('scansuite.recover_token_hash', :'token_hash', true) AS token_hash,
       set_config('scansuite.recover_team_slug', :'team_slug', true) AS team_slug \gset recover_

DO $$
DECLARE
    name text := current_setting('scansuite.recover_username');
    hash text := current_setting('scansuite.recover_token_hash');
    account integer;
    team integer;
BEGIN
    IF name !~ '^[A-Za-z0-9][A-Za-z0-9._@-]{1,99}$' THEN
        RAISE EXCEPTION 'Invalid user name "%": 2 to 100 letters, digits, dots, hyphens, underscores or @', name;
    END IF;
    IF hash !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'token_hash must be the SHA-256 of the token: 64 lowercase hexadecimal digits';
    END IF;
    SELECT id INTO account FROM users WHERE lower(username) = lower(name);
    IF account IS NOT NULL AND EXISTS (SELECT 1 FROM auth_identities WHERE user_id = account) THEN
        RAISE EXCEPTION 'The account "%" signs in through single sign-on; name a new account for recovery', name;
    END IF;
    SELECT id INTO team FROM teams WHERE status <> 'deleted'
        ORDER BY (slug = current_setting('scansuite.recover_team_slug')) DESC, id LIMIT 1;
    IF team IS NULL THEN
        RAISE EXCEPTION 'The installation has no team yet: open https://<host>/setup to create the first account';
    END IF;

    IF account IS NULL THEN
        INSERT INTO users(username, password, is_active, installation_admin)
            VALUES (name, '', true, true) RETURNING id INTO account;
    ELSE
        UPDATE users SET password = '', is_active = true, installation_admin = true WHERE id = account;
        UPDATE user_secret_versions SET revoked = true, revoked_at = now() WHERE user_id = account AND NOT revoked;
    END IF;

    DELETE FROM password_setup_links WHERE user_id = account AND used_at IS NULL;
    INSERT INTO password_setup_links(id, user_id, team_id, purpose, token_hash, expires_at)
        VALUES (md5(random()::text || clock_timestamp()::text), account, team, 'reset', hash,
                now() + interval '1 hour');

    INSERT INTO audit_events(team_id, actor_kind, action, target_id, detail, actor_label)
        VALUES (NULL, 'system', 'installation.admin.recover', account::text,
                json_build_object('username', name), 'recovery');

    RAISE NOTICE 'Recovery prepared for "%" (account %): the link is valid for one hour', name, account;
END
$$;

COMMIT;
