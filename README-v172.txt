ChatBox v172 — full-app audit, bug fixes & upgrades (base v171, live version)
Release: 20 November 2026, 13:36 (Asia/Dhaka) — sw chatbox-v172
NO SQL ships with this version (supabase-v172.sql is a DRAFT for approval — see §8).
Call block byte-identical (md5 63e54beeafa890f9383ad9195ab78c61).
Base v171 untouched (index md5 7525f68041765a8998899f54369bccfb, re-checked after the build).

================================================================
RELEASE FACTS
================================================================
- index.html: md5 44c9fa3e3430e9c8f4a52e4133b04edc, 39,998 lines, 2,588,638 bytes
- sw.js: md5 66c15007192e59a66ce5ed8d25735457, CACHE_NAME chatbox-v172
- supabase-v172.sql: md5 8a57a820a57af1cc17e546732565c10f, 1,264 lines (DRAFT — not run)
- icon-maskable-512.png: md5 883da5f8c59146e060b2dcdfcb1f285c (rebuilt — see F-04, §2.7)
- Version stamp: __CHATBOX_VERSION__ = 'v172', __CHATBOX_RELEASE_DATE__ = '20 November 2026, 13:36'
- Audit: 7 areas, 75 NEW findings (P0: 0 · P1: 13 · P2: 62). Of the 75, 50 are
  FIXED in the shipped file (47 by the fix rounds + 3 coordinator stamp jobs:
  F-02 version stamp, F-04 sw.js cache name, G-07 stamp/sw header) and 25 are
  NOT FIXED — every one of them is listed with its reason in §3.
- The seven fix rounds applied 54 fixes (auth 8, inbox 12, DM 5, groups 8,
  games 7, notif 5, perf 9 — counts as reported by each fixer, including the
  v168 re-audit items they closed: P2-10, P2-11, F-03, F-04, F-10, F-11, G-06,
  F13-partial, P2-8, F-08, F-04-icon). G-6 (expired game rows prune/delete)
  is NOT reverted or expanded. Bot difficulty is untouched (see §5).
- Quota: v169's traffic cuts are fully preserved; no new polling, no new
  request volume (see §6). Load time unchanged (see §7).

================================================================
§1 DIAGNOSIS — the 18 Nov live inbox disappearance (Abir, Arif, Aditi, Arko)
================================================================
Observed (once, not reproduced): ~19:08 the All list showed chats for Abir,
Arif, Aditi, Arko (plus five others). After switching to the Unread filter
and back, those four vanished and did not return after two Refreshes or a
reload, and were not in Archived either. Scrolling briefly duplicated the
five visible chats. The Unread result was empty both times. Arif, Aditi,
Arko are not in the known-contacts list for the @muse test account (known:
Abir, Samia, Alif, Forhad, Nafis, Alvi, Asad, Sadibul).

What the code can and cannot explain:

1. The first paint was almost certainly the SEEDED CACHE, not the live sync.
   startApp() paints v151SeedInboxFromCache() synchronously BEFORE refreshAll()
   runs. The seed reads chatbox_inbox_recent_<me.id> (up to 20 cached detail
   rows) plus the self-chat cache and renders them with no network fetch at
   all. So "they were there at 19:08" proves only that they were in that
   account's localStorage cache from an earlier session — it does not prove
   they were in the live conversations table at 19:08. The fresh sync behind
   the seed then replaces the paint.

2. Cross-account cache paint is UNLIKELY. All three inbox cache keys are
   scoped by the signed-in user id (chatbox_inbox_recent_<me.id>,
   chatbox_selfchat_<me.id>, chatbox_v5_<me.id>), and the seed refuses to run
   without me. A different account's inbox could only paint if the keys
   collided, which requires the same me.id. The simpler reading is that the
   four chats ARE real conversations of the @muse account that the
   human-maintained "known contacts" list does not include (e.g. created by
   exact-username startChat, or from an earlier test session) — the contact
   list is a human list, not a server query, and it is the weakest premise.

3. The vanish itself has one code path that fits every observed detail: the
   NULL-DETAIL DROP (B-03). Switching filters calls setInboxView() ->
   inboxRebuildWindow({reset:true}) -> inboxEnsureShown(). There, a detail
   that comes back null is skipped (if(!details[i]) continue) in EVERY view
   — All, Unread, Favorites, Groups, Archived. A detail comes back null when
   its 8 s v155Race times out or its fetch throws. inboxFetchDetails() reuses
   a cached detail only when its last-message time still matches the fresh
   index; if the index time moved, a fresh fetch is required, and that fetch
   is slow by construction (sequential message_meta loop, up to 10 serial
   queries, plus profile + clears). On a slow connection the four chats'
   fetches can time out while the other five succeed — exactly a partial
   vanish. Two Refreshes repeat the same failing fetches, and a reload
   re-paints the seed and then immediately replaces it with the same failing
   rebuild, so the user looking after the replacement sees the same absence.
   This also explains: not in Archived (the same null-drop hides it there
   too — a genuinely archived row with a healthy fetch WOULD show); Unread
   empty both times (those chats had no unread, or null, and the Unread scan
   skips both); and it is NOT a v5.deleted effect (B-01 proves v5.deleted is
   not consulted by the list renderer at all, so a delete could not hide
   them — the delete path is ruled out as the cause). Block/archive as the
   cause is contradicted for the same reason (blocked rows show in the
   Blocked section, archived rows show in Archived, when their fetch is
   healthy).

4. The main competing theory is a genuinely MISSING/PARTIAL FRESH INDEX —
   and code alone cannot separate it from (3). inboxLoadIndex() replaces
   inboxIndex wholesale. If the conversations query returned without those
   four rows (RLS, a partial/failed response, or the rows genuinely not
   existing server-side), every subsequent view would lack them in exactly
   the same way, and the seeded cache would be the only trace. The code gives
   no way to distinguish "index missing the rows" from "details timed out
   for the rows" after the fact.

5. The scroll duplication is a SEPARATE, weaker signal. There is no scroll
   listener that loads more rows — Load more is a button only. The plausible
   path is a race between inboxAppendShown() and a concurrent full
   renderChats() (slice boundaries no longer match the DOM, already-rendered
   rows appended a second time). The inboxGen guard protects against a newer
   rebuild, but a render triggered without a gen bump is not excluded. This
   is a hypothesis, not a proof — it could equally be the v102-tab-swap
   animation class or a rendering artefact. It is not, on its own, evidence
   for any particular vanish mechanism.

