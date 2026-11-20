# Deploy & push guide

## 1. Deploy to Cloudflare Pages (manual)

1. Zip the app files at the repo root — exactly these 11:
   `index.html`, `sw.js`, `manifest.json`, `favicon.svg`, `logo.png`,
   `icon-192.png`, `icon-512.png`, `icon-maskable-512.png`,
   `chatbox-call-doodle-bg.jpg`, `_headers`, `README-v172.txt`
   (do **not** include `README.md`, `DEPLOY_GUIDE.md`, `.env.example`,
   `.gitignore`, `LICENSE`, `supabase-v172.sql`, or `assets/` — those are
   repo-only).
2. Cloudflare dashboard → Workers & Pages → your Pages project →
   **Create deployment** → **Direct Upload** → upload the zip.
3. Verify: open the site, Settings → About shows the new version.

## 2. Push to GitHub (first time)

```bash
git init
git add .
git commit -m "ChatBox v172"
git branch -M main
git remote add origin https://github.com/hossainabirdev/ChatBox.git
git push -u origin main
```

Later updates: `git add . && git commit -m "ChatBox v173" && git push`.

## 3. Where the real secrets go (never in the repo)

| Secret | Set it in |
|---|---|
| Supabase `service_role` key | Supabase dashboard → Project Settings → API (server use only) |
| `TURN_SHARED_SECRET` | Supabase dashboard → Edge Functions → Secrets |
| `VAPID_PRIVATE_KEY` | Supabase dashboard → Edge Functions → Secrets |
| `BREVO_API_KEY` | Supabase dashboard → Edge Functions → Secrets |
| Cloudflare Realtime app id + secret | Cloudflare dashboard → Realtime; secret also in Supabase Edge Function secrets |
| `CLEANUP_SECRET` | Supabase dashboard → Edge Functions → Secrets |

Real secrets **never** go in the repo, in any file, in any commit. If one
ever lands in git history, rotate it immediately — deleting the file does not
unleak it. `.env` is git-ignored; only `.env.example` (placeholders) is
committed.

## 4. Backend first-run checklist

Live status (20 Nov 2026, project "chatbox"): the `§0` checks are done and
§1-1a, §1-3a (adapted), §2 C-12 and §3 S-1 are already run and verified live.
Do NOT run §3 E-06 or §3 F11 as written (both stopped, rework owed), and do
NOT run §1-1b, §1-3c, the `view_once_views` table or the `muted_chats` table.

1. Run the `§0` checks in `supabase-v172.sql` before any section.
2. Confirm `group_messages.forwarded` exists (a missing column breaks group
   opens) and `message_meta` is in the Realtime publication — both confirmed
   live on 20 Nov 2026.
3. Deploy the Edge Functions the app calls (`send-push`, `login-by-email`,
   `request-recovery-code`, `verify-and-reset`, `send-welcome`,
   `delete-view-once`, `cleanup-expired-media`, `link-preview`,
   `group-call-token`).
