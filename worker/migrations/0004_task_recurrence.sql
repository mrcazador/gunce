-- Repeating tasks: daily chores and habits. "Teslim et" closes the current period and the
-- task stays open for the next one. NULL = a one-off task (the default).
ALTER TABLE tasks ADD COLUMN recurrence TEXT CHECK (recurrence IN ('daily', 'weekdays', 'weekly'));
