-- Session table for Sledge::Session::Pg; last_access is used by session cleanup
CREATE TABLE IF NOT EXISTS sessions (
    id          CHAR(32) NOT NULL PRIMARY KEY,
    a_session   TEXT,
    last_access TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE OR REPLACE FUNCTION sledge_sessions_touch() RETURNS trigger AS $$
BEGIN
    NEW.last_access := CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS sessions_touch ON sessions;
CREATE TRIGGER sessions_touch BEFORE INSERT OR UPDATE ON sessions
    FOR EACH ROW EXECUTE FUNCTION sledge_sessions_touch();
