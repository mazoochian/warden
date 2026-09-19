# Command reference

`/help` (two messages) is the user-facing reference and is kept in
`main.zig` (`help_text`, `help_text_admin`); `public_commands` is what is
published to Telegram's command menu. `!command` works everywhere as an
alias for `/command`; `/command@botname` is accepted and a qualifier for a
different bot is ignored. Custom shortcuts come from `/alias` and can never
shadow a built-in name (`isReservedCommandName`).

Access column: **any** = anyone in the chat, **admin** =
`checkGroupAdminAccess` (owner / `/sudo` / live platform admin),
**owner** = owner only, **bot admin** = owner or bot admin, **view/owner**
= anyone may view, owner may change.

## Talking to the bot

| Command | Access | Notes |
|---|---|---|
| mention / reply / magic word / DM | owner+bot admins, or anyone if `WARDEN_LLM_OWNER_ONLY=false` | Free-form Q&A with tools |
| `/translate <lang> [text]`, `/rewrite <tone> [text]`, `/eli5 [text]`, `/brainstorm [topic]` | same as Q&A | Messaging modes; fall back to the replied-to message |
| `/joke /riddle /trivia /wordoftheday /motivate` | same as Q&A | |
| `/summary [hours]` | any | Summarises this chat's own logged history; no tool loop |
| `/thinking on\|off\|default` | view/owner | Per-chat override of show-thinking |
| `/persona <text>\|off` | view/owner | Per-chat system prompt |
| `/magicword <word>` | view/owner | |
| `/template save\|use\|list\|delete` | any / creator-or-owner to delete | Saved prompts (`power_tools`) |
| `/cancel` | any | Cancels your pending conversion or menu prompt, else (admin) a pending kick/ban |

## Personal tools

| Command | Access | Notes |
|---|---|---|
| `/remind <time> <msg>`, `every <interval>`, `cancel <id>`; `/reminders` | any / creator-or-owner to cancel | Durations, clock times, dates, weekdays; per-user timezone |
| `/alert <crypto\|weather\|aqi> <subject> <above\|below> <value>`; `/alerts` | any | Standing metric alerts |
| `/watch <url>`, `/unwatch`, `/watches`, `/watchcheck` | any | RSS/Atom |
| `/note add\|list\|delete`, `/notes` | any / creator-or-owner to delete | Caption a voice message with `/note` to save its transcript |
| `/memory list\|forget <id>` | any (own facts only) | Long-term facts about you, across chats |
| `/keyword add\|list\|remove` | any / creator-or-owner | Get pinged when a word appears |
| `/expense add\|list\|summary\|delete`, `/budget set\|list\|remove`, `/subscription add\|list\|remove` | any; budgets view/owner | Finance module, USD only |
| `/poll <q> \| <opt> \| <opt>...` | any | 2–10 options |
| `/convert [<format>]` | any | One-shot with a caption, or the interactive flow |
| `/alias add\|list\|remove` | any / creator-or-owner | Command shortcuts (`power_tools`) |
| `/menu` | any (per-node tiers) | Button-driven front end for every module |
| `/digest on\|off\|now`, `/briefing on\|off\|now` | any | Scheduled summaries / pending-items briefing |
| `/location <place>\|off` | view/owner | Briefing weather |
| `/stats`, `/wordcloud` | any | |

## Chat administration (`group_admin` module)

| Command | Access | Notes |
|---|---|---|
| `/mute /unmute /kick /ban` (reply, `@user` or id) | admin | Kick/ban ask for `/confirm` within `WARDEN_CONFIRM_TIMEOUT_SECONDS` |
| `/pin /unpin /delete` | admin | Reply-based |
| `/redact <N>\|reply [N]\|text <s>\|regex <p>` | admin; regex: owner or `/sudo` | Bulk delete from local history |
| `/slowmode <seconds>\|off` | admin | Warden's own cooldown; enforced by deleting on Telegram/Matrix |
| `/permission [<dur>] <+\|-><letters> <@user>` | admin | Partial enforcement, stated in the reply |
| `/tag @user <text>\|off` | admin | Telegram custom title; admins only |
| `/promote /demote` | owner | Never delegated |
| `/welcome <text>\|off` | view/owner | `{name}` placeholder |
| `/photo`, `/title`, `/description` | admin | |
| `/announce <text>`, `at <time>`, `every <interval>`, `list`, `cancel` | admin | Pinned broadcasts |
| `/autopin on\|off`, `/silent on\|off`, `/videodownload on\|off`, `/videoquality lossy\|lossless` | admin | |
| `-s` / `-p` flag on the above | — | Skip / force the in-group confirmation |
| `/whois [@user\|id]`, `/chatinfo [native id]` | bot admin / admin | Lookups |

## Management rooms

| Command | Access | Notes |
|---|---|---|
| `/manage bind\|unbind <chat id>`, `/manage list` | owner or live admin of the target | 1:1 binding |
| `/as <chat id> <command>` | owner or live admin of the target | Relays one command; replies come back here |
| bare relayable command in a bound room | same | No prefix needed |

## Bot-wide (hidden from the public menu)

| Command | Access | Notes |
|---|---|---|
| `/addadmin /removeadmin` | bot admin | Reply, `@user` (queued if unseen) or id |
| `/blockuser /unblockuser` | bot admin | Owner/bot admins can't be blocked |
| `/blockchat /unblockchat` | bot admin | Whole chat |
| `/sudo <command>` | bot admin | Announced elevation |
| `/scraper` | bot admin | Local vs remote scraping backend |
| `/storage status\|autopilot\|cleanup ...` | owner | Storage Sense |
| `/tdlogin /tdlogout /tdchats /tdsearch /tdsend /tdsummary /sendas` | owner | Personal Telegram account |
| `/autonomy off\|draft\|auto [prompt ...]`, `/drafts`, `/approve`, `/discard` | owner | Reply autonomy |
| `/iglogin ...` | owner | Instagram |
| `/feed ...` | owner | Curated feed |
