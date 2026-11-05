-- AGA Pro Member: database, access rules and helper functions for Supabase.
-- Run once in Supabase > SQL Editor > New query > Run.

create extension if not exists pgcrypto;

create sequence if not exists member_code_seq;

create table if not exists members (
  id          uuid primary key default gen_random_uuid(),
  code        text unique not null default ('AGA' || lpad(nextval('member_code_seq')::text, 4, '0')),
  name        text not null check (char_length(name) between 1 and 80),
  phone       text not null default '',
  city        text not null default '',
  agent_tm    text not null default '',
  agent_aga   text not null default '',
  join_date   date not null default current_date,
  status      text not null default 'aktif' check (status in ('aktif', 'nonaktif')),
  note        text not null default '',
  upline      uuid references members(id) on delete restrict,
  account     uuid unique references auth.users(id) on delete set null,
  added_by    uuid references auth.users(id) on delete set null,
  created_at  timestamptz not null default now()
);
create index if not exists members_upline_idx on members(upline);

-- owner = Steven, master = full control, viewer = may see the whole network
create table if not exists roles (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  role       text not null check (role in ('owner', 'master', 'viewer')),
  email      text,
  name       text,
  created_at timestamptz not null default now()
);

create table if not exists master_requests (
  user_id    uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  name       text not null check (char_length(name) between 1 and 60),
  email      text,
  created_at timestamptz not null default now()
);

-- ---------- helpers (security definer so policies can call them without recursion) ----------

create or replace function my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from roles where user_id = auth.uid()
$$;

create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role in ('owner', 'master') from roles where user_id = auth.uid()), false)
$$;

create or replace function sees_all() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from roles where user_id = auth.uid())
$$;

create or replace function my_member() returns uuid
language sql stable security definer set search_path = public as $$
  select id from members where account = auth.uid()
$$;

-- true when target is the caller's own record or anywhere below it
create or replace function in_my_tree(target uuid) returns boolean
language sql stable security definer set search_path = public as $$
  with recursive chain as (
    select id, upline, 0 as depth from members where id = target
    union all
    select m.id, m.upline, c.depth + 1 from members m join chain c on m.id = c.upline where c.depth < 5000
  )
  select exists (select 1 from chain where id = (select id from members where account = auth.uid()))
$$;

-- ---------- integrity: max 5 direct recruits, no cycles, non-admins cannot hand out accounts ----------

create or replace function members_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if tg_op = 'INSERT' then
    new.added_by := coalesce(auth.uid(), new.added_by);
    if not is_admin() and coalesce(current_setting('aga.self_register', true), '') <> 'on' then
      new.account := null;
    end if;
  else
    if not is_admin() then
      if new.account is distinct from old.account and coalesce(current_setting('aga.self_register', true), '') <> 'on' then
        raise exception 'Hanya pengelola yang bisa mengubah akun member';
      end if;
      if new.upline is distinct from old.upline and old.account = auth.uid() then
        raise exception 'Kamu tidak bisa memindahkan perekrutmu sendiri';
      end if;
    end if;
    new.code := old.code; new.added_by := old.added_by; new.created_at := old.created_at;
  end if;

  if new.upline is not null and (tg_op = 'INSERT' or new.upline is distinct from old.upline) then
    perform 1 from members where id = new.upline for update;
    select count(*) into n from members where upline = new.upline and id <> new.id;
    if n >= 5 then raise exception 'Perekrut ini sudah punya 5 rekrutan'; end if;
    if tg_op = 'UPDATE' and exists (
      with recursive down as (
        select id from members where upline = new.id
        union all select m.id from members m join down d on m.upline = d.id
      ) select 1 from down where id = new.upline
    ) or new.upline = new.id then
      raise exception 'Upline tidak boleh dari jaringan member itu sendiri';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists members_guard on members;
create trigger members_guard before insert or update on members
for each row execute function members_guard();

-- ---------- row level security ----------

alter table members enable row level security;
alter table roles enable row level security;
alter table master_requests enable row level security;

drop policy if exists members_read on members;
create policy members_read on members for select to authenticated
  using (sees_all() or in_my_tree(id));

drop policy if exists members_add on members;
create policy members_add on members for insert to authenticated
  with check (is_admin() or (upline is not null and in_my_tree(upline)));

drop policy if exists members_edit on members;
create policy members_edit on members for update to authenticated
  using (is_admin() or in_my_tree(id))
  with check (is_admin() or in_my_tree(id) or (upline is not null and in_my_tree(upline)));

drop policy if exists members_remove on members;
create policy members_remove on members for delete to authenticated
  using (is_admin() or (in_my_tree(id) and id is distinct from my_member()));

drop policy if exists roles_read on roles;
create policy roles_read on roles for select to authenticated
  using (user_id = auth.uid() or is_admin());

drop policy if exists roles_admin_write on roles;
create policy roles_admin_write on roles for all to authenticated
  using (is_admin() and role <> 'owner') with check (is_admin() and role <> 'owner');

drop policy if exists req_read on master_requests;
create policy req_read on master_requests for select to authenticated
  using (user_id = auth.uid() or is_admin());

drop policy if exists req_add on master_requests;
create policy req_add on master_requests for insert to authenticated
  with check (user_id = auth.uid());

