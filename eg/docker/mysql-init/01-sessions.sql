-- For the development environment: session table for the sample app and a database for tests
CREATE TABLE IF NOT EXISTS sledge.sessions (
    id CHAR(32) NOT NULL PRIMARY KEY,
    a_session MEDIUMBLOB,
    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

CREATE DATABASE IF NOT EXISTS test;
