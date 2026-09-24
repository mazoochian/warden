-- What the bot itself did to produce one of its own messages: a compact
-- "name(args) -> result" line per tool call, recorded alongside the reply
-- text and rendered back into the recent-history block as "[used: ...]"
-- so the model can see, on the next turn, which tools it actually called
-- and what they returned -- before this, only the final text was kept, and
-- a reply produced entirely by a side-effecting tool (a message sent, a
-- poll created) left no trace in the history at all. NULL for every
-- inbound message and for replies that used no tool. Never shown to users.
ALTER TABLE messages ADD COLUMN tool_trace TEXT;
