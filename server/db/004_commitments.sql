-- Commitments the owner accepted on the weekly review site, one row each. The
-- review site sends the accepted set for a week; the iPhone makes a reminder
-- for each active one and reports back the reminder's id and whether it is
-- checked off. `active` turns false when a commitment is un-accepted or its
-- week has been scored: the iPhone then removes the reminder if still open.
CREATE TABLE IF NOT EXISTS rai_commitments (
  user_id uuid NOT NULL REFERENCES rai_users(id) ON DELETE CASCADE,
  week date NOT NULL,
  item_id text NOT NULL CHECK (item_id ~ '^c[1-9]$'),
  text text NOT NULL CHECK (length(text) BETWEEN 1 AND 200),
  measure text CHECK (measure IS NULL OR length(measure) <= 200),
  area text NOT NULL DEFAULT 'other' CHECK (length(area) <= 20),
  active boolean NOT NULL DEFAULT true,
  reminder_id text CHECK (reminder_id IS NULL OR length(reminder_id) BETWEEN 1 AND 255),
  done boolean NOT NULL DEFAULT false,
  completed_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, week, item_id)
);

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'reminders_ai_runtime') THEN
    GRANT SELECT, INSERT, UPDATE, DELETE ON rai_commitments TO reminders_ai_runtime;
  END IF;
END $$;
