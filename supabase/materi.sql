-- Materi: info for every logged-in member: videos, files (PDF/brosur via link),
-- announcements and admin contacts. Owner and masters manage them from the website.
-- Run once in Supabase > SQL Editor > New query > Run.

create table if not exists materials (
  id          uuid primary key default gen_random_uuid(),
  kind        text not null default 'video' check (kind in ('video', 'file', 'info', 'contact')),
  title       text not null check (char_length(title) between 1 and 120),
  url         text not null default '' check (url = '' or (url ~* '^https://' and char_length(url) <= 500)),
  note        text not null default '' check (char_length(note) <= 2000),
  sort        int  not null default 0,
  created_by  uuid default auth.uid(),
  created_at  timestamptz not null default now()
);

alter table materials enable row level security;

drop policy if exists materials_read on materials;
create policy materials_read on materials for select to authenticated using (true);

drop policy if exists materials_admin_write on materials;
create policy materials_admin_write on materials for all to authenticated
  using (is_admin()) with check (is_admin());

grant select, insert, update, delete on materials to authenticated;
