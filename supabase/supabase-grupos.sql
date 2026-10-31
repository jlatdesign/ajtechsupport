-- Tabla de grupos
create table if not exists public.grupos (
  id          uuid primary key default gen_random_uuid(),
  cliente     text not null,
  nombre      text not null,
  notas       text,
  created_at  timestamptz not null default now()
);

alter table public.grupos enable row level security;
drop policy if exists "grupos_all" on public.grupos;
create policy "grupos_all" on public.grupos for all to authenticated using (true) with check (true);
revoke all on public.grupos from anon;
grant select, insert, update, delete on public.grupos to authenticated;

-- Cada equipo puede pertenecer a un grupo
alter table public.equipos
  add column if not exists grupo_id uuid references public.grupos(id) on delete set null;

notify pgrst, 'reload schema';