DIAGNOSIS (confidence LOW–MEDIUM): the four chats were most likely real rows
in the seeded localStorage cache, and after the filter switch the fresh
rebuild dropped them because their detail fetches returned null (most
plausibly 8 s timeouts on the slow, sequential detail path), while the other
five chats' fetches succeeded. The same failure then repeated on Refresh and
on reload. The "not known contacts" premise most likely reflects an
incomplete contact list rather than a cross-account cache leak. The competing
"fresh index genuinely lacked the rows" theory fits the same observations and
cannot be excluded from code alone. NO fix is proposed for the quirk itself —
the only fix that touches it is B-03 (never silently drop a null-detail row),
which is justified independently as a defect, not as a proven cure for this
incident. B-03 also adds the diagnostic the next occurrence needs: the
per-rebuild null-detail count + ids are now logged (console.warn with kind +
id, in _v172NullDetailIds), and the failed id gets exactly one bounded
re-fetch on the next light check.

What would settle it (next occurrence, before any Refresh): (1) dump
localStorage keys chatbox_inbox_recent_<me.id>, chatbox_selfchat_<me.id>,
chatbox_v5_<me.id> — were the four chats in the seed, and what were their
v5.archived / v5.blocked / v5.deleted flags? (2) Console + network capture
during All -> Unread -> All: the conversations response (do the four
conversation ids appear?), and per-chat inboxFetchDetails outcomes (cached
reuse vs fresh fetch vs null after the 8 s race) with the chat ids. (3)
Server-side check: conversations rows where the @muse user id is user_a /
user_b against the profile ids for Arif, Aditi, Arko and Abir — do the four
conversations exist server-side at all?

