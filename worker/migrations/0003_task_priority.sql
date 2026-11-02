-- Task size ("öncelik"): 1 ufak, 2 orta, 3 büyük. It decides how grand the task's building
-- is in Şehir. Existing tasks become orta.
ALTER TABLE tasks ADD COLUMN priority INTEGER NOT NULL DEFAULT 2 CHECK (priority BETWEEN 1 AND 3);
