-- ============================================================================
-- ChatBox v172 — supabase-v172.sql
-- STATUS: PARTIALLY RUN LIVE (20 Nov 2026, project "chatbox" ONLY).
-- ----------------------------------------------------------------------------
-- §0 checks: DONE (20 Nov 2026).
-- RUN + VERIFIED live: §1-1a (pre-auth RPC), §1-3a ADAPTED (lockout RPCs on
--   the existing auth_lockouts table, RLS enabled), §2 C-12 (hidden_messages),
--   §3 S-1 (game-invite cap trigger).
-- STOPPED — DO NOT RUN AS WRITTEN: §3 E-06 (backfill blocked by the existing
--   chatbox_guard_poll_vote trigger; rework owed), §3 F11 (Postgres forbids a
--   subquery in CHECK; trigger-based check owed).
-- DO NOT RUN: §1-1b, §1-3c (oracle revoke), §2 C-02 view_once_views table,
--   §4 muted_chats table (chat_mutes is the store).
-- Every section is written CHECK-FIRST: run the CHECK queries, read the
-- result, and only then run the change. If a check contradicts an assumption
-- stated in the comments, STOP and re-draft instead of forcing the change
-- through.
--
-- HOW TO USE (Supabase dashboard -> SQL Editor, project "chatbox" ONLY):
--   1. Run the §0 checks first and record the answers.
--   2. Run ONE section at a time, in order. After each section, run its
--      Verification queries (live, after deploy where noted).
--   3. Sections marked "Edge Function" are build specs, not SQL — they are
--      implemented in the Supabase dashboard / CLI, never by pasting here.
--   4. Sections marked "PARKED" or "verify-only" must NOT be run: read them.
--
-- CONTENTS
--   §0  Check-first preamble (run before any section)
--   §1  Auth & security — A-01 pre-auth security-event forgery,
--       A-03 story-media delete, P1-01/P1-02/P1-3 server lockout + oracle
--   §2  DM & media — C-01 storage deletion, C-02 group view-once,
--       C-03 expired-story queue, C-12 delete-for-me sync, C-14
--       disappearing-message hard delete
--   §3  Games & polls — E-06 group_poll_votes.group_id, F11 poll-options
--       validation, S-1 3-pending-invite cap trigger, F03 verify-only
--   §4  Notifications — S09 P0-1 server push mute store (PARKED, see §4)
--
-- Client companions: the v172 client diff does NOT contain any of this work.
-- Client-side fixes for the same findings are listed per section where they
-- exist; do not re-apply them from here.
-- ============================================================================

-- ============================================================================
-- §0 — CHECK-FIRST PREAMBLE (run before any section, record the answers)
-- ============================================================================
-- What policies exist on the security-events table today?
select policyname, cmd, roles, qual, with_check
from pg_policies where tablename = 'account_security_events';

-- Does the security-events table have the columns the client assumes?
select column_name, data_type, is_nullable
from information_schema.columns
where table_name = 'account_security_events';

-- Do the RPCs / functions referenced by the client exist?
select proname, prosecdef from pg_proc
where proname in ('chatbox_lookup_username_by_recovery_email',
                  'chatbox_record_security_event_pre_auth',
                  'chatbox_check_login_lock',
                  'chatbox_record_failed_login');

-- What tables exist that could already hold failed-login state?
select table_name from information_schema.tables
where table_schema = 'public'
  and table_name like '%login%' or table_name like '%lock%';

-- Does group_messages.forwarded exist live? (D-06: v172 group-forward
-- hardening assumes it; if this returns 0 rows, group opens will 42703.)
select column_name from information_schema.columns
where table_name = 'group_messages' and column_name = 'forwarded';

-- Is message_meta in the Realtime publication? (v172 C-05 depends on it;
-- if absent, the 60 s unsend bound stands.)
select schemaname, tablename from pg_publication_tables
where pubname = 'supabase_realtime' and tablename = 'message_meta';

-- Which tables are in the Realtime publication today?
select tablename from pg_publication_tables
where pubname = 'supabase_realtime' order by tablename;

