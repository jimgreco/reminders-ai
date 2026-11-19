-- Reminders the person told Plan My Day to leave out: until a time, or for
-- good when dismissed_until is null. Keyed by the Apple Reminders id.
CREATE TABLE IF NOT EXISTS rai_plan_dismissals (
  user_id uuid NOT NULL REFERENCES rai_users(id) ON DELETE CASCADE,
  reminder_id text NOT NULL CHECK (length(reminder_id) BETWEEN 1 AND 255),
  dismissed_until timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, reminder_id)
);

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'reminders_ai_runtime') THEN
    GRANT SELECT, INSERT, UPDATE, DELETE ON rai_plan_dismissals TO reminders_ai_runtime;
  END IF;
END $$;
