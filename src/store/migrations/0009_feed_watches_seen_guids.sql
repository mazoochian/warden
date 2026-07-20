-- Replaces the single `last_seen_guid` watermark with a bounded set of
-- recently-seen item guids, stored as a JSON array.
--
-- Found live 2026-07-20: the watermark design assumed a feed's <item>s are
-- always strictly newest-first and that the previously-newest item never
-- reappears at the top later. A real feed (iranwire.com's) violates this —
-- it keeps a "featured"/pinned story pinned at position 0 regardless of
-- publish date, while genuinely new items accumulate underneath it. Since
-- the old dedup logic scanned from the top and stopped at the first item
-- matching `last_seen_guid`, a pinned item sitting at position 0 forever
-- made every check report "0 new items", permanently, even with hundreds
-- of new items published beneath it. A set-membership check (is this guid
-- in the snapshot from last time?) is immune to item ordering entirely.
ALTER TABLE feed_watches ADD COLUMN seen_guids_json TEXT;
UPDATE feed_watches SET seen_guids_json = jsonb_build_array(last_seen_guid)::text WHERE last_seen_guid IS NOT NULL;
ALTER TABLE feed_watches DROP COLUMN last_seen_guid;