-- ======================================================================
-- §1 — AUTH & SECURITY (A-01, A-03, P1-01/P1-02/P1-3 cluster)
-- ======================================================================
-- Source draft: sql_auth_security.md (verbatim conversion;
-- prose -> comments, ```sql blocks -> SQL unchanged).

--
-- V172 SQL / EDGE FUNCTION DRAFT — AUTH & SECURITY (A-01, A-03, P1-01/P1-02/P1-3 CLUSTER)
-- ---------------------------------------------------------------------------------------

-- **STATUS: DRAFT ONLY — NOT RUN, NOT APPROVED.** For the coordinator to hold
-- for user approval. No SQL in this file has been executed against any database,
-- and no Edge Function has been deployed from it. Every section is written
-- **check-first**: run the CHECK queries, read the result, and only then run
-- the change — if a check contradicts an assumption stated below, STOP and
-- re-draft instead of forcing the change through.
--
-- **Scope:** A-01 (pre-auth security-event insert forgery), A-03 (story media
-- delete with no server consumer), and the v168 P1-01 / P1-02 / P1-3
-- server-lockout + email→username-oracle cluster from
-- `../audit_auth_security.md`. Client-side companions are listed per section;
-- the client diff (`auth_security.diff`) does NOT contain any of this work.
--
-- **Assumptions to verify (do not trust — check):**
-- - `account_security_events` has columns `id, user_id, username, event_type,
--   device_label, detail, created_at` (row shapes from the client:
--   `v142RecordSecurityEvent` L4835–4843 inserts with `user_id = me.id`;
--   `v142RecordSecurityEventPreAuth` L4862–4870 inserts with `user_id = NULL`).
-- - `V142_SEC_TYPES = ['login','password_change','failed_attempt']` (L4813).
-- - The client comment at L4853–4861 *claims* SQL already allow-lists the
--   pre-auth insert to `failed_attempt`/`password_change` for existing
--   usernames only. **v172 ships no SQL at all, so that claim is UNVERIFIED.**
--   Section 1's check step exists precisely to test it; if no such policy
--   exists, the claim is false and the RPC below is the fix, not a duplicate.
-- - `profiles.username` is unique and lowercase (client lowercases everywhere).
-- - Edge Functions named here (`login-by-email`, `verify-and-reset`,
--   `request-recovery-code`, `cleanup-expired-media`, `delete-view-once`)
--   exist in the live project; their source is NOT in the v172 folder, so
--   every statement about their internals below is a change request, not a
--   description of current behaviour.

-- ----------------------------------------------------------------------

--
-- 0. Check-first preamble — run before any section
-- ------------------------------------------------

-- What policies exist on the security-events table today?
select policyname, cmd, roles, qual, with_check
from pg_policies where tablename = 'account_security_events';

-- Does the table have the columns the client assumes?
select column_name, data_type, is_nullable
from information_schema.columns
where table_name = 'account_security_events';

-- Do the RPCs / functions referenced by the client exist?
select proname, prosecdef from pg_proc
where proname in ('chatbox_lookup_username_by_recovery_email',
                  'chatbox_record_security_event_pre_auth',
                  'chatbox_check_login_lock',
                  'chatbox_record_failed_login');

-- What tables exist that could already hold failed-login state?
select table_name from information_schema.tables
where table_schema = 'public'
  and table_name like '%login%' or table_name like '%lock%';


-- Record the answers in the fix report before proceeding. If
-- `account_security_events` has **no** INSERT policy at all (or an open one),
-- A-01 is confirmed live and Section 1 is urgent. If a restrictive policy
-- already exists, say so and re-scope Section 1 to the RPC + rate limit only.

-- ----------------------------------------------------------------------

--
-- 1. A-01 — pre-auth security-event insert forgery (P1)
-- -----------------------------------------------------

-- **Problem (audit A-01):** `v142RecordSecurityEventPreAuth` inserts directly
-- into `account_security_events` with `user_id = NULL` using only the public
-- anon key. Anyone can forge `failed_attempt` / `password_change` alerts for
-- ANY username, with no rate limit, and a flood pushes genuine events out of
-- the bell's 50-row window (`v142SecuritySync` L4914).

-- **Fix:** replace the direct client insert with a `SECURITY DEFINER` RPC that
-- allow-lists the event type, rejects unknown usernames, and rate-limits per
-- username. Then revoke the anon INSERT path for `user_id IS NULL` rows, while
-- keeping the authenticated insert path working.

-- 1a. Create the RPC:

create or replace function public.chatbox_record_security_event_pre_auth(
  p_username text,
  p_event_type text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user text := lower(trim(coalesce(p_username, '')));
  v_count int;
begin
  -- (1) Allow-list the event type. 'login' is authenticated-only and must
  -- never be recordable pre-auth.
  if p_event_type not in ('failed_attempt', 'password_change') then
    return jsonb_build_object('ok', false, 'error', 'bad_event_type');
  end if;

  -- (2) Reject unknown usernames: a forged row for a non-existent account
  -- must not even be written.
  if not exists (select 1 from public.profiles where username = v_user) then
    return jsonb_build_object('ok', false, 'error', 'unknown_username');
  end if;

  -- (3) Rate-limit: max 5 pre-auth rows per username per hour. A genuine
  -- lockout records exactly 1 row (on the 5th failure); a flood is cut off.
  select count(*) into v_count
  from public.account_security_events
  where username = v_user
    and user_id is null
    and created_at > now() - interval '1 hour';
  if v_count >= 5 then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;

  insert into public.account_security_events
    (user_id, username, event_type, device_label, detail)
  values
    (null, v_user, p_event_type, null, null);

  return jsonb_build_object('ok', true);
end;
$$;

-- The RPC is the only pre-auth writer. Revoke direct execution from
-- nobody: anon/authenticated call it through PostgREST; the function itself
-- runs as its owner (SECURITY DEFINER).
revoke all on function public.chatbox_record_security_event_pre_auth(text, text) from public;
grant execute on function public.chatbox_record_security_event_pre_auth(text, text) to anon, authenticated;


-- 1b. Close the anon INSERT path (keep the authenticated path):

-- CHECK FIRST: list the current INSERT policies (see Section 0). The change
-- below assumes there is one permissive INSERT policy for anon, or none and
-- RLS is off for inserts. Adapt the DROP to the real policy name.
-- Goal state after this step:
--   * anon may NOT insert rows at all (pre-auth writes go via the RPC only).
--   * authenticated may insert ONLY its own rows: user_id = auth.uid().
drop policy if exists "anon_insert_security_events" on public.account_security_events;
drop policy if exists "insert_security_events" on public.account_security_events;

create policy "auth_insert_own_security_events"
  on public.account_security_events
  for insert to authenticated
  with check (user_id = auth.uid());

-- There must be NO insert policy left for the anon role. Verify:
select policyname, cmd, roles from pg_policies
where tablename = 'account_security_events' and cmd = 'INSERT';


-- **Ordering warning:** do 1b only AFTER 1a is deployed AND the client
-- change in 1c is live. Between 1a and 1c, the old client still inserts
-- directly; between 1c and 1b, the RPC is live but the direct path is still
-- open. The window where forgery is possible closes only when both are done.

-- 1c. Client companion (coordinator applies — one line, NOT in this draft):

-- In `v142RecordSecurityEventPreAuth` (L4862–4870), replace
-- `sb().from('account_security_events').insert(row)` with
-- `sb().rpc('chatbox_record_security_event_pre_auth', { p_username: u, p_event_type: type })`.
-- No other call site changes: the authenticated `v142RecordSecurityEvent`
-- keeps its direct insert (covered by the policy in 1b).

-- 1d. Verification (live, after deploy):

-- 1. Anonymous (logged-out) insert into `account_security_events` with
--    `user_id = NULL` is rejected by RLS.
-- 2. RPC with `p_event_type = 'login'` returns `{"ok":false,"error":"bad_event_type"}` and writes
-- nothing.
-- 3. RPC with an unknown username returns `{"ok":false,"error":"unknown_username"}` and writes
-- nothing.
-- 4. RPC with a real username + `failed_attempt` returns `{"ok":true}` and the
--    row appears in the owner's bell (and only in that owner's bell).
-- 5. Six RPC calls for the same username within one hour: the 6th returns
--    `{"ok":false,"error":"rate_limited"}`.
-- 6. A signed-in `password_change` event (`v44ChangePassword` path) still
--    records and still shows in the bell — the authenticated path is not broken.
-- 7. No new request volume: the RPC replaces the insert 1:1.

-- ----------------------------------------------------------------------

--
-- 2. A-03 — story media delete has no server consumer (P1)
-- --------------------------------------------------------

-- **Problem (audit A-03):** `v168QueueStoryMediaDelete` (L9354–9362) queues
-- `{id, url, ts}` in localStorage `chatbox_pending_story_delete_<userId>` and
-- nothing ever reads the queue — no drain function exists (contrast the
-- view-once queue, drained by `v121RetryPendingVoDeletes` on start, L16321).
-- The viewer promises deletion "within 24 hours" (L9194), but the file in the
-- public `chat-media` bucket stays reachable by URL indefinitely. The comment
-- at L9354 states the Edge Function update is "OWED" and that
-- `cleanup-expired-media`'s delete-one branch only handles
-- `messages`/`group_messages` (it coerces any other table to `'messages'` and
-- verifies against a message row) — so story files cannot go on that path
-- (a colliding id could soft-delete an unrelated message row).

-- **Fix:** a `stories`-aware delete branch in the server function, plus a
-- client drain once the branch ships. The branch is Edge Function work, not
-- pure SQL; the SQL below is the ownership check the branch must run, and the
-- rest of this section is a build spec for the function change.

-- 2a. Ownership check the branch must enforce (SQL fragment):

-- The delete-one branch must verify, with the caller's auth.uid(), that the
-- story row belongs to the caller BEFORE deleting any Storage object.
-- Never reuse the messages/group_messages branch for stories.
select id, user_id, media_url
from public.stories
where id = $1            -- the queued story id
  and user_id = auth.uid();
-- If no row is returned: refuse (do not touch Storage, do not drop the
-- queue entry — surface the failure so it can be investigated).


-- 2b. Edge Function build spec — `cleanup-expired-media` (or a new `delete-story-media`):

-- 1. Add a delete-one branch keyed on `table = 'stories'` that:
--    - loads the story row with the check in 2a (caller must own it);
--    - derives the Storage object path from `media_url` (same path logic the
--      upload used — strip the public bucket URL prefix; never accept an
--      arbitrary path from the client);
--    - deletes the object from the `chat-media` bucket with the service-role
--      Storage client;
--    - returns `{ok:true}` only after the Storage delete succeeds (or the
--      object is already gone), so the client drain can drop the queue entry.
-- 2. Do NOT extend the existing `messages`/`group_messages` branch to accept
--    `'stories'` — its table coercion is the hazard named in the audit.
-- 3. Expired-story sweeping (the 24-hour promise): the same function (or its
--    scheduled invocation) should delete the Storage object when a story row
--    expires, not only when the user deletes it. Scope this to stories whose
--    `expires_at` has passed.

-- 2c. Client drain (coordinator applies AFTER 2b ships — not before):

-- Mirror `v121RetryPendingVoDeletes` (L16321, called on start at L4210):
-- on app start, read `chatbox_pending_story_delete_<userId>`, send each
-- queued `{id, url}` to the new stories branch, and drop it from localStorage
-- only on `{ok:true}`. Runs once on start — no new polling, no new request
-- volume beyond one call per queued story.

-- 2d. Verification (live, after deploy):

-- 1. Post a story, delete it: the Storage object is gone (public URL 404s)
--    and the localStorage queue entry is dropped after the next app start.
-- 2. Let a story expire: its Storage object is gone within the sweep window.
-- 3. Attempt to delete another user's story id through the branch: refused,
--    object untouched, queue entry kept.
-- 4. Until 2b ships, do NOT claim stories are deleted — the UI copy
--    ("Will be deleted within 24 hours") is currently untrue at the Storage
--    layer. That wording stays as-is in the client until the server half lands.

-- ----------------------------------------------------------------------

--
-- 3. P1-01 / P1-02 / P1-3 cluster — server lockout + oracle revoke (P1)
-- ---------------------------------------------------------------------

-- **Problem (audit re-audit table):** the login lockout is client-side only
-- (localStorage, per browser/device — P1-01, still present by design); the
-- email→username oracle RPC `chatbox_lookup_username_by_recovery_email` is
-- still callable by anon and the signup form now *shows* its result
-- ("That email is already linked to another account", L3972–3974 — P1-3);
-- P1-02 is fixed client-side (email path now fails closed on lookup failure),
-- which is exactly why the revoke SQL must NOT be run until `login-by-email`
-- enforces the username lock — revoking first would break recovery-email
-- login for everyone (code comment L18004–18013, correct sequencing).

-- **Order matters. Do these in order, verifying each stage live before the next:**

-- 3a. Stage 1 — server-side failed-login table + lockout RPC:

-- CHECK FIRST: does a failed-login table already exist (see Section 0)?
-- If one exists with different columns, adapt — do not create a second one.
create table if not exists public.chatbox_failed_logins (
  id bigint generated always as identity primary key,
  username text not null,
  attempted_at timestamptz not null default now(),
  -- Record the lockout that resulted, if any, so the lock can be inspected.
  locked_until timestamptz
);
create index if not exists chatbox_failed_logins_username_at
  on public.chatbox_failed_logins (username, attempted_at desc);

-- RLS: nobody reads/writes this table directly from the client. All access
-- goes through the RPCs below (SECURITY DEFINER).
alter table public.chatbox_failed_logins enable row level security;
-- (Intentionally no policies: direct client access is denied by default
-- when RLS is enabled with no policies. Verify that is the behaviour on
-- the live project before relying on it.)

create or replace function public.chatbox_record_failed_login(p_username text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user text := lower(trim(coalesce(p_username, '')));
  v_fails int;
  v_locks int;
begin
  if v_user = '' then
    return jsonb_build_object('ok', false, 'error', 'bad_username');
  end if;
  insert into public.chatbox_failed_logins (username) values (v_user);
  -- Count failures since the last successful login. The client clears its
  -- local counter on success; the server needs the same reset — see the
  -- companion note in 3d (login-by-email / login success must delete the
  -- rows for the username, or the lock can never clear).
  select count(*) into v_fails
  from public.chatbox_failed_logins
  where username = v_user
    and attempted_at > now() - interval '24 hours';
  -- Lockout thresholds mirror the client: 5 failures -> lock, 5 min first
  -- cycle then +1 min per cycle. The lock length needs the cycle count;
  -- derive it from prior locks, not from a client-supplied number.
  select count(*) into v_locks
  from public.chatbox_failed_logins
  where username = v_user and locked_until is not null;
  if v_fails >= 5 then
    update public.chatbox_failed_logins
    set locked_until = now() + make_interval(mins => 5 + v_locks)
    where username = v_user and locked_until is null
      and attempted_at > now() - interval '24 hours';
    return jsonb_build_object('ok', true, 'locked', true,
      'locked_until', now() + make_interval(mins => 5 + v_locks));
  end if;
  return jsonb_build_object('ok', true, 'locked', false, 'fails', v_fails);
end;
$$;
grant execute on function public.chatbox_record_failed_login(text) to anon, authenticated;

create or replace function public.chatbox_check_login_lock(p_username text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user text := lower(trim(coalesce(p_username, '')));
  v_until timestamptz;
begin
  select max(locked_until) into v_until
  from public.chatbox_failed_logins
  where username = v_user and locked_until > now();
  if v_until is not null then
    return jsonb_build_object('locked', true, 'locked_until', v_until);
  end if;
  return jsonb_build_object('locked', false);
end;
$$;
grant execute on function public.chatbox_check_login_lock(text) to anon, authenticated;


-- **Client companion (Stage 1):** `doAuth` and the change-password form call
-- `chatbox_check_login_lock` before attempting credentials and
-- `chatbox_record_failed_login` on a credential failure, INSTEAD of (or in
-- addition to, during migration) the localStorage counters. The localStorage
-- lockout stays as a UX fallback only — it must never again be described as
-- enforcement. This client change is a separate fix task for the coordinator;
-- it is not in `auth_security.diff`.

-- 3b. Stage 2 — `login-by-email` enforces the username lock:

-- Edge Function change (source not in this repo — spec, not a patch):

-- 1. After resolving the recovery email to a username (server-side, never
--    revealing it to the caller), call `chatbox_check_login_lock(username)`.
-- 2. If locked, return a locked error and issue NO session — the same
--    fail-closed behaviour the client now has at L18041–18061.
-- 3. On a successful login (either path), clear the server-side failure rows
--    for that username (the reset that makes a lock clearable — without this,
--    Stage 1 locks forever) and clear the client's localStorage lock keys as
--    today.
-- 4. On a failed password check, record via `chatbox_record_failed_login`
--    (so email-path failures count toward the same lock as username-path
--    failures — today the email path records lock events under the email
--    address, which the bell never shows; see audit P2-05).

-- **Verification for Stage 2 (live):** lock an account to 5 failures via the
-- username path, then attempt recovery-email login with the correct password:
-- it must be refused while locked and accepted after the lock expires.
-- Recovery-email login for a never-locked account still works.

-- 3c. Stage 3 — ONLY after Stage 2 is verified live: revoke the oracle RPC:

-- RUN THIS ONLY AFTER 3b is verified live. Running it earlier breaks
-- recovery-email login for everyone (P1-02 fail-closed + the RPC fallback
-- at L18101 is the only other path).
-- CHECK FIRST: confirm login-by-email is the live path (Stage 2 verified)
-- and note the current grantee list for the function.
select p.proname, r.rolname as grantee
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
left join lateral aclexplode(p.proacl) a on true
left join pg_roles r on r.oid = a.grantee
where n.nspname = 'public'
  and p.proname = 'chatbox_lookup_username_by_recovery_email';

revoke execute on function public.chatbox_lookup_username_by_recovery_email(text)
  from anon, authenticated;
-- If the function is no longer needed at all, drop it instead:
-- drop function if exists public.chatbox_lookup_username_by_recovery_email(text);


-- **Client companion (Stage 3, same release as the revoke):** the signup
-- duplicate-email check at L3972–3974 and the forgot-reset lookup at L17985
-- must stop calling the revoked RPC and stop *showing* its result. Signup
-- must answer with a generic message ("If that email is already registered,
-- use login or password reset") whether or not the email exists — the current
-- "That email is already linked to another account" text is the oracle made
-- visible. The forgot-reset flow must not depend on the lookup to record its
-- `password_change` event or to clear the username lock (see §4, P2-03).

-- 3d. Verification for the whole cluster (live, after Stage 3):

-- 1. Five wrong passwords from a fresh browser/incognito lock the account
--    server-side; a sixth attempt (any device) is refused before a credential
--    check runs.
-- 2. The lock expires on its own; the correct password then works and the
--    failure count resets.
-- 3. Recovery-email login honours the same lock (Stage 2 check above).
-- 4. `chatbox_lookup_username_by_recovery_email` called with the anon key is
--    rejected; signup with an already-registered email no longer reveals that
--    fact.
-- 5. A-07's honest-notice wording still holds: a lock is a login gate, and a
--    live session is unaffected until the server revokes it (see §4, session
--    revocation — not part of this cluster).

-- ----------------------------------------------------------------------

--
-- 4. Related Edge Function notes (same approval round — spec only)
-- ----------------------------------------------------------------

-- These ride the same functions as Sections 1–3. None is SQL; all need the
-- function source, which is not in the v172 folder.

-- 4a. A-08 (server half) — `verify-and-reset` should revoke other sessions:

-- After a successful password reset, revoke all refresh tokens for the user
-- (Supabase Admin API / `auth.admin.signOut(userId)`) — the same revocation
-- `v44ChangePassword` already does client-side for the signed-in path
-- (L17782–17791). The client wording was fixed in `auth_security.diff`
-- (A-08) to stop implying the reset alone secures the account; the server
-- change is what makes the implication true. Verify live: reset the password,
-- then check that a session on a second device is dead.

-- 4b. P2-03 (server half) — `verify-and-reset` should return the username:

-- `v44ForgotReset` (L17985–17987) clears the username-key login lock only
-- when the `chatbox_lookup_username_by_recovery_email` RPC succeeds; on
-- lookup failure `_v142fu = ''` and only the email key is cleared, so the
-- username lock survives a reset that is itself proof of ownership. The
-- client cannot fix this — it does not know the username when the lookup
-- fails. Have `verify-and-reset` return the username on success (the caller
-- proved ownership with the code); the client then clears the username-key
-- lock unconditionally on `data.ok`. Note: after the Stage 3 revoke this
-- becomes the ONLY way the client learns the username — do 4b in the same
-- release as 3c, or the forgot-reset lock-clear regresses.

-- 4c. P2-12 — recovery-code guarantees (verify before claiming):

-- Confirm server-side in `request-recovery-code` / `verify-and-reset`: code
-- expiry (client asserts "valid for 10 minutes", L17963), single-use, and an
-- attempt cap (client surfaces `too_many_attempts`, L17993). The resend
-- cooldown (60 s, L4092) is reload-resettable client-side and is not a server
-- limit. If any guarantee is missing server-side, add it in the same round —
-- do not rely on the client-side checks.

-- ----------------------------------------------------------------------

--
-- 5. What this draft deliberately does NOT cover
-- ----------------------------------------------

-- - **P1-2 / P2-4 / P2-5 / P2-6 (polls, messages/group_messages UPDATE,
--   group_members DELETE, chat_games UPDATE RLS):** still UNPROVEN — v172
--   ships no SQL, so there is nothing to draft against. Those need a live
--   Supabase policy inspection first, not a blind draft.
-- - **P1-4 (view-once `delete-view-once` deployment):** unverifiable from
--   these files; needs a live function-list + a viewed-file reachability
--   check, not SQL.
-- - **P2-7 (public `chat-media` bucket):** by design; the mitigations are the
--   server deletes in §2 and the view-once delete function, not a policy
--   rewrite.
-- - **A-07's full fix (session revocation on lockout):** needs the same
--   server failed-login table as §3 plus a token-revocation call at the lock
--   threshold — a follow-up once §3 Stage 1 exists. The client notice shipped
--   in `auth_security.diff` is the honest interim, not the enforcement.


-- ======================================================================
-- §2 — DM & MEDIA (C-01, C-02, C-03, C-12, C-14)
-- ======================================================================
-- Source draft: sql_dm_media.md (verbatim conversion;
-- prose -> comments, ```sql blocks -> SQL unchanged).

