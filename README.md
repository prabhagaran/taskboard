# TaskBoard

A lightweight personal task manager. The website is a static site hosted free on GitHub Pages, there's an Android app, and both sync through [Supabase](https://supabase.com).

- **My day:** pick the tasks you'll work on today from everything open. Due dates stay the same, and the list starts empty each morning
- **Workspace layout:** sidebar with smart lists (My day, Today, Next 7 days, Overdue, Completed) and projects, with live counts
- **Dashboard:** KPI tiles, completions per day, open work by priority, workload by project, upcoming deadlines, recent activity
- **Board:** drag and drop between To Do and Done, plus inline quick-add in each column
- **Table:** sortable columns, multi-select, and bulk actions (mark done, add to My day, set status or priority, delete)
- **Task panel:** a side drawer with every field, timestamps, duplicate and delete (with undo)
- **Calendar:** month view of due dates
- **Tags and saved filters:** label tasks and keep filter combinations (saved per device)
- **Links:** attach Google Drive files or any web link to a task
- **Task history:** every change is logged and shown on the task
- **Notes:** a Notes page for ideas, meeting notes and research. Link a note to any number of tasks; each task lists its notes and can start a new one
- **Repeating tasks and checklists:** finishing a repeating task creates the next one, and steps show progress on the card
- **Offline edits:** changes wait in a queue and sync when you reconnect
- **Conflict warnings:** if a task changed on another device, you choose whether to keep your edit
- **Command palette** (`Ctrl K`): jump to any task, project or view
- Light, dark and system themes; works on phones
- Works without an account in **local mode** (saved in the browser) until you sign in
- Shortcuts: `Ctrl K` palette, `N` new task, `/` filter, `Ctrl Enter` save, `Esc` close

```
Website (GitHub Pages) ──┐
                         ├──▶  Supabase: sign-in + Postgres (tasks, notes, task_history)
Android app ─────────────┘
```

## 1. Set up Supabase

1. Create a Supabase project and run [`supabase/schema.sql`](supabase/schema.sql) in its **SQL Editor**. This creates the tables, the rules that keep each account's rows private, and the functions the apps call.
2. **Authentication → Users → Add user → Create new user**: enter your email and a password, and tick **Auto Confirm User**.
3. **Authentication → Sign In / Providers**: turn off **Allow new users to sign up**. The site's publishable key is public, so otherwise anyone could create an account in your project (they still couldn't see your tasks).
4. Put your project's URL and publishable key (**Project Settings → API Keys**) in `SUPABASE_DEFAULT` in `app.js` and in `supabaseUrl`/`supabaseKey` in `mobile/lib/services/api.dart`. Both are safe to publish; never use the `service_role` key.

Supabase's free plan pauses a project after about a week without use; restore it from the dashboard.

## 2. Host the website on GitHub Pages

```bash
git init
git add .
git commit -m "TaskBoard"
gh repo create taskboard --public --source=. --push
```

Then in the repo on GitHub: **Settings → Pages → Build and deployment → Source: Deploy from a branch → `main` / `(root)` → Save**.
Your site will be live at `https://<your-username>.github.io/taskboard/` within a minute or two.

(GitHub Pages needs a public repo on the free plan. That's safe here: the repo holds no secrets.)

## 3. Sign in

On the website, open **Connection settings** and sign in with the email and password from step 1. Your password goes only to Supabase and is never stored; the browser keeps a session that renews itself.

## Android app

[`mobile/`](mobile/) is a Flutter app that uses the same Supabase account. Its Today screen leads with your My day picks (tap **Plan my day** to choose them) and folds everything else due away. It has Today, Tasks, Notes, Calendar, and Dashboard screens, a scrollable home-screen widget listing all open tasks, swipe to complete or delete, hold and drag to reorder, and a tablet layout. Offline, it shows your last synced tasks and queues your changes until you reconnect. Turn on **Due date reminders** in Settings for a notification at 9:00 on days with tasks due.

```bash
cd mobile
flutter build apk --release
# Output: build/app/outputs/flutter-apk/app-release.apk
```

Release builds are signed with the key in `android/upload-keystore.jks`, using the passwords in `android/key.properties`. Neither file is in git, so **back up both somewhere safe**. Without them you can't publish an update that installs over the app, and without `key.properties` a build falls back to a debug key.

Copy the APK to your phone, open it, and allow installs from that source. On first launch, sign in with your email and password. The session is kept in Android's encrypted storage.

## Data

Each table has a `user_id` column, and row-level security limits every query to the signed-in account. The apps go through three functions: `list_all`, `apply_ops` (batched writes, with conflict checks and repeats) and `task_history`.

**tasks**: `id`, `title`, `description`, `status` (`todo` or `done`), `priority` (`low`, `medium`, `high`), `project`, `due_date`, `tags` (comma-separated), `links` (one http(s) link per line), `sort_order` (set by dragging), `recurrence` (blank, `daily`, `weekly`, `monthly` or `yearly`), `checklist` (one step per line, as `[ ] step` or `[x] step`), `focus_date` (the day it was picked for My day), `created_at`, `updated_at`, `completed_at`.

**notes**: `id`, `title`, `body` (up to 40,000 characters), `task_ids` (comma-separated IDs of linked tasks), `created_at`, `updated_at`.

**task_history**: one row per change, shown on the task.

You can view and edit rows in Supabase's **Table Editor**. The apps pick up changes when you refresh or switch back to them.

## Using it with several people

Add a user for each person under **Authentication → Users**. Each account sees only its own tasks and notes.

## Run locally

Any static server works, for example:

```bash
npx serve .
# or
python -m http.server 8080
```

## Troubleshooting

| Problem | Fix |
|---------|-----|
| "Invalid login credentials" | Check the email and password of the user you added in Supabase. |
| "Your sign-in has expired" | Open **Connection settings** (website) or **Settings** (app) and sign in again. |
| "Could not reach Supabase" | Check your connection. If it persists, the free project may be paused; restore it from the Supabase dashboard. Changes wait in the queue meanwhile. |
| Website still looks old after an update | Press `Ctrl+F5` to reload without the cache. |
