-- sql/init_db.sql
-- OpenGrok Scheduler Schema

-- 1. Configuration Table
CREATE TABLE IF NOT EXISTS config (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    key TEXT UNIQUE NOT NULL,
    value TEXT NOT NULL
);

INSERT OR IGNORE INTO config (key, value) VALUES ('start_time', '18:00');
INSERT OR IGNORE INTO config (key, value) VALUES ('end_time', '06:00');
INSERT OR IGNORE INTO config (key, value) VALUES ('resource_threshold', '70');
INSERT OR IGNORE INTO config (key, value) VALUES ('check_interval', '300');

-- 2. Services Table
CREATE TABLE IF NOT EXISTS services (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    container_name TEXT UNIQUE NOT NULL,
    priority INTEGER DEFAULT 0,
    is_active INTEGER DEFAULT 1
);

-- 3. Jobs Table
CREATE TABLE IF NOT EXISTS jobs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    service_id INTEGER NOT NULL,
    status TEXT NOT NULL CHECK(status IN ('WAITING', 'RUNNING', 'COMPLETED', 'FAILED')),
    start_time DATETIME,
    end_time DATETIME,
    duration INTEGER,
    message TEXT,
    FOREIGN KEY (service_id) REFERENCES services(id)
);
