-- Photos the person attaches to a message. Kept on the message row, so they
-- are backed up and deleted with it: [{"id", "mediaType", "data" (base64)}].
ALTER TABLE rai_messages ADD COLUMN IF NOT EXISTS attachments jsonb;
