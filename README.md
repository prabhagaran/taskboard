# TaskBoard

A lightweight personal task manager. The frontend is a static site (hosted free on GitHub Pages); the backend is a Google Sheet, accessed through a small Google Apps Script web app.

- **Workspace layout:** sidebar with smart lists (Today, Next 7 days, Overdue, Completed) and projects, with live counts
- **Dashboard:** KPI tiles, completions per day, open work by priority, workload by project, upcoming deadlines, recent activity
- **Board:** drag and drop between To Do, In Progress and Done, plus inline quick-add in each column
- **Table:** sortable columns, multi-select, and bulk actions (mark done, set status or priority, delete)
- **Task panel:** a side drawer with every field, timestamps, duplicate and delete (with undo)
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

Open the site, click the **gear icon** (or *Connect Google Sheet*), paste the **Web app URL** and **API token**, click **Test**, then **Save**.
Repeat this once on each browser or device you use.

## Android app

[`mobile/`](mobile/) is a Flutter app that uses the same Google Sheet and web app. It has Today, Tasks, and Dashboard screens, swipe to complete or delete, and shows your last synced tasks when offline (changes need a connection).

```bash
cd mobile
flutter build apk --release
# Output: build/app/outputs/flutter-apk/app-release.apk
```

Copy the APK to your phone, open it, and allow installs from that source. On first launch, enter the web app URL and API token. The token is kept in Android's encrypted storage.

## Sheet format

| id | title | description | status | priority | project | dueDate | createdAt | updatedAt |
|----|-------|-------------|--------|----------|---------|---------|-----------|-----------|

- `status`: `todo`, `inprogress`, `done`
- `priority`: `low`, `medium`, `high`
- `dueDate`: `YYYY-MM-DD`

You can edit rows directly in the sheet. The app picks up changes when you click refresh or switch back to its tab.

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