drop policy if exists req_remove on master_requests;
create policy req_remove on master_requests for delete to authenticated
  using (user_id = auth.uid() or is_admin());

-- ---------- functions the website calls ----------

-- shows only the recruiter that matches a typed code, so newcomers never see the whole list
create or replace function recruiter_lookup(p_code text)
returns table (id uuid, name text, code text, used int)
language sql stable security definer set search_path = public as $$
  select m.id, m.name, m.code, (select count(*)::int from members k where k.upline = m.id)
  from members m where auth.uid() is not null and upper(m.code) = upper(trim(p_code))
$$;

create or replace function register_self(p_upline_code text, p_name text, p_phone text, p_city text,
  p_agent_tm text, p_agent_aga text, p_join_date date, p_note text)
returns uuid language plpgsql security definer set search_path = public as $$
declare up uuid; new_id uuid;
begin
  if auth.uid() is null then raise exception 'Silakan masuk dulu'; end if;
  if exists (select 1 from members where account = auth.uid()) then raise exception 'Akunmu sudah terhubung ke data member'; end if;
  select id into up from members where upper(code) = upper(trim(p_upline_code));
  if up is null then raise exception 'Kode perekrut tidak ditemukan'; end if;
  perform set_config('aga.self_register', 'on', true);
  insert into members (name, phone, city, agent_tm, agent_aga, join_date, note, upline, account)
  values (trim(p_name), coalesce(p_phone, ''), coalesce(p_city, ''), coalesce(p_agent_tm, ''), coalesce(p_agent_aga, ''),
          coalesce(p_join_date, current_date), coalesce(p_note, ''), up, auth.uid())
  returning id into new_id;
  perform set_config('aga.self_register', 'off', true);
  return new_id;
end $$;

create or replace function claim_member(p_code text, p_phone text)
returns uuid language plpgsql security definer set search_path = public as $$
declare m members;
begin
  if auth.uid() is null then raise exception 'Silakan masuk dulu'; end if;
  if exists (select 1 from members where account = auth.uid()) then raise exception 'Akunmu sudah terhubung ke data member'; end if;
  select * into m from members where upper(code) = upper(trim(p_code));
  if m.id is null or regexp_replace(m.phone, '\D', '', 'g') = ''
     or regexp_replace(m.phone, '\D', '', 'g') <> regexp_replace(coalesce(p_phone, ''), '\D', '', 'g') then
    raise exception 'Kode member dan no. HP tidak cocok';
  end if;
  if m.account is not null then raise exception 'Data ini sudah terhubung ke akun lain'; end if;
  perform set_config('aga.self_register', 'on', true);
  update members set account = auth.uid() where id = m.id;
  perform set_config('aga.self_register', 'off', true);
  return m.id;
end $$;

-- give master or viewer access to someone who already made an account on the website
create or replace function grant_role(p_email text, p_role text)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid;
begin
  if not is_admin() then raise exception 'Hanya pengelola yang bisa memberi akses'; end if;
  if p_role not in ('master', 'viewer') then raise exception 'Akses tidak dikenal'; end if;
  select id into uid from auth.users where lower(email) = lower(trim(p_email));
  if uid is null then raise exception 'Email ini belum membuat akun di website'; end if;
  if exists (select 1 from roles where user_id = uid and role = 'owner') then raise exception 'Ini akun pemilik'; end if;
  insert into roles (user_id, role, email) values (uid, p_role, lower(trim(p_email)))
  on conflict (user_id) do update set role = excluded.role, email = excluded.email;
  delete from master_requests where user_id = uid;
end $$;

create or replace function approve_request(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Hanya pengelola yang bisa menyetujui'; end if;
  insert into roles (user_id, role, email, name)
  select user_id, 'master', email, name from master_requests where user_id = p_user
  on conflict (user_id) do update set role = 'master';
  delete from master_requests where user_id = p_user;
end $$;

-- run once after Steven signs up:  select make_owner('email-steven@gmail.com');
create or replace function make_owner(p_email text)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid;
begin
  if exists (select 1 from roles where role = 'owner') and not exists (select 1 from roles where user_id = auth.uid() and role = 'owner') and auth.uid() is not null then
    raise exception 'Pemilik sudah ada';
  end if;
  select id into uid from auth.users where lower(email) = lower(trim(p_email));
  if uid is null then raise exception 'Email ini belum membuat akun di website'; end if;
  insert into roles (user_id, role, email) values (uid, 'owner', lower(trim(p_email)))
  on conflict (user_id) do update set role = 'owner';
end $$;
revoke execute on function make_owner(text) from public, anon, authenticated;

-- live updates for the website
do $$ begin
  alter publication supabase_realtime add table members;
exception when others then null; end $$;

-- after an Excel import with its own codes, move the counter past the highest AGA number
create or replace function sync_code_seq()
returns void language plpgsql security definer set search_path = public as $$
declare mx bigint;
begin
  if not is_admin() then raise exception 'Hanya pengelola'; end if;
  select coalesce(max(nullif(regexp_replace(code, '\D', '', 'g'), '')::bigint), 0) into mx from members where code ~* '^AGA';
  if mx > 0 then perform setval('member_code_seq', mx); end if;
end $$;
