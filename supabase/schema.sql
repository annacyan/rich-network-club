-- =====================================================================
-- Rich人脈富豪俱樂部 — Supabase 資料庫結構與權限
-- 在 Supabase 後台 → SQL Editor 貼上整份執行即可（可重複執行）。
-- =====================================================================

-- ---------- 私有設定（不對外開放） ----------
create schema if not exists private;
revoke all on schema private from anon, authenticated;

create table if not exists private.app_settings (
  k text primary key,
  v text not null
);
-- 註冊用的通關密語（比對時忽略大小寫與空白）。要更換密語，改這一行再執行一次。
insert into private.app_settings (k, v) values ('passphrase', '我是rich')
  on conflict (k) do update set v = excluded.v;

create or replace function private.norm_pass(t text) returns text
language sql immutable as $$
  select lower(regexp_replace(coalesce(t, ''), '[[:space:]　]', '', 'g'))
$$;

-- ---------- 擁有者（後台暫時只有這個帳號看得到） ----------
create or replace function public.owner_email() returns text
language sql immutable as $$ select 'anna258266@gmail.com'::text $$;

-- ---------- 學員帳號 ----------
create table if not exists public.students (
  user_id      uuid primary key references auth.users(id) on delete cascade deferrable initially deferred,
  student_no   text not null unique,
  email        text not null,
  role         text not null default 'student' check (role in ('student', 'viewer', 'manager', 'owner')),
  suspended    boolean not null default false,
  suspend_note text,
  created_at   timestamptz not null default now()
);
alter table public.students enable row level security;

-- ---------- 權限判斷 ----------
create or replace function public.is_owner() returns boolean
language sql stable security definer set search_path = public, auth as $$
  select exists (
    select 1 from auth.users u
    where u.id = auth.uid()
      and lower(u.email) = public.owner_email()
      and u.email_confirmed_at is not null
  )
$$;

create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_owner() or exists (
    select 1 from public.students s
    where s.user_id = auth.uid() and s.role in ('viewer', 'manager', 'owner') and not s.suspended
  )
$$;

create or replace function public.is_manager() returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_owner() or exists (
    select 1 from public.students s
    where s.user_id = auth.uid() and s.role in ('manager', 'owner') and not s.suspended
  )
$$;

create or replace function public.is_member() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.students s where s.user_id = auth.uid() and not s.suspended)
$$;

drop policy if exists students_read on public.students;
create policy students_read on public.students
  for select to authenticated
  using (user_id = auth.uid() or public.is_staff());
-- 不開放直接修改；停權、身分調整只能透過下方的後台函式。

-- ---------- 註冊：密語在伺服器端檢查 ----------
-- 用「學員編號＋信箱＋密碼」註冊時，通關密語與學員編號放在 signUp 的 metadata，
-- 這個觸發器會檢查密語、移除密語、建立學員資料；密語不對就整個註冊失敗。
create or replace function private.on_auth_user_created() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare
  sno  text := upper(trim(coalesce(new.raw_user_meta_data ->> 'student_no', '')));
  pass text := new.raw_user_meta_data ->> 'passphrase';
begin
  if sno = '' then
    return new; -- 例如用 Google 登入：之後在網站上補填密語與學員編號
  end if;
  if private.norm_pass(pass) <> (select v from private.app_settings where k = 'passphrase') then
    raise exception 'RICH_BAD_PASSPHRASE';
  end if;
  if exists (select 1 from public.students where student_no = sno) then
    raise exception 'RICH_DUP_STUDENT_NO';
  end if;
  new.raw_user_meta_data := new.raw_user_meta_data - 'passphrase';
  insert into public.students (user_id, student_no, email) values (new.id, sno, lower(new.email));
  return new;
end $$;

drop trigger if exists rich_on_auth_user_created on auth.users;
create trigger rich_on_auth_user_created
  before insert on auth.users
  for each row execute function private.on_auth_user_created();