--
-- SQL / SERVER DRAFT — CHATBOX V172 §3/§8 (DM & MEDIA) — C-01, C-02, C-03, C-12, C-14
-- -----------------------------------------------------------------------------------

-- - **Status:** DRAFT ONLY. Nothing in this file has been run. No SQL was executed
--   while preparing it, no Edge Function was deployed, no file was deleted.
--   Hold for user approval; the coordinator applies it only on the user's word.
-- - **Source:** `audit_dm_media.md` findings C-01, C-02, C-03 (P1), C-12, C-14 (P2).
--   Client-side fixes for the same findings live in `dm_media.diff` (C-12 toast
--   relabel only; C-01/C-02/C-03/C-14 have no client fix — see
--   `dm_media_fix_report.md`).
-- - **Style:** check-first. Every section starts with the check that decides
--   whether the step is even needed, then the draft. Verify table/column names
--   against the LIVE database before running anything — the drafts below are
--   written from what `index.html` shows the client reading/writing, not from a
--   live schema dump.
-- - **Facts the drafts rely on (from the client file, verified by grep):**
--   - Storage bucket `chat-media`; story files live under `stories/<uid>/…` and
--     `stories-audio/<uid>/…`; message media under the message paths the client
--     already queues.
--   - `stories` columns the client writes: `user_id, text, emoji, bg,
--     expires_at, media_url, audio_url, text_color, text_size, text_position,
--     text_bg, story_filter, visible_to` (+ `id`, `created_at`).
--   - `messages` rows never change on unsend — the unsend is
--     `message_meta(message_id, deleted_at, forwarded)`; `group_messages` carries
--     `deleted_at` directly. View-once state is `messages.view_once` /
--     `messages.view_once_viewed` (same columns on `group_messages`).
--   - Edge Functions the client calls: `cleanup-expired-media`
--     (`{mode:'delete-one', table, id, url}`), `delete-view-once`
--     (`{table, message_id, path}`, POST with the user's access token),
--     `link-preview`.
--   - Disappearing-message purge the client calls:
--     `rpc('chatbox_disappearing_purge', {p_chat_id, p_delete_window})`.
--   - `profiles` has exactly 13 live columns (`id, created_at, username,
--     display_name, bio, birthday_md, avatar_color, avatar_emoji, avatar_url,
--     wallpaper, theme, read_receipts, last_seen`). NEVER select `birthday`
--     (no such column) or `phone` (lives in `profile_phones`, not `profiles`).

-- ----------------------------------------------------------------------

--
-- C-01 — Storage-file deletion depends on undeployed Edge Functions (P1)
-- ----------------------------------------------------------------------

-- Check first (no deploy, no SQL):
-- 1. In the Supabase dashboard → Edge Functions, confirm `cleanup-expired-media`
--    and `delete-view-once` exist AND are deployed (not just source in a repo —
--    the v172 delivery ships no `functions/` directory at all).
-- 2. Confirm the `CLEANUP_SECRET` secret is set on `cleanup-expired-media`
--    (the client comment at L5096 says the invoke "fails silently" before
--    deployment — a missing secret fails the same silent way).
-- 3. Confirm a sweep schedule exists (pg_cron or the project's existing cleanup
--    schedule) that calls `cleanup-expired-media` for expiry/retention, so the
--    queues can drain without a user opening the app.
-- 4. Confirm `link-preview` is deployed too (same owed item, finding C-09).
-- 5. Live round-trip, after 1–4 pass: unsend a photo in a DM and view a
--    view-once photo, then check in Storage that the objects are actually gone
--    (not just hidden in the UI). Also confirm the localStorage queues
--    (`chatbox_pending_media_delete_<userId>`, cap 200;
--    `chatbox_pending_vo_delete_<userId>`, cap 50) drain to empty on next app
--    start — a queue that never drains is the visible symptom of an undeployed
--    function.
-- 6. If any of 1–4 fails: DO NOT claim deletion works. The UI currently tells
--    the user the file is gone while the public `chat-media` URL stays reachable
--    indefinitely. That is the P1.

-- If a function is missing (server work, not a client fix):
-- - Deploy `cleanup-expired-media` and `delete-view-once` from their source
--   (source is not in the v172 folder — locate it in the project repo first;
--   do not re-create the functions from the client's invoke shape alone).
-- - No SQL in this section: nothing about the schema needs to change for C-01.

-- Parked client hardening (NOT applied in this fix round):
-- - The audit proposed surfacing the pending-delete queue depth in Settings
--   (one localStorage read on the Settings open path, zero extra requests) so an
--   undeployed function is visible instead of silent. Not in `dm_media.diff` —
--   it was outside this fixer's assigned list (C-05, C-10–C-14). Coordinator:
--   apply as a separate one-line change if the user wants it.

-- ----------------------------------------------------------------------

--
-- C-02 — Group view-once: first member to open it consumes it for everyone (P1)
-- -----------------------------------------------------------------------------

-- Check first:
-- 1. Confirm the current behaviour on a live group: B opens a view-once photo,
--    C then sees only "Opened" and can never view it. (Code evidence:
--    `v117MarkViewOnceViewed()` sets the single shared flag
--    `view_once_viewed:true` and deletes the file immediately; zero hits for
--    `view_once_viewed_by` anywhere in the client.)
-- 2. Confirm the `messages` / `group_messages` columns `view_once` and
--    `view_once_viewed` exist live, and check whether any per-recipient view
--    table already exists (if one does, this whole section collapses to "wire
--    the client to it").

-- Draft SQL (run only after the checks; verify names live first):
-- Per-recipient view-once state. One row per (message, viewer).
-- Works for both tables: group messages use group_message_id, 1-to-1
-- messages use message_id (exactly one of the two is non-null per row).
create table if not exists view_once_views (
  message_id       bigint references messages(id) on delete cascade,
  group_message_id bigint references group_messages(id) on delete cascade,
  group_id         bigint references chat_groups(id) on delete cascade,
  viewer_id        uuid not null,
  viewed_at        timestamptz not null default now(),
  constraint view_once_views_one_target
    check ((message_id is null) <> (group_message_id is null)),
  primary key (message_id, group_message_id, viewer_id)
);

alter table view_once_views enable row level security;

-- A member may record their own view, and read views for messages in
-- groups they belong to. (Adjust the membership check to the live
-- group_members shape before running.)
create policy view_once_views_insert_own on view_once_views
  for insert with check (viewer_id = auth.uid());
create policy view_once_views_select_member on view_once_views
  for select using (
    viewer_id = auth.uid()
    or exists (
      select 1 from group_members gm
      where gm.group_id = view_once_views.group_id
        and gm.user_id = auth.uid()
    )
  );


-- Server-function change (draft — `delete-view-once`):
-- - Today the function deletes the Storage file as soon as ANY viewer opens it.
--   Change the rule to: delete the file only when EVERY current member of the
--   group has a `view_once_views` row for that message (or when the message
--   expires / the sender deletes it). The function must take the viewer list
--   into account before deleting — it receives `{table, message_id, path}` today,
--   so extend its input with the group id (or resolve the group from the
--   message row server-side) and count remaining unviewed members itself.
-- - 1-to-1 behaviour is unchanged: a single viewer still consumes the photo
--   (the shared `view_once_viewed` flag stays correct there).

-- Client contract after this SQL lands (follow-up work, NOT in this diff):
-- - The client must check "have *I* viewed it" (its own `view_once_views` row)
--   instead of the shared `view_once_viewed` flag, and render "Opened" per
--   viewer. `v117MarkViewOnceViewed()` inserts the per-viewer row instead of
--   setting the shared flag for groups. No client-only fix exists — do not
--   attempt one (the file itself is deleted after the first view today).

-- Verify after landing:
-- - Group of 3: A sends view-once photo; B opens (file still there); C opens
--   (file still there, both see it); after the last member views, the Storage
--   object is gone. 1-to-1 view-once still consumes on first view.

-- ----------------------------------------------------------------------

--
-- C-03 — Deleted/expired story files have a queue with no consumer (P1)
-- ---------------------------------------------------------------------

-- Check first:
-- 1. Confirm nothing reads `chatbox_pending_story_delete_<userId>` back
--    (code evidence: `v168DeleteStoryFiles()` writes it; zero readers in the
--    file — the queue is write-only today).
-- 2. Confirm the `cleanup-expired-media` `delete-one` branch really coerces any
--    other table to `messages` and verifies against a message row (read the
--    deployed function source — do NOT route story deletes through `delete-one`:
--    the coercion could soft-delete an unrelated message row with a colliding id).
-- 3. Confirm the client has no Storage DELETE policy (the direct
--    `storage.remove()` in `v168DeleteStoryFiles()` fails silently today).

-- Draft Edge Function change (extend `cleanup-expired-media`):
-- Add a `mode:'delete-story'` branch that:
-- - takes a story id + URL (and optional audio URL),
-- - verifies the caller owns the story (`stories.user_id = auth.uid()`) OR the
--   story row is already gone (expired/deleted — the row delete and the file
--   delete are separate steps, and the expiry cleanup deletes the row first),
-- - verifies the URL is under `stories/` or `stories-audio/` (reject anything
--   else — never delete an arbitrary bucket path on a client-supplied URL),
-- - deletes the Storage object(s) with the service-role key and returns ok.

-- (fenced json block from the draft, commented out)
--   // client → function request shape (draft; the client side is NOT wired yet)
--   { "mode": "delete-story", "story_id": 123, "url": "stories/<uid>/…", "audio_url": "stories-audio/<uid>/…" }


-- Client follow-up (draft sketch for the coordinator — NOT applied in this diff):
-- Add `v168RetryPendingStoryDeletes()`, mirroring `v142RetryPendingMediaDeletes()`,
-- called at startup, draining `chatbox_pending_story_delete_<userId>` through the
-- new `delete-story` branch. Sketch only — the coordinator writes and tests it
-- once the server branch exists:
-- (fenced js block from the draft, commented out)
--   // sketch — do not paste blindly; mirror v142RetryPendingMediaDeletes() (L5051)
--   async function v168RetryPendingStoryDeletes(){
--     try{
--       var key = 'chatbox_pending_story_delete_' + me.id;
--       var list = JSON.parse(localStorage.getItem(key) || '[]');
--       if(!list.length) return;
--       var kept = [];
--       for(var i = 0; i < list.length; i++){
--         var it = list[i];
--         try{
--           var res = await sb().functions.invoke('cleanup-expired-media',
--             { body: { mode:'delete-story', story_id: it.story_id, url: it.url, audio_url: it.audio_url } });
--           if(res && !res.error) continue; // deleted — drop from the queue
--         }catch(e){}
--         kept.push(it);
--       }
--       localStorage.setItem(key, JSON.stringify(kept));
--     }catch(e){}
--   }


-- Verify after landing:
-- - Delete a story → its photo/video/audio object is gone from Storage and the
--   queue entry drains. Let a story expire → same. Queue an entry while the
--   function is (hypothetically) down, bring it back → the entry drains on next
--   app start.

-- ----------------------------------------------------------------------

--
-- C-12 — "Delete for me only" is device-local (P2; client toast fixed, sync owed)
-- -------------------------------------------------------------------------------

-- What the client fix already did:
-- - `doMsgDeleteForMe()` and `v161GroupDeleteForMe()` now toast
--   "Hidden on this device only" instead of "Message hidden for you only"
--   (`dm_media.diff`, hunk C-12). The localStorage behaviour is unchanged and
--   honest: the hide works on this device.

-- Check first:
-- 1. Confirm no per-user hidden table exists live (code evidence: the hide writes
--    only to `chatbox_hidden_for_me_<userId>` / `chatbox_hidden_for_me_group_<userId>`;
--    the only server-side per-user hide in the file is "Clear chat" via
--    `chat_clears` — do NOT fake sync by writing to `chat_clears`, that would
--    clear the whole chat, not one message).

-- Draft SQL:
-- Per-user, per-message hide. One row per (user, message).
create table if not exists hidden_messages (
  user_id          uuid not null,
  message_id       bigint references messages(id) on delete cascade,
  group_message_id bigint references group_messages(id) on delete cascade,
  hidden_at        timestamptz not null default now(),
  constraint hidden_messages_one_target
    check ((message_id is null) <> (group_message_id is null)),
  primary key (user_id, message_id, group_message_id)
);

alter table hidden_messages enable row level security;

create policy hidden_messages_own on hidden_messages
  for all using (user_id = auth.uid())
  with check (user_id = auth.uid());


-- Client contract after this SQL lands (follow-up work, NOT in this diff):
-- - `doMsgDeleteForMe()` / `v161GroupDeleteForMe()` upsert the row AND keep the
--   localStorage write as the instant offline path.
-- - `filterVisibleMessages()` / `appendMessage()` (and the group equivalents)
--   consult the table with one batched `in('message_id', …)` read per chat open
--   — same shape as the existing `chat_clears` read — and merge it with the
--   local list. Until then the toast stays "on this device only".

-- Verify after landing:
-- - Hide a message on the phone → it is hidden on the PC too, and stays hidden
--   after localStorage is cleared on the phone.

-- ----------------------------------------------------------------------

--
-- C-14 — Disappearing-message expiry hard-delete depends on an unverified RPC (P2)
-- --------------------------------------------------------------------------------

-- Check first (this is the whole point — do not assume the RPC exists):
-- 1. Check whether `chatbox_disappearing_purge` exists in the live database
--    (e.g. `select proname from pg_proc where proname =
--    'chatbox_disappearing_purge';` or the Supabase dashboard → Database →
--    Functions). The v172 folder ships no SQL for it and nothing in the file
--    defines it.
-- 2. If it exists, read its definition and confirm it hard-deletes (not just
--    hides) and that it also handles the media files (via the media-delete path)
--    and reactions. If it does not exist, the client today only HIDES expired
--    messages locally (`refreshMessages()` filters by the cutoff; inbox previews
--    relabel them "Message expired") while the rows — including their media —
--    remain server-side indefinitely.
-- 3. Confirm expiry only runs on chat open today (`purgeExpiredDisappearing()` is
--    called only from `openChatById()`; throttled to once per chat per 5 min) —
--    a chat nobody opens keeps its expired rows.

-- Draft SQL (only if the RPC is missing or incomplete):
-- Hard-deletes expired disappearing messages for one conversation.
-- p_delete_window = true deletes the whole current ON window (used when the
-- user turns disappearing messages OFF); false deletes only rows older than
-- the window. SECURITY DEFINER so the caller can delete rows they
-- participate in without a broad delete policy; the participation check
-- inside is the boundary — verify the conversations membership shape live
-- (user_a/user_b) before running.
create or replace function chatbox_disappearing_purge(p_chat_id bigint, p_delete_window boolean)
returns integer
language plpgsql
security definer
as $$
declare
  v_ms      bigint;
  v_set_at  timestamptz;
  v_cutoff  timestamptz;
  v_deleted integer := 0;
begin
  -- Caller must be a participant of the conversation.
  if not exists (
    select 1 from conversations c
    where c.id = p_chat_id and (c.user_a = auth.uid() or c.user_b = auth.uid())
  ) then
    return 0;
  end if;

  select disappearing_ms, disappearing_set_at into v_ms, v_set_at
  from conversations where id = p_chat_id;

  if p_delete_window then
    v_cutoff := now();  -- whole current window
  else
    if v_ms is null or v_ms <= 0 then return 0; end if;
    v_cutoff := greatest(now() - make_interval(msecs => v_ms), coalesce(v_set_at, now() - make_interval(msecs => v_ms)));
  end if;

  -- Delete message_meta first (unsend state), then reactions, then rows.
  -- Storage files: queue via the same media-delete path the client uses
  -- (cleanup-expired-media delete-one) — the RPC itself must not delete
  -- Storage objects it has not verified against a message row.
  delete from message_meta
  where message_id in (select id from messages where chat_id = p_chat_id and created_at < v_cutoff);
  delete from message_reactions
  where message_id in (select id from messages where chat_id = p_chat_id and created_at < v_cutoff);
  delete from messages where chat_id = p_chat_id and created_at < v_cutoff;
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;


-- Scheduled sweep (so expiry does not depend on anyone opening the chat):
-- - Add a pg_cron job (or extend the existing cleanup schedule from C-01) that
--   calls `chatbox_disappearing_purge` for every conversation with
--   `disappearing_ms > 0` — e.g. hourly. Draft the schedule only after the RPC
--   is verified; the exact cron expression belongs to the project's existing
--   schedule conventions, not this draft.

-- Client change: none required:
-- - The client already calls the RPC with the exact signature above
--   (`purgeExpiredDisappearing()` on chat open; `setSharedDisappearing()` with
--   `p_delete_window:true` when turning OFF, and it reverts the toggle if the
--   RPC errors). Do NOT add a per-tick purge (quota: Dec cycle zero-tolerance).

-- Verify after landing:
-- - Turn disappearing messages ON (e.g. 24 h) in a test chat, send a message,
--   force the cutoff (or wait), confirm the row is gone server-side (not just
--   hidden) and the media file is queued/deleted. Confirm a chat nobody opens
--   still gets swept by the schedule.

-- ----------------------------------------------------------------------

--
-- What is deliberately NOT in this draft
-- --------------------------------------
-- - The two known orphan Storage files (v168 P2-19): nothing in the file or
--   folder identifies their paths. Do NOT delete anything on their account —
--   the deletion needs user approval and the paths first.
-- - `link-preview` deployment (C-09): same owed item as C-01 §1–4; no SQL.
-- - 15-minute edit-window server enforcement (C-08) and message length cap
--   (C-07): outside this fixer's assigned list.
-- - Any change to the version stamp (`__CHATBOX_VERSION__` /
--   `__CHATBOX_RELEASE_DATE__`) or `sw.js` — the coordinator stamps those.


-- ======================================================================
-- §3 — GAMES & POLLS (E-06, F11, S-1, F03)
-- ======================================================================
-- Source draft: sql_games_polls.md (verbatim conversion;
-- prose -> comments, ```sql blocks -> SQL unchanged).

--
-- CHATBOX V172 — SQL DRAFT: GAMES/POLLS ITEMS THAT CANNOT BE FIXED IN THE CLIENT
-- ------------------------------------------------------------------------------

-- **Status: DRAFT ONLY — NOT RUN. Do not paste this into Supabase blindly.**
-- Written by the v172 games/polls fixer (20 Nov 2026) from the v172 audit
-- (`audit_games_polls.md` §1 E-06 and §6). Each section states what it does,
-- what must be checked live first, and how to verify it afterwards. All three
-- items are idempotent (`IF NOT EXISTS` / `DROP TRIGGER IF EXISTS` + recreate),
-- so re-running converges live state to the text below. Run them in the
-- Supabase SQL editor, one section at a time, and stop if any live-shape
-- check fails — a second table/column with the same name must never be created.

-- ----------------------------------------------------------------------

--
-- 1. E-06 — `group_poll_votes` gets a `group_id` column so its realtime subscription can be filtered (P2)
-- -------------------------------------------------------------------------------------------------------

-- **Why SQL is needed:** the `group_poll_votes` realtime subscription in
-- `subscribeGroupChat` (v172 L11243) is unfiltered because the table has no
-- `group_id` column to filter on — every vote in every group the user belongs
-- to (RLS-scoped) reaches `v117OnPollVoteChange` and no-ops via the
-- `v117PollIdToMsg` lookup when the poll is not loaded. Wasted events and
-- handler wake-ups, not wrong behaviour. The client cannot fix this: there is
-- no column to filter on. (The sibling `group_polls` subscription at L11246
-- was already filtered in v168/F13; this closes the second half of F13.)

-- 1a. Check the live shape first. STOP if group_poll_votes already has a
--     group_id column of a different type, or if group_polls.group_id is
--     not bigint.
select column_name, data_type
  from information_schema.columns
 where table_schema = 'public' and table_name = 'group_poll_votes';

-- 1b. Add the column (nullable at first so the backfill can run).
alter table public.group_poll_votes
  add column if not exists group_id bigint
  references public.chat_groups(id) on delete cascade;

-- 1c. Backfill from the parent poll.
update public.group_poll_votes v
   set group_id = gp.group_id
  from public.group_polls gp
 where gp.id = v.poll_id and v.group_id is null;

-- 1d. Verify the backfill left no NULLs before making it NOT NULL.
select count(*) as votes_with_no_group
  from public.group_poll_votes where group_id is null;
-- If the count above is 0, tighten the column:
-- alter table public.group_poll_votes alter column group_id set not null;

create index if not exists idx_group_poll_votes_group
  on public.group_poll_votes(group_id);

-- 1e. Keep it maintained: derive group_id from the parent poll on every
--     insert / poll_id change. (The client vote upsert does NOT set
--     group_id — a trigger is the durable enforcement, not client text.)
create or replace function public.chatbox_poll_vote_set_group()
returns trigger language plpgsql as $$
begin
  select group_id into new.group_id
    from public.group_polls where id = new.poll_id;
  return new;
end $$;
drop trigger if exists trg_poll_vote_set_group on public.group_poll_votes;
create trigger trg_poll_vote_set_group
  before insert or update of poll_id on public.group_poll_votes
  for each row execute function public.chatbox_poll_vote_set_group();


-- **Client follow-up (a LATER client change, only after this SQL is live):**
-- add `filter:'group_id=eq.'+groupId` to the `group_poll_votes` subscription at
-- L11243, exactly as L11246 does for `group_polls`. Do NOT add the filter
-- before the column exists, or votes will stop arriving. After both ship,
-- verify by voting in group A while group B's poll card is open: no
-- `v117OnPollVoteChange` wake-up for B's poll, and A's counts still update live.

-- ----------------------------------------------------------------------

--
-- 2. F11 — server-side validation of poll `options` (2–5 options, ≤100 chars each) (P2)
-- -------------------------------------------------------------------------------------

-- **Why SQL is needed:** `group_polls.options` is bare `jsonb` (see
-- `supabase-v168.sql` L282: "options is bare jsonb — no server-side check").
-- The client enforces 2–5 options / 100 chars, but a crafted insert bypasses
-- it. The v119 vote-guard trigger already bounds `option_index` at vote time;
-- this only closes the crafted-insert path.

-- 2a. Check live rows first. STOP (and clean up or leave the CHECK off)
--     if any existing poll violates it — adding the CHECK would fail.
select id, group_id, jsonb_array_length(options) as n_opts
  from public.group_polls
 where jsonb_typeof(options) <> 'array'
    or jsonb_array_length(options) not between 2 and 5
    or exists (select 1 from jsonb_array_elements_text(options) as o
                where char_length(o) > 100);

-- 2b. Add the CHECK (idempotent name; drop + re-add converges on re-run).
alter table public.group_polls
  drop constraint if exists group_polls_options_2_5_max100;
alter table public.group_polls
  add constraint group_polls_options_2_5_max100 check (
    jsonb_typeof(options) = 'array'
    and jsonb_array_length(options) between 2 and 5
    and not exists (
      select 1 from jsonb_array_elements_text(options) as o
      where char_length(o) > 100)
  );


-- **Verify:** an insert with 1 option, 6 options, or a 101-char option must be
-- rejected by the database; a normal 2–5 option poll (client path) still
-- creates fine. No client change is needed — the client already enforces the
-- same bounds.

-- ----------------------------------------------------------------------

--
-- 3. S-1 — server-side 3-pending-invite cap trigger on `chat_games` (carried, SQL-owed)
-- -------------------------------------------------------------------------------------

-- **Why SQL is needed:** the client count-then-insert in `v165StartGroupGame`
-- (v172 L29219–29224) still admits in its own comment that "a simultaneous
-- race can overshoot by one". The 10-minute expiry clears an overshoot, but
-- only the server can enforce the cap. `supabase-v168.sql` contains zero
-- `TRIGGER` statements and no `chat_games` cap trigger.

-- 3a. Trigger function: when a new row is an invited group game, count the
--     group's existing invited rows (locking them) and reject the insert
--     once 3 are already pending. Playing / finished / declined / expired
--     rows are never counted and never touched.
create or replace function public.chatbox_cap_group_game_invites()
returns trigger language plpgsql as $$
declare _n int;
begin
  if new.status = 'invited' and new.group_id is not null then
    select count(*) into _n
      from public.chat_games
     where group_id = new.group_id and status = 'invited'
       for update;
    if _n >= 3 then
      raise exception 'too many unanswered game invites in this group';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists trg_cap_group_game_invites on public.chat_games;
create trigger trg_cap_group_game_invites
  before insert on public.chat_games
  for each row execute function public.chatbox_cap_group_game_invites();


-- **Known limit of this draft (stated honestly):** `FOR UPDATE` locks the
-- counted rows, so two simultaneous inserts that both see ≥1 pending invite
-- serialise correctly — but when zero invited rows exist there is nothing to
-- lock, so two simultaneous *first* invites can still both pass. The client
-- cap and the 10-minute expiry remain the backstop for that corner, exactly as
-- today. A fully airtight cap needs an advisory lock
-- (`pg_advisory_xact_lock`) or a serializable check instead of the
-- `FOR UPDATE` count; that is a deliberate follow-up, not smuggled in here.

-- **Verify:** with 3 pending invites in a group, a 4th `chat_games` insert
-- with `status='invited'` must fail with the exception above, and the client
-- must show its existing "Too many unanswered game invites…" toast (the
-- insert-error path in `v165StartGroupGame` already handles a failed insert).
-- Inserts for other groups, and `playing`/`finished` rows, must be unaffected.

-- ----------------------------------------------------------------------

--
-- 4. F03 — NO new SQL (verify-only note, do not re-run)
-- -----------------------------------------------------

-- The v132-hardened `group_poll_votes_update_self` policy (membership check)
-- already shipped in `supabase-v168.sql` §5 as a conditional DO block that
-- replaces the policy when live lacks it and no-ops with a notice when it is
-- already hardened. Whether that SQL was actually run live cannot be
-- determined from code alone. Close-out needs a live read only — no new SQL:

select policyname, pg_get_expr(qual, 'public.group_poll_votes'::regclass) as qual
  from pg_policies
 where schemaname = 'public' and tablename = 'group_poll_votes'
   and policyname = 'group_poll_votes_update_self';
-- PASS when the qual contains a group_members membership join; if it is
-- still the v117 text (no membership check), run supabase-v168.sql §5 live.



-- ======================================================================
-- §4 — NOTIFICATIONS / SETTINGS (S09 P0-1 mute store — PARKED)
-- ======================================================================
-- Source draft: sql_notif_settings.md (verbatim conversion;
-- prose -> comments, ```sql blocks -> SQL unchanged).

--
-- S09 P0-1 — SERVER PUSH STILL IGNORES MUTE / OPEN-CHAT (PARKED) — SQL + EDGE FUNCTION DRAFT
-- ------------------------------------------------------------------------------------------

-- DRAFT ONLY. Nothing here has been run, deployed, or applied. This note exists so
-- the coordinator / user can approve the server-side work separately. It needs:
-- (1) a SQL migration run in Supabase, (2) a `send-push` Edge Function redeploy,
-- (3) the user's separate deploy approval. Client-only fixes cannot close this:
-- mute lives only in the recipient's `localStorage` (`v5.muted`, v163 disjoint
-- namespaces) and is never synced to any server table today.
--
-- Source: `audit_notif_settings.md` §3 (S09 P0-1) + v168 `hidden_files/v168_audit_s09_notif.md` §3/§9.
-- Evidence re-verified in v172: `sendPushForMessage` (L4639) guards only missing
-- ids + `recipientId===me.id`; `sendCallPush` (L4647) and `sendGroupPush` (L4650)
-- have no per-member mute check; `files/chatbox-send-push/index.ts` verifies the
-- JWT, skips self, loads `push_subscriptions`, sends via web-push — no query of
-- any mute state anywhere in the file. The only mitigation today is the `sw.js`
-- visible-client skip (no notification while any ChatBox tab is visible).

--
-- 1. Proposed mute store (new table)
-- ----------------------------------

-- Run in the Supabase SQL editor (project: ChatBox / Sunset Island project is
-- separate — use the ChatBox project). One row per (user, chat) or (user, group).
create table if not exists muted_chats (
  user_id uuid not null references auth.users(id) on delete cascade,
  chat_id bigint,          -- 1-to-1 conversation id, null for groups
  group_id bigint,         -- group id, null for 1-to-1 chats
  muted_at timestamptz not null default now(),
  primary key (user_id, chat_id, group_id)
);
-- RLS: a user reads/writes only their own rows.
alter table muted_chats enable row level security;
create policy "own muted rows" on muted_chats
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);


-- Design notes (from the v168 §3 plan, unchanged):
-- - Keep the client-side `v5.muted` localStorage as the fast local gate (in-app tone
--   already respects it — `playNotify` / `isChatMuted`); the new table is the
--   **server-side mirror** used only by `send-push`.
-- - Client sync point: every mute/unmute toggle (1-to-1 + group, incl.
--   `v161GroupMuteToggle` and the chat mute toggles) upserts/deletes the matching
--   row after updating localStorage. A failed sync must surface honestly (toast),
--   not silently claim the mute is server-side. Sync is best-effort on top of the
--   local gate — a failed sync never un-mutes locally.
-- - Backfill: on first sync after the migration, the client uploads its existing
--   local mute list once (so users who already muted chats do not get push again
--   after the deploy). Do NOT wipe local mutes.
-- - Sound-off (`v5Settings.sound`) is also local-only today; the same table does
--   not cover it. If the user wants "sound OFF = no server push either", that needs
--   a second flag (e.g. a `push_opt_out` column on `profiles` or a row in the same
--   pattern) — out of scope for this draft, decide separately.

--
-- 2. Proposed `send-push` Edge Function change
-- --------------------------------------------

-- In `files/chatbox-send-push/index.ts`, before sending to a recipient's endpoints:
-- 1. Look up the recipient's `muted_chats` row for that chat/group
--    (`chat_id` for 1-to-1 / call pushes, `group_id` for group pushes).
-- 2. If a row exists, skip that recipient (do not send, do not error).
-- 3. Same check for call pushes (`sendCallPush`) and game pushes — a muted chat's
--    calls/games must not push either, matching the in-app behaviour.
-- 4. Keep the existing guards (JWT verify, skip self, `push_subscriptions` lookup)
--    and the existing visible-client skip in `sw.js`.

--
-- 3. What stays uncovered (honest limit)
-- --------------------------------------

-- - **Open-chat state cannot be reliably known server-side.** A recipient with the
--   chat open on a visible tab is still covered only by the `sw.js` visible-client
--   skip — that half of the P0 stays client-side by design.
-- - **Closed-app + muted** is what this fix closes: today a muted chat still
--   pushes to a closed app (phone default sound); after the fix it will not.

--
-- 4. Deploy / approval checklist (for the user)
-- ---------------------------------------------

-- - [ ] Run the SQL above in Supabase (ChatBox project).
-- - [ ] Verify the table + RLS (a second user cannot read another user's rows).
-- - [ ] Client sync on mute/unmute toggles (+ one-time backfill) — client code change.
-- - [ ] `supabase functions deploy send-push` (needs the user's separate deploy approval).
-- - [ ] Live test: mute a chat on device A, send from device B with A's app closed —
--       no push on A; unmute, resend — push arrives. Same for a group + a call push.

--
-- 5. What this fix area did NOT do
-- --------------------------------

-- - No SQL was run, no Edge Function was edited or deployed, no table was created.
-- - The v172 client diff (`notif_settings.diff`) contains no mute-sync code — the
--   client half is intentionally left for the same approved batch as the SQL, so a
--   half-synced state (client writing rows the function never reads, or vice versa)
--   is never shipped.