================================================================
§2 WHAT CHANGED — reasoning + fix, by area
================================================================
§2.1 Auth & security (8 fixed: A-02, A-04, A-05, A-06, A-07, A-08, P2-10, P2-11)
- A-02 (P1) Exact-username search used select('*') — six sites now select the
  7 slim columns (id, display_name, username, avatar_url, avatar_color,
  avatar_emoji, last_seen). profileToUser defaults every omitted field, so the
  render is unchanged. (Also: profiles select('*') count fell 15 -> 9
  file-wide — the 6 removed were A-02's.)
- A-04 (P2) downloadMedia fetched before validating the scheme — now rejects
  non-http(s)/non-blob URLs with "File unavailable." before fetch. blob:
  view-once URLs stay allowed.
- A-05 (P2) Story viewer took raw style strings — bg must now be in STORY_BGS,
  story_filter one of the six picker values, text_color a #rrggbb hex.
- A-06 (P2) Call peer avatar_color unsanitised — one sanitise line in the
  post-block v117 showCallUI wrapper, AFTER the peer resolves. The frozen
  call block is byte-identical.
- A-07 (P2) Lockout gave no notice to the locked-in user — a one-time toast
  now says logins are paused but this session stays signed in. Deliberately
  does NOT force-sign-out the live session (a false positive would lock the
  legitimate owner out). Full enforcement needs the server lockout (§8 §1).
- A-08 (P2) Forgot-reset success text implied other sessions were revoked —
  it now says honestly they may stay signed in. Server half is spec'd in
  supabase-v172.sql §1 §4a.
- P2-10 (P2, v168 re-audit) Self-chat header had no "You" label — now appends
  " · You" via the same v142IsSelfChat() helper the header already uses.
- P2-11 (P2, v168 re-audit) Watch Together was hidden in self-chat only on
  the games attach page — now hidden on EVERY attach page in self-chat.
- NOT FIXED: A-01 (pre-auth security-event insert forgery) and A-03 (story
  delete with no server consumer) — client cannot fix either; SQL/Edge
  Function drafts in supabase-v172.sql §1. P1-01 (server lockout), P2-03,
  P2-05 — same drafts. P2-08 (logout teardown gaps) parked as risky to touch
  from outside the frozen call block. P2-12 (recovery-code guarantees) needs
  Edge Function source that does not ship in this folder.

§2.2 Inbox & search (12 fixed: B-01..B-08, F-03, F-04, F-10, F-11)
- B-01 (P1) "Delete chat" didn't delete — inboxDeriveEntries() now filters
  v5.deleted out of base. (This is also what rules out delete as the cause
  of the 18 Nov quirk — see §1.)
- B-02 (P1) In-chat search rendered newest-first — both branches now
  .slice().reverse() before render, so the newest-200 window reads
  oldest→newest like a normal chat (day separators and v93SearchNav order
  restored). Query, banner and scrollTop unchanged.
- B-03 (P1) Null detail silently deleted the chat from every view — a null
  detail now keeps its row: the stale cached detail if one exists, else a
  minimal placeholder built from the index (other.display_name 'Chat',
  unread 0; the name fills in via inboxRefreshVisibleProfiles on the same
  rebuild). The failed id is queued for exactly ONE re-fetch on the next
  light check (merged into the existing changed-row loops; consumed there,
  so a still-failing id does not retry every tick). Unread view still skips
  unread-unknown placeholders. No new polling, no raised timeout. Also the
  §1 quirk diagnostic (per-rebuild null-detail log) and the exclusion of
  placeholders from the offline seed cache.
- B-04 (P2) Global search surfaced hidden-for-me messages — doGlobalSearch()
  now drops them (1-to-1 via getHiddenForMe(), groups via
  v161GetGroupHiddenForMe()), agreeing with searchInChat().
- B-05 (P2) Inbox search never searched group message text — one extra
  group_messages ilike query per debounced search (same shape/limit 200 as
  the 1-to-1 leg), plus a shared _v172GrpMatch() helper so Groups, All,
  Unread and Favorites match groups by name OR message text.
- B-06 (P2) False "Showing the newest 30 matches" note — _trunc168 is now
  computed from the FILTERED merged list.
- B-07 (P2) Group-member searches shared one debounce timer — new
  groupInfoSearchTimer for searchGroupInfoMembers(); searchGroupMembers()
  keeps groupSearchTimer.
- B-08 (P2) Group badge could resurrect after opening — v151ClearGroupUnreadLocal()
  now also advances the local group read position (v80MarkGroupRead), so the
  next index load cannot recompute the old count when the open's server-side
  mark never lands.
- F-03 (P2, v168) Badge survived Clear chat — on a successful chat_clears
  upsert, doChatClear() zeroes the loaded detail's unread + inboxUnreadCounts
  and advances the local read-max past the newest message id.
- F-04 (P2, v168) Blocked sender not suppressed on receive — the subscribeList
  messages-INSERT handler now skips streak/notify/unread-bump for blocked
  senders. markDelivered is unchanged (invisible to the user).
- F-10 (P2, v168) Timed-out detail -> "All messages read" — fixed via B-03
  (same code path, now wider than v168 reported: all views, not just Unread).
- F-11 (P2, v168) Double space in Last-seen — hours branch '  hours ago' ->
  ' hours ago'.
- NOT FIXED: B-09 (community + announcement group render as two rows) —
  parked, needs an intent decision (the duplication may be deliberate).
  F-09 (scale caps + N+1 in detail path) — unsafe to change client-side;
  needs a dedicated server-side perf pass.

§2.3 DM & media (5 fixed: C-05, C-10, C-11, C-12, C-13)
- C-05 (P2) Peer's unsend only surfaced on the fallback poll — up to 60 s
  when Realtime is healthy (v169 adaptive tick), long enough to screenshot /
  reply / forward a message that should already be gone. The v44
  subscribeList rewrite now restores the v43 message_meta UPDATE binding
  (same shape, same routing: re-read the row, enrich, refreshExistingMessage
  removes it). Zero extra requests beyond the one re-read the v43 handler
  already did, only when an unsend actually arrives. Still needs message_meta
  in the Realtime publication — if absent, the 60 s bound stands (see §8).
- C-10 (P2) Unsend left the starred snapshot behind — refreshExistingMessage()
  now prunes it (DM + group live + group refresh reconciliation, which also
  removes a row a peer unsent that the Realtime handler missed).
- C-11 (P2) A seeded snapshot could resurrect an unsent message for 7 days —
  new V168_MSG_CACHE_SEED_MAX_MS (24 h): v168SeedOpenChatFromCache() refuses
  snapshots older than 24 h and filters out rows already flagged deleted.
  No new requests (the stronger variant — re-checking message_meta per seed —
  was NOT taken, per the quota rule).
- C-12 (P2) "Delete for me only" toast implied a sync that doesn't exist —
  both toasts now read "Hidden on this device only". The hide itself is
  unchanged (localStorage-only). Full per-account sync needs SQL —
  supabase-v172.sql §2 (hidden_messages table + client contract). DELIBERATE
  wording change, flagged (see §5).
- C-13 (P2) Pin fetch kept the OLDEST 100 — v161LoadPins() now orders
  pinned_at descending (keeps the 100 newest), reverses back for storage,
  and merges instead of overwriting when the fetch is complete.
- NOT FIXED: C-01, C-02, C-03, C-14 — SQL/Edge-Function-owed, drafts in
  supabase-v172.sql §2 (storage deletion, group view-once per-member views,
  expired-story queue, disappearing-message hard delete). C-04, C-06, C-07,
  C-08, C-09, C-15..C-24 — out of scope for this fix round (temp-bubble Pin
  guard; 25-day retention notice; message length cap; 15-min edit-window
  server enforcement; link-preview deployment; storyPrev dead-end; cached
  story strip dead rings; story viewer image error; view-once close-watcher;
  view-once 60 s cap vs long video; postStory double-submit; failed story
  post orphans Storage file; document upload type check; camera/preview
  view-once into self-chat; upload progress). Left as audited.

§2.4 Groups & calls (8 fixed: D-01..D-05, D-07, D-08, D-09; + G-06, F13 partial)
- D-02 (P1) Subscribe-add branch could stall on a dead subscriber PC — now
  await waitConnected(subPc, CONNECT_TIMEOUT_MS) after renegotiate, before
  flushEarlyTracks(). A failed add resets the PC and the 10 s reconcile
  rebuilds it.
- D-04 (P1) A stale call row kept a stranded client in a dead call — after
  the existing row-gone eject, checkCallRowAlive now also ejects when the
  active row's id differs from the client's (toast + leaveCall; cannot end
  the new row).
- D-01 (P2) Community member list ⋮ showed on the creator row — same rule as
  the group list: !isCreator && (own || admin).
- D-03 (P2) Seen avatars went stale — v168RefreshSeenAvatars() now also runs
  from the existing v44ForegroundRefresh heavy leg (returning to a group
  refreshes avatars at once, no new timer/request type). Stale "5 s tick"
  comments corrected to the v169 adaptive tick (60 s healthy / 5 s degraded).
- D-05 (P2) Dead _iceCache and _pendingMids removed (init + two resets; grep
  confirmed no other references).
- D-07 (P2) Early-track queue bound 8 -> 32 (one entry per participant) and
  flushEarlyTracks now schedules one subscribe retry if any event was
  re-queued, instead of waiting for the next 10 s reconcile.
- D-08 (P2) Forwarding a game / game-result / group-call-invite inserted a
  broken card — all three forward functions now refuse those types with a
  toast ("Games and group-call invites cannot be forwarded — start a new one
  in that chat instead."), next to the existing poll refusal. DM->DM forward
  (doForward) does NOT get this refusal — the audit scoped D-08 to the three
  group functions only; changing DM forward is out of scope (open question,
  see §DECISIONS).
- D-09 (P2) Call sheet showed an empty list / 00:00 timer for an unconnected
  call — showSheet() moved to just before S.state = 'in-call' (after publish
  succeeds). hideSheet() in catch kept as a backstop.
- G-06 (P2, v168 re-audit) Pure rename inside v161GroupEditSave: gid ->
  msgId (behaviour identical).
- F13 (P2, v168 re-audit) PARTIALLY FIXED: the wrong-group half — refreshBanner's
  in-call branch now hides the banner when another group is open. The
  chat-list return-pill half is NOT FIXED — it needs new UI (no group-call
  equivalent of the 1-to-1 #callMiniBar pill exists); still owed.
- NOT FIXED: D-06 (group_messages.forwarded column) — no client change made;
  LIVE CHECK OWED BEFORE DEPLOY (see §8). G-03 (forward inserts don't set
  forwarded:true) deliberately left — same owed check decides it. F09 (TURN
  fetch) parked — needs a new Edge Function round-trip.

§2.5 Games & polls (7 fixed: E-01, E-02, E-03, E-04, E-05, E-07, F05)
- E-01 (P2) v117ClosePoll._busy was shared by all polls — now a per-message-id
  map (same pattern as v137VoteInFlight). A second tap on the same poll is
  still dropped; a close tap on a different poll now proceeds.
- E-02 (P2) Dedupe window finite (21st live game invisible) — one extra read
  on game-start only: a second query scoped to my own games, merged into the
  group-window result deduped by id. My own live games can now never fall out
  of the window. No new polling; +1 read per game-start.
- E-03 (P2) Open-challenge sweep was a single page of 20 — now pages
  oldest-first exactly like the player sweep (max 5 pages / 100 rows, break
  on a short page or no new ids). No new timer/polling.
- E-04 (P2) v146GameStartSeen localStorage map never pruned — new helper
  v146PruneGameStartSeen drops entries older than 24 h (the
  v146CatchUpStartedGames look-back window); called on write and read. The
  TTL is a literal inside the helper (not a sibling var) so the helper stays
  correct when extracted alone — the harness caught a NaN on the first
  version, and the code was changed, not the test.
- E-05 (P2) My-games corner fetch cap 200 hid older pairs — limit 200 -> 500
  (same one read per corner open; 500 covers 25 pairs at the per-chat 20-row
  prune cap). Still finite by design — a user with 26+ active pairs would
  still lose the oldest.
- E-07 (P2) Stale v123DeleteGame comment contradicted the expired-delete code
  — comment-only change (delete guard itself unchanged).
- F05 (P2, v168) Poll counts vs voter list contradicted for ex-members — the
  voter list dropped ex-members while counts counted all vote rows (e.g. "3
  votes · Who voted" expanding to "No votes yet."). Fix: ex-member votes are
  shown unnamed as "Former member". Totals, per-option counts, bars and
  percentages are unchanged; no vote data is invented and no name is revealed.
  DELIBERATE BEHAVIOUR CHANGE, flagged (see §5).
- NOT FIXED: E-06, F11, S-1 — SQL-owed, drafts in supabase-v172.sql §3
  (group_poll_votes.group_id + realtime filter; poll-options CHECK;
  3-pending-invite cap trigger). G-10 (Carrom queen endgame) — UNANSWERED
  USER DECISION; v142BotCarrom is byte-identical, no bot change of any kind.
  F03 (ex-member re-vote) — hardening already ships in supabase-v168.sql §5;
  needs only a live pg_policies read to close out (see §8).

§2.6 Notifications & settings (5 fixed: F-01, F-03, F-05, F-06, F-07)
- F-01 (P1) Push-OFF did not survive restart — v140EnsurePushSubscription now
  reads localStorage['chatbox_push_pref_'+me.id] and runs one
  push_subscriptions row-check per app start before subscribing; it returns
  without subscribing when there is no row and no 'on' pref.
  togglePushNotifications writes 'on'/'off'. Repair preserved (a row
  existing still subscribes; a failed row-check fails OPEN). No extra query
  (the per-endpoint maybeSingle check was replaced by reusing the same row
  list). Burst rule re-verified: sounds on 1/7/13, reset on open and gap
  >120 s.
- F-03 (P2) Font-size S/L missed 40 rules — 40 new body[data-font-size]
  rules (inbox time/preview, message foot/timestamps, section headers,
  bell list, contact/group-info panels, auth screen, .note). --msg-size
  bubble/composer rules untouched. One deliberate omission: #auth .field
  label (base rule is 11px!important; overriding it would need !important).
- F-05 (P2) DELIBERATE SMALL ADDITION: "Sign out of other devices" button in
  Account -> Session (v44SignOutOtherDevices()), calling
  sb().auth.signOut({scope:'others'}) — the same call already proven in the
  password-change path. Success is claimed only when the call really
  succeeded. No security event is recorded (no such event type exists;
  inventing a password_change record would be a lie). This is the only new
  feature in v172. Flagged (see §5).
- F-06 (P2) Wallpaper browsing wrote profiles on every tap — pickWallpaper
  now debounces the profiles.update ~400 ms trailing edge; rapid browsing
  settles to one write with the last id. The "saved" toast fires only after
  the debounced write succeeds.
- F-07 (P2) "Check for updates" claimed the version was the latest — verdict
  now reads "No service-worker update found — you are on <stamp>." The check
  only asks the service worker; it never compares versions. No new polling,
  no version.json fetch. A real version comparison is still a follow-up
  (needs the server to expose the deployed version).
- F-02 (P1) Version stamp — coordinator's job, DONE at stamp time (v172 /
  20 November 2026, 13:36). F-04 (P2) sw.js — coordinator's job, DONE
  (CACHE_NAME chatbox-v172 + header).

§2.7 Performance, PWA & quota (8 fixed: G-01 partial, G-02, G-03, G-04, G-06,
G-08, G-09, G-10; + P2-8, F-08, F-04-icon)
- G-01 (P2) PARTIAL — probe sig now also carries deleted_at (group newest
  row) and edited_at (once the window fetch has proven the column exists).
  Residual (NOT fixed): DM delete-for-everyone (message_meta.deleted_at),
  reactions and pins still cannot be seen without a new per-tick query each —
  that would be new request volume, so they stay blind until the forced fetch
  (bounded by the 5-skip cap, ~6 min healthy / ~30 s degraded; Realtime is
  the live path).
- G-02 (P2) Probe queries dropped count:'exact' (PostgREST COUNT(*) scanned
  the whole chat history on every tick) and the #n= sig component. Remaining
  count:'exact' uses are all head:true single-purpose counts, untouched.
- G-03 (P2) Offline-queue flush: in the returned-{error} branch, a network-
  like error now calls v168FlushLanded before re-queueing (exactly like the
  catch path) — landed messages stop being re-queued.
- G-04 (P2) Message-cache TTL 7 days -> 24 h (snapshot is replaced on every
  successful load anyway). The offline note now shows when the snapshot was
  saved ("showing saved messages (saved 19 Nov 08:18)…").
- G-06 (P2) Update reload could fire mid-call/game — the 800 ms setTimeout
  now re-checks the three conditions fresh (call modal / minimised pill /
  callState, game modal) and aborts the reload with the matching toast.
- G-08 (P2) Index windows limit(5000) -> limit(2000) in inboxLoadIndex and
  inboxLoadGroupIndex (capped-window check >= 5000 -> >= 2000). The existing
  fallback already handles a capped window, so ordering stays stable.
- G-09 (P2) Seen-avatar refresh ran every degraded tick — now throttled to at
  most once per 60 s even in degraded mode (_v168SeenAvatarsAt, stamped only
  when a query is about to run). ~720 -> ~60 group_message_reads selects/hr
  in a degraded group hour. The guard is typeof-safe (the extractor lifts
  this function alone; a bare read of the file-scope var would throw and
  silently disable the refresh — the first quota run showed scenario-c reads
  dropping to 0, and the guard fixed it).
- G-10 (P2) Tick/refresh paths called v161LoadPins(true) — now respect the
  30 s cache (v161LoadPins(false)). Chat-open and pins-channel callers still
  use force=true, so opening a chat always shows fresh pins.
- P2-8 (P2, v168 re-audit) Dead v43 stories/notes data channel deleted
  (v43SubscribeData + wrapper + top-level call). Verified no live duplicate
  subscription existed.
- F-08 (P2, v168 re-audit) Logout wiped a pending offline queue silently —
  the armed logout label now reads "Tap again to log out — N queued
  message(s) will be lost" when the queue is non-empty.
- F-04 (P2, maskable icon) New icon-maskable-512.png rebuilt: the original
  art was byte-identical to icon-512 and its pixels reached radius 252 px
  (29,344 px outside the maskable safe circle r=204.8). The new icon scales
  the artwork x0.78 onto the same solid teal background (#087f68): max
  non-background radius 197.4 px, 0 px outside the safe circle.
- NOT FIXED: G-05 (restore a local bot game — needs a parallel restore path
  + a new "resume local game" affordance; a new feature, not a fix). G-07
  (stamp/sw) — coordinator's job, DONE. G-11 (sw.js fallback cacheName) —
  needs a sw.js change; coordinator-owned, no behaviour change for any URL
  cached today.
- QUOTA VERDICT (see §6): every v169 traffic cut verified in code; no new
  volume in v172 except the deliberate v171 one-extra-detail-fetch for
  genuinely-deleted peers. Dec-cycle budgets (33 MB logs / 130-170 MB egress
  per day) are preserved by the measured numbers below.

================================================================
§3 FINDINGS TABLE — all 75 NEW findings (P0: 0 · P1: 13 · P2: 62)
================================================================
ID    Sev  Title                                                     Status
----  ---  --------------------------------------------------------  ----------------
A-01  P1   Pre-auth security-event insert forgery                  NOT FIXED — SQL-owed (§8 §1)
A-02  P1   Exact-username search select('*') at 6 sites            FIXED
A-03  P1   Story-delete queue has no server consumer               NOT FIXED — SQL/Edge-owed (§8 §1)
A-04  P2   downloadMedia fetches before scheme validation          FIXED
A-05  P2   Story viewer takes raw style strings                   FIXED
A-06  P2   Call peer avatar_color unsanitised                      FIXED
A-07  P2   Lockout gives no notice to the locked-in user           FIXED (notice only)
A-08  P2   Forgot-reset text implies other sessions revoked        FIXED (wording)
B-01  P1   "Delete chat" doesn't delete                            FIXED
B-02  P1   In-chat search renders newest-first                     FIXED
B-03  P1   Null detail silently deletes the chat (all views)       FIXED (+ §1 diagnostic)
B-04  P2   Global search surfaces hidden-for-me messages           FIXED
B-05  P2   Inbox search never searches group message text          FIXED
B-06  P2   False "Showing the newest 30 matches" note              FIXED
B-07  P2   Group-member searches share one debounce timer          FIXED
B-08  P2   Group badge can resurrect after opening                 FIXED
B-09  P2   Community + announcement group render as two rows       NOT FIXED — parked (intent decision)
C-01  P1   Storage-file deletion depends on undeployed functions   NOT FIXED — SQL/server-owed (§8 §2)
C-02  P1   Group view-once consumed for everyone by first viewer   NOT FIXED — SQL-owed (§8 §2)
C-03  P1   Deleted/expired story files: queue with no consumer     NOT FIXED — SQL/server-owed (§8 §2)
C-04  P2   Temp-bubble Pin guard                                   NOT FIXED — out of scope
C-05  P2   Peer unsend only surfaced on the 60 s fallback poll     FIXED
C-06  P2   25-day retention notice                                 NOT FIXED — out of scope
C-07  P2   Message length cap                                      NOT FIXED — out of scope
C-08  P2   15-min edit-window server enforcement                   NOT FIXED — SQL-owed, out of scope
C-09  P2   link-preview Edge Function undeployed                   NOT FIXED — out of scope (same as C-01)
C-10  P2   Unsend leaves the starred snapshot behind               FIXED
C-11  P2   Seeded snapshot can resurrect an unsent message (7 d)   FIXED (24 h seed cap)
C-12  P2   "Delete for me only" toast implies a sync               FIXED (wording; sync SQL-owed)
C-13  P2   Pin fetch kept the OLDEST 100                           FIXED
C-14  P2   Disappearing-message expiry hard-delete needs RPC        NOT FIXED — SQL-owed (§8 §2)
C-15  P2   storyPrev() dead-end                                    NOT FIXED — out of scope
C-16  P2   Cached story strip dead rings                           NOT FIXED — out of scope
C-17  P2   Story viewer image error handler                        NOT FIXED — out of scope
C-18  P2   View-once close-watcher wrong modal                     NOT FIXED — out of scope
C-19  P2   View-once 60 s cap vs long video                        NOT FIXED — out of scope
C-20  P2   postStory() double-submit guard                         NOT FIXED — out of scope
C-21  P2   Failed story post orphans Storage file                  NOT FIXED — out of scope
C-22  P2   Document upload type check                              NOT FIXED — out of scope
C-23  P2   Camera/preview view-once into self-chat                 NOT FIXED — out of scope
C-24  P2   Upload progress                                         NOT FIXED — out of scope
D-01  P2   Community member list ⋮ on the creator row              FIXED
D-02  P1   Subscribe-add branch stalls on a dead subscriber PC     FIXED
D-03  P2   Seen avatars go stale on returning to a group           FIXED
D-04  P1   Stranded client kept in a dead group call               FIXED
D-05  P2   Dead _iceCache / _pendingMids                           FIXED (deleted)
D-06  P2   group_messages.forwarded column unverified live         NOT FIXED — LIVE CHECK OWED (§8)
D-07  P2   Early-track queue bound 8 + no retry until reconcile   FIXED
D-08  P2   Forwarding a game / result / call-invite breaks         FIXED (group fns only)
D-09  P2   Call sheet shows empty list / 00:00 before connect      FIXED
E-01  P2   v117ClosePoll._busy shared by all polls                 FIXED
E-02  P2   Dedupe window finite (21st live game invisible)         FIXED
E-03  P2   Open-challenge sweep single page of 20                  FIXED
E-04  P2   v146GameStartSeen localStorage map never pruned          FIXED
E-05  P2   My-games corner fetch cap 200 hides older pairs         FIXED (cap 500)
E-06  P2   group_poll_votes realtime subscription unfiltered       NOT FIXED — SQL-owed (§8 §3)
E-07  P2   Stale v123DeleteGame comment vs expired-delete code     FIXED (comment only)
F-01  P1   Push-OFF does not survive restart                       FIXED
F-02  P1   Version stamp (coordinator's job)                       FIXED (stamped v172)
F-03  P2   Font-size S/L misses 40 rules                           FIXED
F-04  P2   sw.js cache name (coordinator's job)                    FIXED (chatbox-v172)
F-05  P2   No "Sign out of other devices" button                   FIXED (new button, §5)
F-06  P2   Wallpaper browsing writes profiles on every tap         FIXED (400 ms debounce)
F-07  P2   "Check for updates" claims the version is latest        FIXED (honest verdict)
G-01  P2   Probe sig misses deletes/edits (blind until forced fetch) FIXED (partial — see §2.7)
G-02  P2   Probe queries use count:'exact' (full COUNT(*) / tick)  FIXED
G-03  P2   Offline-queue flush re-queues landed messages           FIXED
G-04  P2   Message-cache TTL 7 days                                FIXED (24 h)
G-05  P2   Local bot game cannot be restored after reload          NOT FIXED — needs a new feature
G-06  P2   Update reload can fire mid-call / mid-game              FIXED
G-07  P2   Version stamp / sw.js (coordinator's job)               FIXED (stamped v172)
G-08  P2   Index windows limit(5000)                               FIXED (limit 2000)
G-09  P2   Seen-avatar refresh every degraded tick                 FIXED (60 s throttle)
G-10  P2   Tick/refresh paths force pins reload                    FIXED (30 s cache)
G-11  P2   sw.js fallback ignores cacheName                        NOT FIXED — sw.js job, no behaviour change

New-findings tally: 75 total — FIXED 50, NOT FIXED 25.
NOT FIXED split: SQL/Edge-Function-owed 8 (A-01, A-03, C-01, C-02, C-03, C-14,
E-06, D-06-live-check); out of scope for this round 15 (C-04, C-06, C-07,
C-08, C-09, C-15..C-24); parked / decision-owed 2 (B-09, G-05-as-feature).
No P0 was found.

================================================================
§4 V168 RE-AUDIT (carried items — status in v172)
================================================================
The v168 audit's 192 findings were re-audited. Headline outcomes:
- P1-01 (client-side-only lockout) STILL PRESENT by design — needs the server
  lockout (supabase-v172.sql §1 §3). A-07's toast is the honest interim.
- P1-02 (email login fails open on revoked RPC) already FIXED in base v171.
- P1-03 (session restore admits stub profile) already FIXED in base v171.
- P1-04 (password change doesn't revoke other sessions) already FIXED in
  base v171.
- P1-3 (email->username oracle) STILL PRESENT — revoke gated on the server
  login-by-email lock check (supabase-v172.sql §1 §3c). Do NOT run the revoke
  before Stage 2 is verified live, or recovery-email login breaks.
- P2-03 (forgot-reset doesn't clear username lock) STILL PRESENT — server
  half in supabase-v172.sql §1 §4b; must land with the §3 Stage 3 revoke.
- P2-05 (lock-event recording gaps) parked — recording on every failure would
  widen the A-01 forgery surface before the RPC exists.
- P2-08 (logout teardown gaps) parked as risky (see §2.1).
- P2-12 (recovery-code guarantees) unverifiable — Edge Function source not
  in this folder (supabase-v172.sql §1 §4c).
- P2-10, P2-11 FIXED this round (see §2.1). F-03, F-04, F-10, F-11 FIXED this
  round (see §2.2). G-06 FIXED this round; F13 PARTIALLY FIXED (see §2.4).
  P2-8 (dead v43 channel) DELETED; F-08 FIXED (see §2.7).
- F03 (ex-member re-vote) — hardening already ships in supabase-v168.sql §5;
  close-out needs only a live pg_policies read (see §8).
- F09 (calls, TURN fetch) parked — needs a new Edge Function round-trip.
- F-09 (inbox, scale caps + N+1) — same item as the inbox B-09 row's
  companion: unsafe to change client-side, needs a dedicated perf pass.
- G-6 (expired game rows prune/delete) — NOT reverted, NOT expanded. The
  revert decision is still unanswered; the h_ui suite's one known failure is
  its stale check string (see §7).
- v168 §0(e) NULL-created_by policy edge — still an open hand item: live
  group_members/group_admins DELETE policies DENY delete when created_by is
  NULL; the §6 proposed form would ALLOW it. Reconciliation still owed.
- v155 SQL-1 — still NOT run: messages has 169 rows with non-NULL media_url
  NOT starting with https:// (contents UNKNOWN; inspecting skipped per user
  order 8 Nov 22:58 — do not run/inspect without his word).

================================================================
§5 DELIBERATE BEHAVIOUR CHANGES (flagged — these are not regressions)
================================================================
1. F05 (polls): ex-member votes are now shown unnamed as "Former member" in
   the voter list (was: dropped entirely, while counts counted them — "3
   votes · Who voted" expanding to "No votes yet."). Totals, per-option
   counts, bars and percentages are UNCHANGED. The count-only-current-members
   alternative was NOT taken — it would have retroactively changed poll
   outcomes when a voter leaves.
2. C-12 (delete-for-me): both toasts now read "Hidden on this device only"
   (was: "Hidden" / "Deleted for you", implying a sync that doesn't exist).
   The hide itself is unchanged (localStorage-only).
3. F-05 (settings): NEW "Sign out of other devices" button in Account ->
   Session. The only new feature in v172. Uses the already-proven
   signOut({scope:'others'}) call; no security event is recorded (no such
   event type exists).
4. D-08 (forward): group forward functions now REFUSE game / game-result /
   group-call-invite messages with a toast (was: inserted a broken card).
   DM->DM forward (doForward) is UNCHANGED — out of scope (see §DECISIONS).
5. B-03 (inbox): a chat whose detail fetch fails now keeps a placeholder row
   ("Chat", unread 0) instead of vanishing (was: silently dropped from every
   view). Unread view still skips unread-unknown placeholders.
6. F-07 (updates): the verdict no longer claims the version is latest.
7. G-04/C-11 (cache): message-cache TTL 7 days -> 24 h; seeded snapshots
   older than 24 h are refused for first paint. Offline open still works
   from a fresh snapshot.
8. G-08 (index windows): limit(5000) -> limit(2000). Ordering is unchanged
   (the capped-window fallback already handles it).
9. NOT changed: bot difficulty (Carrom endgame G-10 and Quiz difficulty are
   UNANSWERED user decisions — bots byte-identical, no mercy/catch-up/
   score-adaptive change anywhere); G-6 (expired rows prune/delete);
   PC-call hardening N2–N4 (PARKED by user order); no battery/Chrome-engine
   fix (v147 lesson); no redesign, no new features beyond F-05; no fake or
   demo features.

================================================================
§6 QUOTA (Dec cycle is zero-tolerance — budgets 33 MB logs / 130-170 MB
egress per day; org over quota, restrictions from 11 Dec 2026 if it stays
over; cycle resets 03 Dec)
================================================================
Measured on the final v172 file (harness, stubbed sb(), 60 virtual min),
against the v168 baseline:
- (a) idle DM open, healthy:      12,021 -> 710 req  (94.1% fewer)
- (b) idle inbox only, healthy:    8,301 -> 360 req  (95.7% fewer)
- (c) idle group open, healthy:   10,221 -> 530 req  (94.8% fewer)
- (d) active DM (10 incoming):    12,086 -> 765 req  (93.7% fewer; v171: 771)
- (e) idle DM, Realtime DEGRADED: 12,021 -> 10,377 req (13.7% fewer — the
  safety net by design; identical to v171)
- Target check (>=90% fewer idle requests per client): a 94.1%, b 95.7%,
  c 94.8% — ALL MET.
- v172 vs v171: identical except active DM 771 -> 765 (6 fewer). No
  regression. The only new volume in v172 is E-02's +1 read per game-start
  and B-05's +1 query per debounced inbox search — both event-driven, not
  polling. G-09 strictly REDUCES degraded-mode volume (~720 -> ~60
  group_message_reads selects/hr). Whether the Dec budgets hold depends on
  Supabase's unpublished per-request log bytes — the live dashboard trend
  after deploy is the final judge (check the org Usage page daily in week 1
  of the Dec cycle; do not poll Logs Explorer on a schedule).
- Load time (same harness, 300 ms/query stubbed network): v172 index load
  median 1204 ms (v170: 1204 ms — 0% change); seeded first paint 0 ms;
  hung network resolves false after ~4003 ms and keeps the cached inbox
  (never a forever-skeleton).

================================================================
§7 VERIFICATION (all on the final stamped file unless noted)
================================================================
- Fix suites (each on the merged file, with negative controls on the true
  v171 original): auth/security 50/51 · inbox/search 57/58 · DM/media 59/60
  · groups/calls 24/25 · games/polls 33/34 · notif/settings 71/74 ·
  perf/PWA 43/44. Total 337/346 — and all 9 failures are the same thing:
  the "fixer didn't stamp the version" guards, which MUST fail now that the
  coordinator stamped v172 (they passed on the fixers' private copies,
  unstamped, when the suites reported 346/346 with ORIG still pointing at
  the then-pristine v172 folder file). Every actual fix check passes, and every
  negative control passes against v171 (0 negative-control failures). Two
  harness repairs made during this final run: the suites' hardcoded ORIG
  paths pointed at the v172 folder file (which held the pristine original
  when the fixers ran but now holds the final build) — repointed to the v171
  folder so the negative controls read the true original.
- Repointed v171 behaviour suites on v172: deleted_user 29/0 · adaptive
  29/0 · presence 34/0 · pagination 44/0 · loadmore 23/0 · game-listener
  18/18 (the suite's stale "v44 binds NO message_meta" expectation was
  updated for C-05, and the E-04 prune helper was added to the extracted
  function list — in the real file all four functions share one scope, so
  the guard was never broken in the app; the failures were harness-only).
- Regression suite (v172 vs v171): 67/67 — call block identical, game
  subscriptions + v170 FIX-2 preserved, burst rule, search limit 200, seen
  avatars, bot form rates (TTT 10/25/40, C4 0.03/0.10/0.25), v169 quota
  behaviours, v170 load-more cursor, v172 stamp + cache names, v172-only
  markers (C-05, E-04, B-03, F-05, G-04, F-07), v171 changes preserved
  (V169_PROFILE_COLS, _v171IsSelf, _v171Poisoned, fallback avatar, cache
  sigs). (Two harness bugs found and fixed during this run: a renamed
  _v170OldestId literal and reference checks that read the new file instead
  of the v171 file — both were suite bugs, not app regressions.)
- h_ui: 575 pass / 1 fail — the single failure is the KNOWN STALE h24/G-6
  check ("prune still only deletes finished/declined"), which expects
  expired records to be kept; v168's deliberate G-6 change deletes them.
  Same 575/1 as v168/v169/v170. The extracted games_ui.js was REBUILT from
  the v172 index (rebuild_games_ui.py) so h_ui tests the shipped game UI,
  including the E-04 prune helper.
- node --check: 46 inline script blocks, 0 errors.
- Expose audit: 582 inline onclick attributes, 346 distinct callees,
  DEAD 0 (every onclick callee is exposed).
- Call block: md5 63e54beeafa890f9383ad9195ab78c61 (byte-identical v105->v172).
- Profiles columns: V169_PROFILE_COLS = id,created_at,username,display_name,
  bio,birthday_md,avatar_color,avatar_emoji,avatar_url,wallpaper,theme,
  read_receipts,last_seen (13 columns). No profiles select names birthday or
  phone (44 profiles selects checked; select('*') 15 -> 9 — A-02). The one
  'phone' select in the file is from('profile_phones'), a separate table,
  unchanged from v171.
- Bot hard rules: all 13 games re-verified win-first, zero score-dependent
  softening; v142BotCarrom byte-identical; no bot function touched. G-6 not
  reverted or expanded. No battery measurement exists and none is claimed
  (battery must stay equal to WhatsApp — unmeasured).
- Merge notes (coordinator): 7 diffs, 98 hunks applied; 4 hunks hand-merged
  (overlapping comment edits only, except one TTL/comment merge); harness
  repairs recorded in the test files as "v172 MERGE NOTE".
- Base v171 re-checked after the build: index md5
  7525f68041765a8998899f54369bccfb (untouched).

================================================================
§8 SQL — supabase-v172.sql (DRAFT ONLY — NOT RUN, NOT APPROVED)
================================================================
File: supabase-v172.sql in this folder (md5 8a57a820a57af1cc17e546732565c10f,
1,264 lines), consolidated from the four fixers' drafts (auth, DM/media,
games/polls, notif/settings). Nothing in it has been executed against any
database and no Edge Function has been deployed from it. Every section is
check-first: run the CHECK queries, read the result, and only then run the
change. If a check contradicts an assumption, STOP and re-draft.
- §0 Check-first preamble (run before any section) — includes the D-06
  check (group_messages.forwarded) and the message_meta publication check.
- §1 Auth & security: A-01 (SECURITY DEFINER RPC
  chatbox_record_security_event_pre_auth + revoke anon INSERT for
  user_id IS NULL rows), A-03 (story-media delete branch + sweep),
  P1-01/P1-02/P1-3 cluster (server lockout Stages 1-3 — Stage 3 revoke ONLY
  after Stage 2 verified live), §4 Edge Function specs (verify-and-reset
  session revoke + username return; recovery-code guarantees).
- §2 DM & media: C-01 (cleanup-expired-media / delete-view-once deployment
  checklist), C-02 (view_once_views + delete-only-when-every-member-viewed),
  C-03 (cleanup-expired-media mode:'delete-story'), C-12 (hidden_messages),
  C-14 (chatbox_disappearing_purge RPC + scheduled sweep).
- §3 Games & polls: E-06 (group_poll_votes.group_id + backfill + trigger),
  F11 (poll-options CHECK 2-5 options, <=100 chars), S-1 (3-pending-invite
  cap trigger), F03 verify-only (live pg_policies read — no new SQL).
- §4 Notifications: S09 P0-1 mute store (PARKED — proposed table
  muted_chats + send-push change + deploy checklist). NAMING FLAG: this
  draft proposes a NEW table muted_chats, while v168 §3 already created
  chat_mutes. The approver must decide which table send-push reads — do not
  run §4 until that is reconciled.

LIVE CHECKS OWED BEFORE DEPLOY (dashboard, ChatBox project ONLY):
1. D-06: information_schema.columns for group_messages.forwarded — if
   missing, group opens 42703. v168 §8 SQL is recorded as run 10 Nov 23:37,
   but code cannot prove live state. If absent, run the one idempotent
   ADD COLUMN IF NOT EXISTS first. Once confirmed present, also add
   forwarded:true to the two group forward inserts and update the L11125
   comment (G-03).
2. message_meta in the Realtime publication (C-05 depends on it; if absent,
   the 60 s unsend bound stands).
3. F03: live pg_policies read of group_poll_votes_update_self (exact query
   in the SQL draft §3 §4).
4. The auth draft §0 check-first queries (the client comment claims a
   restrictive pre-auth SQL policy already exists — UNVERIFIED; re-scope §1
   if the checks contradict it).

================================================================
§OWED — live tests still owed after deploy (two phones, unless noted)
================================================================
- v172 fixes (new): B-03 placeholder row + one bounded re-fetch (kill the
  detail fetch — e.g. slow network — and watch the row stay, then heal);
  C-05 peer unsend arrives instantly via Realtime (not after 60 s);
  F-01 push-OFF survives restart (turn push off, kill app, reopen — no
  re-subscribe); F-05 "Sign out of other devices" on a second device;
  F-07 update verdict wording; D-02/D-04 group-call join/leave paths;
  D-08 forward refusal for games/call-invites; E-01 close two polls
  quickly; F05 ex-member vote shows "Former member"; G-06 update reload
  aborted mid-call/mid-game; G-09 degraded-mode seen-avatar throttle
  (no visible change expected); C-13 newest pins kept; C-10 starred
  prune on unsend; C-11 24 h seed cap (open a chat from a >24 h old
  snapshot — no stale paint).
- 18 Nov quirk: the §1 diagnostic steps (localStorage dump + console/
  network capture at the next occurrence). B-03's per-rebuild null-detail
  log is the instrument — check it first.
- Carried from earlier versions (still open): v171 inbox Samia + self
  photos/names; two-account live call (voice heard EACH way); Samia's
  phone notification checklist; notification burst on real phones
  (1st/7th/13th sounds, 5 silent, reset on open, reset after 120 s gap);
  poll voting live; seen avatars live; TTT bot feel live; group games
  two-phone (invite -> accept -> result, 3-cap, third-member views);
  spectating two-phone; @ mentions; Carrom flip on Player-B's phone; Chess
  timeout on both phones (exact result string); Quiz PC real-browser
  (clean first tap AND drag-then-click); v168 group-call P0 live retest on
  two phones (needs SFU Edge Function deploy first); password-change
  revocation on a second device; v169/v170 instant Realtime delivery, 5 s
  degrade + catch-up, presence dots incl. after peer closes app, showOnline
  OFF/ON, group Edited tag, history scroll, search, battery; v170 two
  load-more taps = new page, no repeats; game accept with modal closed
  starts game + no double-open; Dec-cycle Usage trend (daily, week 1);
  rendered 320/360/390 px screenshots light+dark for v172 changes;
  battery/heat phone measurement incl. ChatBox-vs-WhatsApp EQUAL comparison.

================================================================
§DECISIONS NEEDED (unanswered — nothing below was decided in this build)
================================================================
1. G-6 revert? Expired game rows prune/delete (v168 change). Revert offered
   if he wants them kept forever. v172 does NOT revert or expand G-6.
2. Carrom endgame tuning (G-10)? Asked 08:42, 10 Nov. v172 leaves the
   Carrom bot byte-identical.
3. Quiz bot difficulty ("Quiz ebr easy ta chilo") — tune harder? v172 leaves
   Quiz untouched.
4. B-09: community + announcement-group double row — intended or a bug?
5. F-09 (inbox scale caps + N+1) — dedicated server-side perf pass?
6. D-08 scope: should DM->DM forward (doForward) also refuse games /
   game-results / call-invites, or stay as it is?
7. group_messages.sender_id nullable? (one-line SQL follow-up, offered
   09:34, 10 Nov — unanswered.)
8. muted_chats (v172 draft) vs chat_mutes (v168 §3, already created) —
   which table does send-push read? (see §8.)
9. S09 P0-1 server push mute: approve the §4 SQL + send-push redeploy?
10. v155 SQL-1: inspect the 169 non-https media_url rows? (Skipped per his
    order; do not run without his word.)
11. Link-preview A4 redeploy (dashboard redeploy needed).
12. v160 group-call setup (his tasks, deferred): Cloudflare Realtime app
    (card) -> secrets -> deploy group-call-token -> live 2+ phone test +
    battery measurement.
13. §4 oracle-RPC revoke — gated on the server login-by-email lock check
    shipping; do NOT run before then.
14. Cleanup schedule + CLEANUP_SECRET setup (sweep cannot run until set).
15. The 13:35 (11 Nov) "quote" clarification — which "quote" did he mean?
    (Asked; awaiting his answer. The 18 Nov diagnosis IS saved in MEMORY.md
    and in this README §1.)

================================================================
§PACKS
================================================================
Cloudflare deploy ZIP: chatbox-supabase-v172-2026-11-20.zip (11 files at
root: index.html, sw.js, manifest.json, favicon.svg, logo.png, icon-192.png,
icon-512.png, icon-maskable-512.png, chatbox-call-doodle-bg.jpg, _headers,
README-v172.txt). Built from INSIDE the v172 folder with an explicit file
list; verified by unzip -l + ZIP index byte-identical to disk + extraction
grep (version string + changed markers) + md5s. (ZIP md5 in the handoff —
it cannot be inside the README it ships in.)
GitHub repo pack: files/chatbox-github-repo-v172/ — the same 11 files +
README.md (portfolio-grade: animated banner, live demo link, stack,
features, architecture, setup, folder structure) + DEPLOY_GUIDE.md
(Cloudflare deploy + GitHub push steps + where each real secret is set) +
.env.example (placeholders only) + .gitignore (excludes .env, .env.local,
.env.*.local) + MIT LICENSE (Copyright (c) 2026 Md Abir Hossain — same as
his CyberLab repo; change it if he wants another licence) +
supabase-v172.sql + assets/banner.gif (1200x630, 36 frames, animated:
bubbles appear, typing dots, gentle logo glow). Secret scan: 0 real secret
values in the pack; .env excluded by .gitignore; .env.example placeholders
only. The Supabase ANON key stays in index.html by design (public, RLS-
scoped) — the static app has no build step and cannot read .env at runtime.
No repo was created, nothing was pushed — he pushes himself.
