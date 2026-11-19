-- TaskBoard on Supabase.
-- Run once in the SQL editor of a new project (or apply as a migration).
-- Each signed-in user sees only their own rows. The apps call three functions,
-- list_all, apply_ops and task_history, which answer exactly like the old
-- Apps Script web app, so offline queues and conflict checks work unchanged.

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
create table public.tasks (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  id text not null check (id ~ '^[A-Za-z0-9_-]{1,64}$'),
  title text not null check (length(title) between 1 and 500),
  description text not null default '',
  status text not null default 'todo' check (status in ('todo', 'done')),
  priority text not null default 'medium' check (priority in ('low', 'medium', 'high')),
  project text not null default '',
  due_date date,
  tags text not null default '',
  links text not null default '',
  sort_order double precision,
  recurrence text not null default '' check (recurrence in ('', 'daily', 'weekly', 'monthly', 'yearly')),
  checklist text not null default '',
  focus_date date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  primary key (user_id, id)
);

create table public.notes (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  id text not null check (id ~ '^[A-Za-z0-9_-]{1,64}$'),
  title text not null default '' check (length(title) <= 500),
  body text not null default '' check (length(body) <= 40000),
  task_ids text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, id)
);

create table public.task_history (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  task_id text not null,
  title text not null default '',
  action text not null,
  details text not null default '',
  at timestamptz not null default clock_timestamp()
);
create index task_history_lookup on public.task_history (user_id, task_id, at desc);

alter table public.tasks enable row level security;
alter table public.notes enable row level security;
alter table public.task_history enable row level security;

create policy "own tasks" on public.tasks for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "own notes" on public.notes for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "own history" on public.task_history for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

revoke all on public.tasks, public.notes, public.task_history from anon;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- The timestamp format the apps store and send back as baseUpdatedAt.
create function public.tb_iso(ts timestamptz) returns text
language sql immutable set search_path = '' as $$
  select to_char(ts at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
$$;

-- Trims all whitespace, like JavaScript's trim().
create function public.tb_trim(v text) returns text
language sql immutable set search_path = '' as $$
  select regexp_replace(coalesce(v, ''), '^\s+|\s+$', '', 'g')
$$;

-- The input's value for key, or fallback when the input leaves it out or sends null.
create function public.tb_pick(p jsonb, key text, fallback text) returns text
language sql immutable set search_path = '' as $$
  select case when p ? key and p -> key <> 'null'::jsonb then p ->> key else fallback end
$$;

create function public.tb_day(v text) returns date
language plpgsql immutable set search_path = '' as $$
begin
  if v !~ '^\d{4}-\d{2}-\d{2}$' then return null; end if;
  return v::date;
exception when others then
  return null;
end $$;

create function public.tb_ts(v text) returns timestamptz
language plpgsql stable set search_path = '' as $$
begin
  return nullif(v, '')::timestamptz;
exception when others then
  return null;
end $$;

create function public.task_json(t public.tasks) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'id', t.id, 'title', t.title, 'description', t.description,
    'status', t.status, 'priority', t.priority, 'project', t.project,
    'dueDate', coalesce(to_char(t.due_date, 'YYYY-MM-DD'), ''),
    'createdAt', public.tb_iso(t.created_at), 'updatedAt', public.tb_iso(t.updated_at),
    'tags', t.tags, 'links', t.links,
    'sortOrder', coalesce(t.sort_order::text, ''),
    'completedAt', coalesce(public.tb_iso(t.completed_at), ''),
    'recurrence', t.recurrence, 'checklist', t.checklist,
    'focusDate', coalesce(to_char(t.focus_date, 'YYYY-MM-DD'), ''))
$$;

create function public.note_json(n public.notes) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'id', n.id, 'title', n.title, 'body', n.body, 'taskIds', n.task_ids,
    'createdAt', public.tb_iso(n.created_at), 'updatedAt', public.tb_iso(n.updated_at))
$$;

-- Applies the fields present in p over b, with the same rules as Code.gs.
create function public.clean_task(p jsonb, b public.tasks) returns public.tasks
language plpgsql stable set search_path = '' as $$
declare
  t public.tasks := b;
  v text;
