-- Günce: initial schema.
-- Every table is protected by Row Level Security: a user can only ever see their own rows.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------- types
create type task_status as enum ('inbox', 'active', 'parked', 'done', 'archived');
create type park_reason as enum ('waiting', 'need_info', 'later');
create type task_event_kind as enum ('created', 'started', 'parked', 'resumed', 'done', 'reopened', 'note');
create type created_via as enum ('app', 'claude', 'widget', 'siri', 'share');

-- ---------------------------------------------------------------- areas
create table public.areas (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name        text not null check (char_length(name) between 1 and 40),
  symbol      text not null default 'circle',
  color       text not null default 'gray',
  sort        int  not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  deleted_at  timestamptz,
  unique (user_id, name)
);

-- ---------------------------------------------------------------- tasks
create table public.tasks (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null default auth.uid() references auth.users (id) on delete cascade,
  area_id            uuid references public.areas (id) on delete set null,
  parent_id          uuid references public.tasks (id) on delete cascade,
  title              text not null check (char_length(title) between 1 and 500),
  details            text check (char_length(details) <= 10000),
  status             task_status not null default 'inbox',
  next_step          text check (char_length(next_step) <= 500),
  park_note          text check (char_length(park_note) <= 1000),
  park_reason        park_reason,
  parked_at          timestamptz,
  started_at         timestamptz,
  due_at             timestamptz,
  remind_at          timestamptz,
  calendar_event_id  text,
  sort               double precision not null default 0,
  created_via        created_via not null default 'app',
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  completed_at       timestamptz,
  deleted_at         timestamptz
);

create index tasks_user_status_idx on public.tasks (user_id, status) where deleted_at is null;
create index tasks_user_remind_idx on public.tasks (user_id, remind_at) where remind_at is not null and deleted_at is null;
create index tasks_parent_idx on public.tasks (parent_id);
create index tasks_updated_idx on public.tasks (user_id, updated_at);

-- The core rule: at most one active top-level task per user.
create unique index tasks_one_active_per_user
  on public.tasks (user_id)
  where status = 'active' and parent_id is null and deleted_at is null;

-- ---------------------------------------------------------------- history ("İz")
create table public.task_events (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null default auth.uid() references auth.users (id) on delete cascade,
  task_id           uuid not null references public.tasks (id) on delete cascade,
  kind              task_event_kind not null,
  note              text check (char_length(note) <= 1000),
  reason            park_reason,
  duration_seconds  int check (duration_seconds >= 0),
  source            created_via not null default 'app',
  occurred_at       timestamptz not null default now()
);
create index task_events_task_idx on public.task_events (task_id, occurred_at desc);

-- ---------------------------------------------------------------- push tokens
create table public.device_tokens (
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  apns_token  text not null check (char_length(apns_token) <= 200),
  environment text not null check (environment in ('sandbox', 'production')),
  updated_at  timestamptz not null default now(),
  primary key (user_id, apns_token)
);

-- ---------------------------------------------------------------- updated_at
create or replace function public.touch_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end $$;

create trigger areas_touch before update on public.areas
  for each row execute function public.touch_updated_at();
create trigger tasks_touch before update on public.tasks
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------- RLS
alter table public.areas         enable row level security;
alter table public.tasks         enable row level security;
alter table public.task_events   enable row level security;
alter table public.device_tokens enable row level security;

create policy "own areas" on public.areas
  for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

create policy "own tasks" on public.tasks
  for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

create policy "own task events" on public.task_events
  for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

create policy "own device tokens" on public.device_tokens
  for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- A task's area and parent must belong to the same user.
create or replace function public.check_task_ownership() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.area_id is not null and not exists (
    select 1 from public.areas a where a.id = new.area_id and a.user_id = new.user_id) then
    raise exception 'area does not belong to user';
  end if;
  if new.parent_id is not null and not exists (
    select 1 from public.tasks t where t.id = new.parent_id and t.user_id = new.user_id) then
    raise exception 'parent task does not belong to user';
  end if;
  return new;
end $$;

create trigger tasks_ownership before insert or update of area_id, parent_id, user_id on public.tasks
  for each row execute function public.check_task_ownership();

