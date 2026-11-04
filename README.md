# TaskBoard

A lightweight personal task manager. The frontend is a static site (hosted free on GitHub Pages); the backend is a Google Sheet, accessed through a small Google Apps Script web app.

- **Workspace layout:** sidebar with smart lists (Today, Next 7 days, Overdue, Completed) and projects, with live counts
- **Dashboard:** KPI tiles, completions per day, open work by priority, workload by project, upcoming deadlines, recent activity
- **Board:** drag and drop between To Do and Done, plus inline quick-add in each column
- **Table:** sortable columns, multi-select, and bulk actions (mark done, set status or priority, delete)
- **Task panel:** a side drawer with every field, timestamps, duplicate and delete (with undo)
- **Calendar:** month view of due dates, plus one-way sync into a separate Google Calendar
- **Tags and saved filters:** label tasks and keep filter combinations (saved per device)
- **Links:** attach Google Drive files or any web link to a task
- **Task history:** every change is logged to a `History` sheet and shown on the task
- **Repeating tasks and checklists:** finishing a repeating task creates the next one, and steps show progress on the card
- **Offline edits:** changes wait in a queue and sync when you reconnect
- **Conflict warnings:** if a task changed on another device, you choose whether to keep your edit
- **Reminders and backups:** a daily email of due tasks, phone notifications, and nightly copies of the sheet
- **Command palette** (`Ctrl K`): jump to any task, project or view
- Light, dark and system themes; works on phones
- Every task is a row in your Google Sheet, so you can also edit, sort, or chart it there
- Works without a backend in **local mode** (saved in the browser) until you connect a sheet
- Shortcuts: `Ctrl K` palette, `N` new task, `/` filter, `Ctrl Enter` save, `Esc` close

```
GitHub Pages (index.html, app.js)  ──POST JSON──▶  Apps Script web app  ──▶  Google Sheet "Tasks"
```

## 1. Set up the Google Sheet backend

1. Create a new Google Sheet (any name, e.g. *TaskBoard*).
2. Open **Extensions → Apps Script**.
3. Replace the contents of `Code.gs` with [`apps-script/Code.gs`](apps-script/Code.gs) from this repo and click **Save**.
4. In the function dropdown pick **`setup`** and click **Run**. Approve the permission prompt (it's your own script, so choose *Advanced → Go to project*).
   - This creates a `Tasks` sheet and generates an **API token**. Copy the token from the **Execution log**.
5. Click **Deploy → New deployment**, choose type **Web app**, and set:
   - **Execute as:** Me
   - **Who has access:** Anyone
6. Click **Deploy** and copy the **Web app URL** (ends in `/exec`).

> "Anyone" means the URL is reachable without a Google login. Every request still needs the API token, so keep the token private. If it ever leaks, run `rotateToken()` in Apps Script and enter the new token in the app.

**Optional automation.** Run each of these once in Apps Script and approve its permission, before deploying a new version, so the web app is not left waiting for that approval:

| Function | What it does |
|----------|--------------|
| `setupCalendarSync` | Syncs open tasks with due dates hourly into a separate calendar named TaskBoard |
| `setupReminders` | Emails you each morning around 8:00 when tasks are due or overdue |
| `setupBackups` | Copies the spreadsheet nightly into a Drive folder named TaskBoard backups, keeping the latest 14 |

**Per-device tokens.** Run `createDeviceTokens` once to create a `Devices` sheet. Type a name for each device in column A, then run it again to fill in tokens. Use a device's token in place of the main one. To revoke a lost device, delete its row. The main `API_TOKEN` keeps working, so run `rotateToken` as well if it may be exposed.

**After changing `Code.gs` later:** use **Deploy → Manage deployments → Edit (pencil) → Version: New version**. This keeps the same URL.

## 2. Host the app on GitHub Pages

```bash
git init
git add .
git commit -m "TaskBoard"
gh repo create taskboard --public --source=. --push
```

Then in the repo on GitHub: **Settings → Pages → Build and deployment → Source: Deploy from a branch → `main` / `(root)` → Save**.
Your app will be live at `https://<your-username>.github.io/taskboard/` within a minute or two.

(GitHub Pages needs a public repo on the free plan. That's safe here: the repo holds no secrets. The URL and token are entered in the app and stay in your browser.)

## 3. Connect

Open the site, click **Connection settings** (or *Connect Google Sheet*), paste the **Web app URL** and **API token**, click **Test connection**, then **Save**.

To add another device, open **Connection settings** on one that's connected and click **Show QR code for another device**. Scan it with the Android app (**Scan QR code**), or with a phone's camera to open the site already connected. Anyone who scans the code can read and change your tasks, so keep it private. If it's ever exposed, run `rotateToken` in Apps Script.

## Android app

[`mobile/`](mobile/) is a Flutter app that uses the same Google Sheet and web app. It has Today, Tasks, Calendar, and Dashboard screens, a scrollable home-screen widget listing all open tasks, swipe to complete or delete, hold and drag to reorder, and a tablet layout. Offline, it shows your last synced tasks and queues your changes until you reconnect. Turn on **Due date reminders** in Settings for a notification at 9:00 on days with tasks due.

```bash
cd mobile
flutter build apk --release
# Output: build/app/outputs/flutter-apk/app-release.apk
```

Release builds are signed with the key in `android/upload-keystore.jks`, using the passwords in `android/key.properties`. Neither file is in git, so **back up both somewhere safe**. Without them you can't publish an update that installs over the app, and without `key.properties` a build falls back to a debug key.

Copy the APK to your phone, open it, and allow installs from that source. On first launch, enter the web app URL and API token. The token is kept in Android's encrypted storage.

## Sheet format

| id | title | description | status | priority | project | dueDate | createdAt | updatedAt | tags | links | sortOrder | completedAt | recurrence | checklist |
|----|-------|-------------|--------|----------|---------|---------|-----------|-----------|------|-------|-----------|-------------|------------|-----------|

Older sheets gain any missing columns automatically the first time a new script runs.

- `status`: `todo` or `done` (anything else shows as To Do)
- `priority`: `low`, `medium`, `high`
- `dueDate`: `YYYY-MM-DD`
- `tags`: comma-separated
- `links`: one http(s) link per line
- `sortOrder`: position set by dragging; leave blank
- `completedAt`: set automatically when a task is finished
- `recurrence`: blank, `daily`, `weekly`, `monthly` or `yearly`
- `checklist`: one step per line, as `[ ] step` or `[x] step`

You can edit rows directly in the sheet. The app picks up changes when you click refresh or switch back to its tab.

## Using it with several people

Each person sets up their own copy: their own Google Sheet, Apps Script deployment and token. Tasks are never shared between copies, and everyone can use the same website and app by entering their own URL and token.

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
| "Invalid API token" | Re-copy the token from `setup()`'s log (run `setup()` again; it prints the existing token). |
| "Unexpected response" / HTML instead of JSON | The deployment's access isn't set to **Anyone**, or the URL isn't the `/exec` one. |
| Changes to `Code.gs` not taking effect | Publish a **new version** of the existing deployment (see above). |
| "Backend not configured" | Run `setup()` once in the Apps Script editor. |