begin
  t.title := public.tb_trim(public.tb_pick(p, 'title', b.title));
  if t.title = '' then raise exception 'Title is required.'; end if;
  if length(t.title) > 500 then raise exception 'Title is too long.'; end if;
  t.description := public.tb_trim(public.tb_pick(p, 'description', b.description));
  t.status := public.tb_trim(public.tb_pick(p, 'status', b.status));
  if t.status not in ('todo', 'done') then t.status := 'todo'; end if;
  t.priority := public.tb_trim(public.tb_pick(p, 'priority', b.priority));
  if t.priority not in ('low', 'medium', 'high') then t.priority := 'medium'; end if;
  t.project := public.tb_trim(public.tb_pick(p, 'project', b.project));
  v := public.tb_trim(public.tb_pick(p, 'dueDate', coalesce(to_char(b.due_date, 'YYYY-MM-DD'), '')));
  t.due_date := public.tb_day(v);
  if v <> '' and t.due_date is null then raise exception 'Due date must be YYYY-MM-DD.'; end if;
  t.tags := public.tb_trim(public.tb_pick(p, 'tags', b.tags));
  v := public.tb_trim(public.tb_pick(p, 'links', b.links));
  select coalesce(string_agg(l, E'\n' order by n), '') into t.links
  from (select public.tb_trim(x) as l, n from unnest(string_to_array(v, E'\n')) with ordinality as u(x, n)) s
  where l ~* '^https?://';
  v := public.tb_trim(public.tb_pick(p, 'sortOrder', coalesce(b.sort_order::text, '')));
  t.sort_order := case when v ~ '^-?\d+(\.\d+)?$' then v::double precision end;
  t.recurrence := public.tb_trim(public.tb_pick(p, 'recurrence', b.recurrence));
  if t.recurrence not in ('daily', 'weekly', 'monthly', 'yearly') then t.recurrence := ''; end if;
  t.checklist := public.tb_trim(public.tb_pick(p, 'checklist', b.checklist));
  t.focus_date := public.tb_day(public.tb_trim(public.tb_pick(p, 'focusDate', coalesce(to_char(b.focus_date, 'YYYY-MM-DD'), ''))));
  return t;
end $$;

create function public.clean_note(p jsonb, b public.notes) returns public.notes
language plpgsql stable set search_path = '' as $$
declare
  n public.notes := b;
begin
  n.title := public.tb_trim(public.tb_pick(p, 'title', b.title));
  n.body := regexp_replace(public.tb_pick(p, 'body', b.body), '\s+$', '');
  if n.title = '' and public.tb_trim(n.body) = '' then raise exception 'A note needs a title or some text.'; end if;
  if length(n.title) > 500 then raise exception 'Title is too long.'; end if;
  if length(n.body) > 40000 then raise exception 'Note is too long.'; end if;
  select coalesce(string_agg(id, ',' order by pos), '') into n.task_ids
  from (
    select id, min(k) as pos
    from unnest(string_to_array(public.tb_pick(p, 'taskIds', b.task_ids), ',')) with ordinality as u(raw, k),
         lateral (select public.tb_trim(raw) as id) i
    where id ~ '^[A-Za-z0-9_-]{1,64}$'
    group by id
  ) s;
  return n;
end $$;

-- Readable list of tracked fields that differ, as the history log shows them.
create function public.describe_changes(b jsonb, a jsonb) returns text
language sql immutable set search_path = '' as $$
  select coalesce(string_agg(
    case when k in ('description', 'links', 'checklist') then k || ' changed'
         else k || ': ' || coalesce(nullif(b ->> k, ''), 'none') || ' → ' || coalesce(nullif(a ->> k, ''), 'none') end,
    '; ' order by ord), '')
  from unnest(array['title', 'description', 'status', 'priority', 'project', 'dueDate', 'tags', 'links', 'recurrence', 'checklist'])
       with ordinality as u(k, ord)
  where coalesce(b ->> k, '') <> coalesce(a ->> k, '')
$$;

create function public.log_task(t public.tasks, action text, details text) returns void
language sql set search_path = '' as $$
  insert into public.task_history (user_id, task_id, title, action, details, at)
  values (t.user_id, t.id, t.title, action, coalesce(details, ''), clock_timestamp())
$$;

-- First date after today in the repeat series that starts at start.
create function public.next_due(start date, recurrence text, today date) returns date
language plpgsql immutable set search_path = '' as $$
declare
  due date := start;
  step int := 0;
begin
  while due <= today loop
    step := step + 1;
    due := case recurrence
      when 'daily' then start + step
      when 'weekly' then start + step * 7
      when 'monthly' then (start + make_interval(months => step))::date
      else (start + make_interval(years => step))::date
    end;
  end loop;
  return due;
end $$;

-- ---------------------------------------------------------------------------
-- One write. Raises on failure; a conflict carries the current copy as DETAIL.
-- ---------------------------------------------------------------------------
create function public.apply_op(op jsonb, today date) returns jsonb
language plpgsql set search_path = '' as $$
declare
  uid uuid := auth.uid();
  act text := op ->> 'action';
  p jsonb := coalesce(op -> 'task', op -> 'note', '{}'::jsonb);
  rid text := coalesce(p ->> 'id', op ->> 'id', '');
  is_force boolean := coalesce((op ->> 'force')::boolean, false);
  base timestamptz := public.tb_ts(p ->> 'baseUpdatedAt');
  t public.tasks;
  prev public.tasks;
  nxt public.tasks;
  n public.notes;
  nb public.notes;
  changes text;
