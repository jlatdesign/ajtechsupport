-- =====================================================
--  🧪 Test de red (v9.8 / v9.9): guarda las pruebas de velocidad (internet y red local) y los monitores
--  Supabase > SQL Editor > New query > pega todo > Run
--  Requiere supabase-roles.sql. Se puede correr más de una vez. No borra nada.
--  Lo ven el Super admin y los operadores (los usuarios "cliente" no).
-- =====================================================
create or replace function public.es_staff()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from perfiles where user_id = auth.uid() and rol in ('admin', 'operador'))
$$;
revoke all on function public.es_staff() from public, anon;
grant execute on function public.es_staff() to authenticated;

create table if not exists public.test_red (
  id          uuid primary key default gen_random_uuid(),
  cliente     text not null,
  tipo        text not null,
  datos       jsonb not null default '{}'::jsonb,   -- bajada, subida, ping, jitter, pérdida…
  equipo      text,                                 -- navegador / equipo donde se hizo
  autor       text,
  created_at  timestamptz not null default now()
);
-- v9.9: también guarda los monitores y las secuencias de pruebas (con su análisis)
alter table public.test_red drop constraint if exists test_red_tipo_check;
alter table public.test_red add constraint test_red_tipo_check check (tipo in ('internet', 'lan', 'monitor', 'secuencia', 'sistema'));
create index if not exists test_red_idx on public.test_red (cliente, created_at desc);
alter table public.test_red enable row level security;

do $$
declare pol record;
begin
  for pol in select policyname from pg_policies where schemaname = 'public' and tablename = 'test_red' loop
    execute format('drop policy %I on public.test_red', pol.policyname);
  end loop;
  execute 'create policy tr_ver    on public.test_red for select to authenticated using (es_staff())';
  execute 'create policy tr_crear  on public.test_red for insert to authenticated with check (es_staff())';
  execute 'create policy tr_borrar on public.test_red for delete to authenticated using (es_admin())';
  execute 'revoke all on public.test_red from anon';
  execute 'grant select, insert, delete on public.test_red to authenticated';
end $$;

create or replace function public.test_red_autor()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.autor := coalesce(nullif(split_part(coalesce(auth.jwt() ->> 'email', ''), '@', 1), ''), new.autor);
  return new;
end $$;
drop trigger if exists test_red_autor on public.test_red;
create trigger test_red_autor before insert on public.test_red for each row execute function public.test_red_autor();

notify pgrst, 'reload schema';