-- 註冊前預先檢查（讓畫面能顯示清楚的錯誤）
create or replace function public.check_registration(pass text, sno text) returns text
language plpgsql stable security definer set search_path = public, private as $$
begin
  if private.norm_pass(pass) <> (select v from private.app_settings where k = 'passphrase') then
    return 'bad_pass';
  end if;
  if exists (select 1 from public.students where student_no = upper(trim(sno))) then
    return 'dup';
  end if;
  return 'ok';
end $$;

-- 用 Google 登入後補完註冊
create or replace function public.register_student(pass text, sno text) returns text
language plpgsql security definer set search_path = public, private, auth as $$
declare
  uemail text;
  s text := upper(trim(coalesce(sno, '')));
begin
  if auth.uid() is null then return 'not_signed_in'; end if;
  if exists (select 1 from public.students where user_id = auth.uid()) then return 'ok'; end if;
  if private.norm_pass(pass) <> (select v from private.app_settings where k = 'passphrase') then return 'bad_pass'; end if;
  if s !~ '^[A-Z0-9-]{2,20}$' then return 'bad_no'; end if;
  if exists (select 1 from public.students where student_no = s) then return 'dup'; end if;
  select lower(email) into uemail from auth.users where id = auth.uid();
  insert into public.students (user_id, student_no, email) values (auth.uid(), s, uemail);
  return 'ok';
end $$;

-- 用學員編號登入：查出對應的信箱
create or replace function public.login_email_for(sno text) returns text
language sql stable security definer set search_path = public as $$
  select email from public.students where student_no = upper(trim(sno)) limit 1
$$;

-- ---------- 登入紀錄（只能新增，任何人都不能修改或刪除） ----------
create table if not exists public.login_events (
  id      bigint generated always as identity primary key,
  user_id uuid references auth.users(id) on delete set null,
  email   text,
  kind    text not null check (kind in ('register', 'login', 'logout', 'open', 'pwchange', 'pwreset', 'admin', 'loginfail')),
  device  text,
  at      timestamptz not null default now()
);
alter table public.login_events enable row level security;

drop policy if exists login_events_insert on public.login_events;
create policy login_events_insert on public.login_events
  for insert to authenticated
  with check (user_id = auth.uid());

drop policy if exists login_events_read on public.login_events;
create policy login_events_read on public.login_events
  for select to authenticated
  using (public.is_staff() or user_id = auth.uid());

-- 登入失敗（尚未登入）也記錄
create or replace function public.log_login_fail(sno_or_email text, dev text) returns void
language sql security definer set search_path = public as $$
  insert into public.login_events (user_id, email, kind, device)
  values (null, left(coalesce(sno_or_email, ''), 120), 'loginfail', left(coalesce(dev, ''), 120))
$$;

-- ---------- APP 內容（名片、動態、活動、訊息…） ----------
create table if not exists public.docs (
  path       text primary key,
  col        text generated always as (split_part(path, '/', 1)) stored,
  data       jsonb not null,
  updated_at timestamptz not null default now()
);
alter table public.docs enable row level security;