begin
  if uid is null then raise exception 'Not signed in.'; end if;

  if act = 'create' then
    if rid ~ '^[A-Za-z0-9_-]{1,64}$' then
      select * into prev from public.tasks where user_id = uid and id = rid;
      -- A retried create (say, after a lost response) must not add a second copy.
      if found then return jsonb_build_object('task', public.task_json(prev)); end if;
    else
      rid := gen_random_uuid()::text;
    end if;
    t.user_id := uid; t.title := ''; t.description := ''; t.status := 'todo'; t.priority := 'medium';
    t.project := ''; t.tags := ''; t.links := ''; t.recurrence := ''; t.checklist := '';
    t := public.clean_task(p, t);
    t.id := rid;
    t.created_at := clock_timestamp();
    t.updated_at := t.created_at;
    t.completed_at := case when t.status = 'done' then t.created_at end;
    insert into public.tasks values (t.*);
    perform public.log_task(t, 'created', '');
    return jsonb_build_object('task', public.task_json(t));

  elsif act = 'update' then
    select * into prev from public.tasks where user_id = uid and id = rid for update;
    if not found then raise exception 'Task not found. It may have been deleted.'; end if;
    if not is_force and base is not null and base <> prev.updated_at then
      raise exception 'This task was changed somewhere else.' using detail = public.task_json(prev)::text;
    end if;
    t := public.clean_task(p, prev);
    t.updated_at := clock_timestamp();
    if prev.status <> 'done' and t.status = 'done' then t.completed_at := t.updated_at;
    elsif t.status <> 'done' then t.completed_at := null;
    end if;
    update public.tasks set
      title = t.title, description = t.description, status = t.status, priority = t.priority,
      project = t.project, due_date = t.due_date, tags = t.tags, links = t.links,
      sort_order = t.sort_order, recurrence = t.recurrence, checklist = t.checklist,
      focus_date = t.focus_date, updated_at = t.updated_at, completed_at = t.completed_at
    where user_id = uid and id = rid;
    changes := public.describe_changes(public.task_json(prev), public.task_json(t));
    if changes <> '' then perform public.log_task(t, 'updated', changes); end if;
    if not (prev.status <> 'done' and t.status = 'done' and t.recurrence <> '') then
      return jsonb_build_object('task', public.task_json(t));
    end if;
    nxt := t;
    nxt.id := gen_random_uuid()::text;
    nxt.status := 'todo';
    nxt.due_date := public.next_due(coalesce(t.due_date, today), t.recurrence, today);
    nxt.sort_order := null;
    nxt.completed_at := null;
    nxt.focus_date := null;
    nxt.checklist := regexp_replace(t.checklist, '^\[x\]', '[ ]', 'gin');
    nxt.created_at := clock_timestamp();
    nxt.updated_at := nxt.created_at;
    insert into public.tasks values (nxt.*);
    perform public.log_task(nxt, 'created', 'repeats ' || t.recurrence);
    return jsonb_build_object('task', public.task_json(t), 'next', public.task_json(nxt));

  elsif act = 'delete' then
    delete from public.tasks where user_id = uid and id = rid returning * into prev;
    if found then perform public.log_task(prev, 'deleted', ''); end if;
    return '{}'::jsonb;

  elsif act = 'createNote' then
    if rid ~ '^[A-Za-z0-9_-]{1,64}$' then
      select * into nb from public.notes where user_id = uid and id = rid;
      if found then return jsonb_build_object('note', public.note_json(nb)); end if;
    else
      rid := gen_random_uuid()::text;
    end if;
    n.user_id := uid; n.title := ''; n.body := ''; n.task_ids := '';
    n := public.clean_note(p, n);
    n.id := rid;
    n.created_at := clock_timestamp();
    n.updated_at := n.created_at;
    insert into public.notes values (n.*);
    return jsonb_build_object('note', public.note_json(n));

  elsif act = 'updateNote' then
    select * into nb from public.notes where user_id = uid and id = rid for update;
    if not found then raise exception 'Note not found. It may have been deleted.'; end if;
    if not is_force and base is not null and base <> nb.updated_at then
      raise exception 'This note was changed somewhere else.' using detail = public.note_json(nb)::text;
    end if;
    n := public.clean_note(p, nb);
    n.updated_at := clock_timestamp();
    update public.notes set title = n.title, body = n.body, task_ids = n.task_ids, updated_at = n.updated_at
    where user_id = uid and id = rid;
    return jsonb_build_object('note', public.note_json(n));

  elsif act = 'deleteNote' then
    delete from public.notes where user_id = uid and id = rid;
    return '{}'::jsonb;
  end if;

  raise exception 'Unknown action: %', act;
end $$;

