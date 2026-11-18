Written by AI on 2026.11.18 by model claude opus 5.5.

# Moving from 0.2.5 to the new app

The new Mac app is a separate app (`<prefix>.AgentKeyring.Mac`) beside 0.2.5
(`<prefix>.AgentKeyring`). Neither reads the other's container, keychain or
update feed. Its first run imports from Apple Passwords like anyone's, so the
logins need no migration. Only the rules do, and carrying them over needs the
owner's leave first: it reads 0.2.5's data and talks to its socket.

## Carrying the rules over

0.2.5 names each rule only by its own login ID, so the rules must be matched to
the new import by site and account. Everything needed is readable without a
prompt and without touching a password (source at tag `v0.2.5`):

1. **The rules.** 0.2.5's container holds
   `Data/Library/Application Support/AgentKeyring/access-policies.json`: plain
   JSON, `{"version": 1, "records": [{"credentialID": UUID, "policy":
   "allowAutomatically" | "block"}]}`. A login with no record is Ask.
2. **Which login each ID is.** 0.2.5's socket answers the JSON request
   `{"action": "resolve", "targetURL": SITE}` with `candidates`: each has
   `id`, `title`, `username` and `origins`. `resolve` raises no approval
   (`MirrorAppModel.process`, case `.resolve`). Ask it once for each site in
   the new import.
3. **Join the two.** For each record, take the candidate with that ID; find the
   new import's login with the same site and account; give it the rule.
   Anything that does not match one login exactly stays Ask, and is listed for
   the owner.
4. **Apply them in the new app** as one rule change: Blocked costs nothing, and
   Automatic logins are sealed to the allowed machines, so the whole change is
   one Touch ID.

Then 0.2.5 can be deleted when the owner says so.
