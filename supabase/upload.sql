-- Upload langsung: photos (gallery), PDF and short videos stored in Supabase Storage.
-- Run once in Supabase > SQL Editor > New query > Run (after materi.sql).

-- 1. materials can now hold uploaded files and a "photo" kind
alter table materials add column if not exists files jsonb not null default '[]'::jsonb;
alter table materials drop constraint if exists materials_kind_check;
alter table materials add constraint materials_kind_check
  check (kind in ('video', 'file', 'info', 'contact', 'photo'));

-- 2. private storage bucket (only logged-in members can view; max 50 MB per file)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('materi', 'materi', false, 52428800,
        array['image/jpeg', 'image/png', 'image/webp', 'application/pdf', 'video/mp4', 'video/quicktime', 'video/webm'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- 3. who may do what with the files
drop policy if exists materi_files_read on storage.objects;
create policy materi_files_read on storage.objects for select to authenticated
  using (bucket_id = 'materi');

drop policy if exists materi_files_add on storage.objects;
create policy materi_files_add on storage.objects for insert to authenticated
  with check (bucket_id = 'materi' and public.is_admin());

drop policy if exists materi_files_change on storage.objects;
create policy materi_files_change on storage.objects for update to authenticated
  using (bucket_id = 'materi' and public.is_admin());

drop policy if exists materi_files_remove on storage.objects;
create policy materi_files_remove on storage.objects for delete to authenticated
  using (bucket_id = 'materi' and public.is_admin());
