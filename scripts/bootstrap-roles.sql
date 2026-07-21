-- Minimal Supabase-like roles, extensions and stub schemas so that a public-schema
-- logical dump restores cleanly into a vanilla Postgres for VERIFICATION only.
-- This is best-effort: extend it per project if your schema uses extra extensions
-- (e.g. postgis, pg_trgm) or references other Supabase-managed objects.

DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY[
    'anon','authenticated','service_role','authenticator',
    'supabase_admin','supabase_auth_admin','supabase_storage_admin',
    'supabase_read_only_user','dashboard_user','pgbouncer'
  ]
  LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('CREATE ROLE %I NOLOGIN', r);
    END IF;
  END LOOP;
END $$;

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Stub schemas/tables that public objects commonly reference via FK/GRANT.
CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS storage;
CREATE TABLE IF NOT EXISTS auth.users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid()
);