-- ---------------------------------------------------------------------------
-- The API the apps call (POST /rest/v1/rpc/<name>)
-- ---------------------------------------------------------------------------

-- Raised when the apps need something new from this schema.
create function public.list_all() returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'ok', true,
    'version', 4,
    'tasks', coalesce((select jsonb_agg(public.task_json(t) order by t.created_at, t.id) from public.tasks t
                       where t.user_id = (select auth.uid())), '[]'::jsonb),
    'notes', coalesce((select jsonb_agg(public.note_json(n) order by n.created_at, n.id) from public.notes n
                       where n.user_id = (select auth.uid())), '[]'::jsonb))
$$;

-- Applies writes in order. One failed op doesn't stop the rest; each reports its own result.
create function public.apply_ops(ops jsonb, today date default current_date) returns jsonb
language plpgsql set search_path = '' as $$
declare
  op jsonb;
  results jsonb := '[]'::jsonb;
  msg text;
  det text;
  failed jsonb;
begin
  if jsonb_typeof(ops) <> 'array' then raise exception 'ops must be a list.'; end if;
  if jsonb_array_length(ops) > 500 then raise exception 'Too many changes at once.'; end if;
  for op in select value from jsonb_array_elements(ops) loop
    begin
      results := results || jsonb_build_array(jsonb_build_object('ok', true) || public.apply_op(op, today));
    exception when others then
      get stacked diagnostics msg = message_text, det = pg_exception_detail;
      failed := jsonb_build_object('ok', false, 'error', msg);
      if det like '{%' then failed := failed || jsonb_build_object('conflict', det::jsonb); end if;
      results := results || jsonb_build_array(failed);
    end;
  end loop;
  return jsonb_build_object('ok', true, 'results', results);
end $$;

create function public.task_history(p_task_id text) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('ok', true, 'entries', coalesce(jsonb_agg(e order by at desc, hid desc), '[]'::jsonb))
  from (
    select h.id as hid, h.at, jsonb_build_object('at', public.tb_iso(h.at), 'action', h.action, 'details', h.details) as e
    from public.task_history h
    where h.user_id = (select auth.uid()) and h.task_id = p_task_id
    order by h.at desc, h.id desc
    limit 200
  ) s
$$;

-- One-time copy from Google Sheets. Keeps IDs and timestamps; skips IDs already here.
create function public.import_data(tasks jsonb, notes jsonb) returns jsonb
language plpgsql set search_path = '' as $$
declare
  uid uuid := auth.uid();
  p jsonb;
  t public.tasks;
  n public.notes;
  added_tasks int := 0;
  added_notes int := 0;
  skipped int := 0;
begin
  if uid is null then raise exception 'Not signed in.'; end if;
  for p in select value from jsonb_array_elements(coalesce(tasks, '[]'::jsonb)) loop
    begin
      if coalesce(p ->> 'id', '') !~ '^[A-Za-z0-9_-]{1,64}$' then raise exception 'bad id'; end if;
      t := null;
      t.user_id := uid; t.title := ''; t.description := ''; t.status := 'todo'; t.priority := 'medium';
      t.project := ''; t.tags := ''; t.links := ''; t.recurrence := ''; t.checklist := '';
      t := public.clean_task(p, t);
      t.id := p ->> 'id';
      t.created_at := coalesce(public.tb_ts(p ->> 'createdAt'), now());
      t.updated_at := coalesce(public.tb_ts(p ->> 'updatedAt'), t.created_at);
      t.completed_at := case when t.status = 'done'
        then coalesce(public.tb_ts(p ->> 'completedAt'), t.updated_at) end;
      insert into public.tasks values (t.*) on conflict do nothing;
      if found then added_tasks := added_tasks + 1; end if;
    exception when others then
      skipped := skipped + 1;
    end;
  end loop;
  for p in select value from jsonb_array_elements(coalesce(notes, '[]'::jsonb)) loop
    begin
      if coalesce(p ->> 'id', '') !~ '^[A-Za-z0-9_-]{1,64}$' then raise exception 'bad id'; end if;
      n := null;
      n.user_id := uid; n.title := ''; n.body := ''; n.task_ids := '';
      n := public.clean_note(p, n);
      n.id := p ->> 'id';
      n.created_at := coalesce(public.tb_ts(p ->> 'createdAt'), now());
      n.updated_at := coalesce(public.tb_ts(p ->> 'updatedAt'), n.created_at);
      insert into public.notes values (n.*) on conflict do nothing;
      if found then added_notes := added_notes + 1; end if;
    exception when others then
      skipped := skipped + 1;
    end;
  end loop;
  return jsonb_build_object('ok', true, 'tasks', added_tasks, 'notes', added_notes, 'skipped', skipped);
end $$;

-- Only signed-in users may call anything.
revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated;
