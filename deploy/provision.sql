-- One-time setup of the reminders_ai database on shared_db, run by the owner as
-- the cluster admin. Passwords are passed as psql variables, never stored:
--   docker exec -i shared_db psql -U admin -v ON_ERROR_STOP=1 \
--     -v migrator_pw="$MIGRATOR_PW" -v runtime_pw="$RUNTIME_PW" < provision.sql
--
-- reminders_ai_owner     nonlogin, owns every table and sequence
-- reminders_ai_migrator  runs migrations: SET ROLE reminders_ai_owner (MIGRATION_ROLE)
-- reminders_ai_runtime   the app: DML on the app tables only (granted by 001)
--
-- The backup contract (consolidated-deploy CONTRACTS) expects the owner and
-- migrator without login and the runtime with login. The migrator is given
-- LOGIN only for the length of a migration (see deploy/RUNBOOK.md).

CREATE ROLE reminders_ai_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE reminders_ai_migrator NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
  PASSWORD :'migrator_pw';
CREATE ROLE reminders_ai_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
  PASSWORD :'runtime_pw';
GRANT reminders_ai_owner TO reminders_ai_migrator WITH INHERIT FALSE, SET TRUE;

CREATE DATABASE reminders_ai OWNER reminders_ai_owner;
REVOKE ALL ON DATABASE reminders_ai FROM PUBLIC;
GRANT CONNECT ON DATABASE reminders_ai TO reminders_ai_migrator, reminders_ai_runtime;

\connect reminders_ai
ALTER SCHEMA public OWNER TO reminders_ai_owner;
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO reminders_ai_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE reminders_ai_owner REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
