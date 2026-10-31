-- =====================================================
--  📐 Diseño: mapa de red con puertos + planos (pisos) con equipos y cobertura WiFi
--  Supabase > SQL Editor > New query > pega todo > Run
--  Requiere supabase-roles.sql y supabase-ubicaciones.sql. Se puede correr más de una vez. No borra nada.
-- =====================================================

-- 1) Puertos de la conexión de cada equipo de red
alter table public.equipos
  add column if not exists up_puerto text,    -- puerto del equipo de arriba (uplink) donde va conectado. ej. 8, SFP+ 1
  add column if not exists mi_puerto text,    -- puerto de este equipo que sube. ej. 25, SFP 1, WAN
  add column if not exists up_tipo   text;    -- cobre | poe | fibra | wifi

-- 2) Planos: un registro por piso de cada ubicación
create table if not exists public.planos (
  id         uuid primary key default gen_random_uuid(),
  cliente    text not null,
  sede_id    uuid references public.sedes(id) on delete set null,
  nombre     text not null,                       -- ej. Nivel 1, Almacén, Oficina
  orden      integer,
  imagen     text,                                -- ruta en Storage (bucket "planos"); vacío = plano dibujado
  ancho      integer not null default 2000,       -- tamaño del plano en puntos
  alto       integer not null default 1400,
  escala     numeric,                             -- puntos por pie (se calcula marcando dos puntos)
  datos      jsonb not null default '{}'::jsonb,  -- {equipos:[{id,x,y}], muros:[{x1,y1,x2,y2,mat}], plan:[{...}]}
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists planos_cliente_idx on public.planos (lower(cliente));
alter table public.planos enable row level security;

do $$
declare pol record;
begin
  for pol in select policyname from pg_policies where schemaname = 'public' and tablename = 'planos' loop
    execute format('drop policy %I on public.planos', pol.policyname);
  end loop;
  execute 'create policy planos_ver    on public.planos for select to authenticated using (acceso_cliente(cliente))';
  execute 'create policy planos_crear  on public.planos for insert to authenticated with check (acceso_cliente(cliente, ''editar''))';
  execute 'create policy planos_editar on public.planos for update to authenticated using (acceso_cliente(cliente, ''editar'')) with check (acceso_cliente(cliente, ''editar''))';
  execute 'create policy planos_borrar on public.planos for delete to authenticated using (acceso_cliente(cliente, ''borrar''))';
  execute 'revoke all on public.planos from anon';
  execute 'grant select, insert, update, delete on public.planos to authenticated';
end $$;

create or replace function public.planos_fecha()
returns trigger language plpgsql as $$ begin new.updated_at := now(); return new; end $$;
drop trigger if exists planos_fecha on public.planos;
create trigger planos_fecha before update on public.planos for each row execute function public.planos_fecha();

-- 3) Imágenes de los planos en Storage (privado). La carpeta es el id del plano:
--    planos/<id del plano>/plano.png  → solo quien tiene acceso a ese cliente la puede ver o cambiar
do $$ begin
  if to_regclass('storage.buckets') is not null then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('planos', 'planos', false, 15728640, array['image/png', 'image/jpeg', 'image/webp'])
    on conflict (id) do update set public = false, file_size_limit = 15728640, allowed_mime_types = array['image/png', 'image/jpeg', 'image/webp'];
  end if;
end $$;

create or replace function public.plano_acceso(p_nombre text, nivel text default 'ver')
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from planos p
    where p.id::text = split_part(p_nombre, '/', 1)
      and acceso_cliente(p.cliente, nivel)
  )
$$;
revoke all on function public.plano_acceso(text, text) from public, anon;
grant execute on function public.plano_acceso(text, text) to authenticated;

do $$
declare pol record;
begin
  if to_regclass('storage.objects') is null then return; end if;
  for pol in select policyname from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname like 'planos_%' loop
    execute format('drop policy %I on storage.objects', pol.policyname);
  end loop;
  execute 'create policy planos_img_ver    on storage.objects for select to authenticated using (bucket_id = ''planos'' and public.plano_acceso(name))';
  execute 'create policy planos_img_subir  on storage.objects for insert to authenticated with check (bucket_id = ''planos'' and public.plano_acceso(name, ''editar''))';
  execute 'create policy planos_img_cambia on storage.objects for update to authenticated using (bucket_id = ''planos'' and public.plano_acceso(name, ''editar'')) with check (bucket_id = ''planos'' and public.plano_acceso(name, ''editar''))';
  execute 'create policy planos_img_borrar on storage.objects for delete to authenticated using (bucket_id = ''planos'' and public.plano_acceso(name, ''editar''))';
end $$;

notify pgrst, 'reload schema';