create or replace function public.doc_can_read(p text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  parts text[] := string_to_array(p, '/');
  uid   text := auth.uid()::text;
begin
  if uid is null then return false; end if;
  if parts[1] = 'data' then return parts[3] = uid; end if;               -- 私人資料：只有自己
  if parts[1] in ('accounts', 'logins') then return parts[2] = uid or public.is_staff(); end if;
  return public.is_member() or public.is_staff();
end $$;

create or replace function public.doc_can_write(p text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  parts text[] := string_to_array(p, '/');
  uid   text := auth.uid()::text;
begin
  if uid is null then return false; end if;
  if parts[1] = 'data' then return parts[3] = uid and public.is_member(); end if;
  if parts[1] in ('site', 'events') then return public.is_manager(); end if;
  if parts[1] in ('accounts', 'logins') then return parts[2] = uid; end if;
  return (public.is_member() and array_length(parts, 1) = 2 and parts[2] = uid) or public.is_manager();
end $$;

drop policy if exists docs_read on public.docs;
create policy docs_read on public.docs for select to authenticated using (public.doc_can_read(path));
drop policy if exists docs_insert on public.docs;
create policy docs_insert on public.docs for insert to authenticated with check (public.doc_can_write(path));
drop policy if exists docs_update on public.docs;
create policy docs_update on public.docs for update to authenticated
  using (public.doc_can_write(path)) with check (public.doc_can_write(path));
drop policy if exists docs_delete on public.docs;
create policy docs_delete on public.docs for delete to authenticated
  using (public.doc_can_write(path) and split_part(path, '/', 1) <> 'logins');

-- 即時同步
do $$ begin
  alter publication supabase_realtime add table public.docs;
exception when duplicate_object then null; end $$;

-- ---------- 後台專用函式 ----------
create or replace function public.admin_set_suspended(target uuid, val boolean, note text default null) returns text
language plpgsql security definer set search_path = public, auth as $$
begin
  if not public.is_manager() then return 'forbidden'; end if;
  if exists (select 1 from auth.users where id = target and lower(email) = public.owner_email()) then return 'cannot_suspend_owner'; end if;
  update public.students set suspended = val, suspend_note = case when val then note else null end where user_id = target;
  return 'ok';
end $$;

create or replace function public.admin_set_role(target uuid, new_role text) returns text
language plpgsql security definer set search_path = public as $$
declare staff_count int;
begin
  if not public.is_owner() then return 'forbidden'; end if;
  if new_role not in ('student', 'viewer', 'manager') then return 'bad_role'; end if;
  if new_role <> 'student' then
    select count(*) into staff_count from public.students where role in ('viewer', 'manager', 'owner') and user_id <> target;
    if staff_count >= 50 then return 'full'; end if;
  end if;
  update public.students set role = new_role where user_id = target;
  return 'ok';
end $$;

create or replace function public.admin_whoami() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('staff', public.is_staff(), 'manager', public.is_manager(), 'owner', public.is_owner())
$$;

-- 權限：一般訪客只能呼叫註冊前檢查與學員編號登入
revoke all on function public.check_registration(text, text) from public;
grant execute on function public.check_registration(text, text) to anon, authenticated;
revoke all on function public.login_email_for(text) from public;
grant execute on function public.login_email_for(text) to anon, authenticated;
revoke all on function public.log_login_fail(text, text) from public;
grant execute on function public.log_login_fail(text, text) to anon, authenticated;
revoke all on function public.register_student(text, text) from public;
grant execute on function public.register_student(text, text) to authenticated;
revoke all on function public.admin_set_suspended(uuid, boolean, text) from public;
grant execute on function public.admin_set_suspended(uuid, boolean, text) to authenticated;
revoke all on function public.admin_set_role(uuid, text) from public;
grant execute on function public.admin_set_role(uuid, text) to authenticated;
revoke all on function public.admin_whoami() from public;
grant execute on function public.admin_whoami() to authenticated;

-- ---------- 安全強化（Supabase 安全檢查建議） ----------
alter function private.norm_pass(text) set search_path = '';
alter function public.owner_email() set search_path = '';
revoke execute on function public.admin_set_role(uuid, text) from anon;
revoke execute on function public.admin_set_suspended(uuid, boolean, text) from anon;
revoke execute on function public.admin_whoami() from anon;
revoke execute on function public.register_student(text, text) from anon;
revoke execute on function public.doc_can_read(text) from anon, public;
revoke execute on function public.doc_can_write(text) from anon, public;
revoke execute on function public.is_owner() from anon, public;
revoke execute on function public.is_staff() from anon, public;
revoke execute on function public.is_manager() from anon, public;
revoke execute on function public.is_member() from anon, public;
revoke execute on function public.owner_email() from anon, public;
grant execute on function public.doc_can_read(text), public.doc_can_write(text), public.is_owner(), public.is_staff(), public.is_manager(), public.is_member(), public.owner_email() to authenticated;
