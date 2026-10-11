-- Session table for Sledge::Session::SQLite
CREATE TABLE IF NOT EXISTS sessions (
    id        CHAR(32) NOT NULL PRIMARY KEY,
    a_session TEXT,
    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