-- ---------------------------------------------------------------- default areas for new users
create or replace function public.create_default_areas() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.areas (user_id, name, symbol, color, sort) values
    (new.id, 'İş',      'briefcase',                 'indigo', 0),
    (new.id, 'Hayat',   'heart',                     'pink',   1),
    (new.id, 'Spor',    'figure.run',                'orange', 2),
    (new.id, 'Yatırım', 'chart.line.uptrend.xyaxis', 'green',  3);
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.create_default_areas();

-- ---------------------------------------------------------------- state changes
-- park_task: park the given task (or the current active one) with a note.
create or replace function public.park_task(
  p_task_id uuid default null,
  p_note    text default null,
  p_reason  park_reason default 'later',
  p_remind_at timestamptz default null,
  p_source  created_via default 'app'
) returns public.tasks
language plpgsql security invoker set search_path = '' as $$
declare
  t public.tasks;
begin
  select * into t from public.tasks
   where user_id = auth.uid() and deleted_at is null
     and (case when p_task_id is null then status = 'active' else id = p_task_id end)
   for update;
  if not found then
    raise exception 'task not found';
  end if;

  update public.tasks set
    status      = 'parked',
    park_note   = coalesce(p_note, park_note),
    park_reason = p_reason,
    parked_at   = now(),
    remind_at   = coalesce(p_remind_at, remind_at)
  where id = t.id
  returning * into t;

  insert into public.task_events (user_id, task_id, kind, note, reason, duration_seconds, source)
  values (auth.uid(), t.id, 'parked', p_note, p_reason,
          case when t.started_at is not null then greatest(0, extract(epoch from now() - t.started_at))::int end,
          p_source);
  return t;
end $$;

-- start_task: make a task active. If another task is active it is parked first, atomically.
create or replace function public.start_task(
  p_task_id       uuid,
  p_previous_note text default null,
  p_previous_reason park_reason default 'later',
  p_source        created_via default 'app'
) returns public.tasks
language plpgsql security invoker set search_path = '' as $$
declare
  t public.tasks;
  current_id uuid;
  was_parked boolean;
begin
  select id into current_id from public.tasks
   where user_id = auth.uid() and status = 'active' and parent_id is null and deleted_at is null
   for update;

  if current_id = p_task_id then
    select * into t from public.tasks where id = p_task_id;
    return t;
  end if;

  if current_id is not null then
    perform public.park_task(current_id, p_previous_note, p_previous_reason, null, p_source);
  end if;

  select (status = 'parked') into was_parked from public.tasks
   where id = p_task_id and user_id = auth.uid() and deleted_at is null;
  if was_parked is null then
    raise exception 'task not found';
  end if;

  update public.tasks set status = 'active', started_at = now()
   where id = p_task_id
  returning * into t;

  insert into public.task_events (user_id, task_id, kind, source)
  values (auth.uid(), t.id, case when was_parked then 'resumed' else 'started' end::public.task_event_kind, p_source);
  return t;
end $$;

-- complete_task: mark done (works for subtasks too).
create or replace function public.complete_task(p_task_id uuid, p_source created_via default 'app')
returns public.tasks
language plpgsql security invoker set search_path = '' as $$
declare
  t public.tasks;
begin
  update public.tasks set status = 'done', completed_at = now(), remind_at = null
   where id = p_task_id and user_id = auth.uid() and deleted_at is null
  returning * into t;
  if not found then
    raise exception 'task not found';
  end if;
  insert into public.task_events (user_id, task_id, kind, source)
  values (auth.uid(), t.id, 'done', p_source);
  return t;
end $$;

-- Log creation automatically.
create or replace function public.log_task_created() returns trigger
language plpgsql set search_path = '' as $$
begin
  insert into public.task_events (user_id, task_id, kind, source)
  values (new.user_id, new.id, 'created', new.created_via);
  return new;
end $$;

create trigger tasks_log_created after insert on public.tasks
  for each row execute function public.log_task_created();

revoke all on function public.park_task, public.start_task, public.complete_task from public, anon;
grant execute on function public.park_task, public.start_task, public.complete_task to authenticated;
