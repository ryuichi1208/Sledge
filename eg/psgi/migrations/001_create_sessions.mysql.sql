-- Session table for Sledge::Session::MySQL (sessions are stored as JSON or Storable)
CREATE TABLE IF NOT EXISTS sessions (
    id        CHAR(32) NOT NULL PRIMARY KEY,
    a_session MEDIUMBLOB,
    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);
