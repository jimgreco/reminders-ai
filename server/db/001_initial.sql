-- Apply only to the dedicated `reminders_ai` database, as reminders_ai_migrator.
-- Apple Reminders stays the source of truth for the tasks themselves. This
-- database holds only what Reminders cannot: each item's AI thread, the edits
-- the agent has queued for the iPhone to apply, and push tokens.

CREATE TABLE IF NOT EXISTS rai_users (
  id uuid PRIMARY KEY,
  email text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS rai_identities (
  provider text NOT NULL CHECK (provider IN ('apple', 'dev')),
  subject text NOT NULL CHECK (length(subject) BETWEEN 1 AND 255),
  user_id uuid NOT NULL REFERENCES rai_users(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (provider, subject)
);
CREATE INDEX IF NOT EXISTS rai_identities_user_idx ON rai_identities(user_id);

CREATE TABLE IF NOT EXISTS rai_sessions (
  token_hash text PRIMARY KEY CHECK (token_hash ~ '^[0-9a-f]{64}$'),
  user_id uuid NOT NULL REFERENCES rai_users(id) ON DELETE CASCADE,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS rai_sessions_user_idx ON rai_sessions(user_id);

-- One AI thread per reminder. reminder_id is EventKit's
-- calendarItemExternalIdentifier, which is the same on every device.
CREATE TABLE IF NOT EXISTS rai_threads (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES rai_users(id) ON DELETE CASCADE,
  reminder_id text NOT NULL CHECK (length(reminder_id) BETWEEN 1 AND 255),
  title text NOT NULL DEFAULT '',
  agent_session_id text,
  status text NOT NULL DEFAULT 'idle' CHECK (status IN ('idle', 'working', 'needs_input', 'error')),
  pending_tool_use_id text,
  unread boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, reminder_id)
);
CREATE INDEX IF NOT EXISTS rai_threads_working_idx ON rai_threads(status) WHERE status = 'working';

CREATE TABLE IF NOT EXISTS rai_messages (
  id uuid PRIMARY KEY,
  thread_id uuid NOT NULL REFERENCES rai_threads(id) ON DELETE CASCADE,
  seq bigint GENERATED ALWAYS AS IDENTITY,
  role text NOT NULL CHECK (role IN ('user', 'assistant', 'question', 'activity', 'error')),
  text text NOT NULL,
  options jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS rai_messages_thread_idx ON rai_messages(thread_id, seq);

-- Agent session events already handled, so a poll never applies one twice.
CREATE TABLE IF NOT EXISTS rai_seen_events (
  thread_id uuid NOT NULL REFERENCES rai_threads(id) ON DELETE CASCADE,
  event_id text NOT NULL,
  PRIMARY KEY (thread_id, event_id)
);

-- Edits to Apple Reminders that the agent asked for. The server cannot reach
-- Reminders; the iPhone applies each one through EventKit and acknowledges it.
CREATE TABLE IF NOT EXISTS rai_ops (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES rai_users(id) ON DELETE CASCADE,
  thread_id uuid NOT NULL REFERENCES rai_threads(id) ON DELETE CASCADE,
  seq bigint GENERATED ALWAYS AS IDENTITY,
  reminder_id text NOT NULL,
  kind text NOT NULL CHECK (kind IN ('update', 'create', 'complete')),
  payload jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  applied_at timestamptz,
  error text
);
CREATE INDEX IF NOT EXISTS rai_ops_pending_idx ON rai_ops(user_id, seq) WHERE applied_at IS NULL;

CREATE TABLE IF NOT EXISTS rai_devices (
  token text PRIMARY KEY CHECK (token ~ '^[0-9a-f]{64,200}$'),
  user_id uuid NOT NULL REFERENCES rai_users(id) ON DELETE CASCADE,
  sandbox boolean NOT NULL DEFAULT false,
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS rai_devices_user_idx ON rai_devices(user_id);

-- Least-privilege runtime access. Skipped where the role does not exist
-- (tests, local development).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'reminders_ai_runtime') THEN
    GRANT SELECT, INSERT, UPDATE, DELETE ON rai_users, rai_identities, rai_sessions, rai_threads,
      rai_messages, rai_seen_events, rai_ops, rai_devices TO reminders_ai_runtime;
  END IF;
END $$;
