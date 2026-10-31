-- =====================================================
--  📍 Ubicaciones (sedes) por cliente  +  🔐 VPN entre ubicaciones
--  Supabase > SQL Editor > New query > pega todo > Run
--  Se puede correr más de una vez sin problema. No borra nada.
-- =====================================================

-- 1) Ubicaciones de cada cliente
create table if not exists public.sedes (
  id         uuid primary key default gen_random_uuid(),
  cliente    text not null,
  nombre     text not null,
  direccion  text,
  contacto   text,
  telefono   text,
  notas      text,
  orden      integer,
  created_at timestamptz not null default now()
);
alter table public.sedes enable row level security;

-- Cada equipo puede estar en una ubicación (si se borra la ubicación, el equipo queda "sin ubicación")
alter table public.equipos
  add column if not exists sede_id uuid references public.sedes(id) on delete set null;

-- 2) VPN entre ubicaciones (o hacia afuera: nube, otra compañía)
create table if not exists public.vpns (
  id         uuid primary key default gen_random_uuid(),
  cliente    text not null,
  nombre     text,
  sede_a     uuid references public.sedes(id) on delete set null,
  sede_b     uuid references public.sedes(id) on delete set null,
  externo    text,                 -- destino cuando no es una ubicación del cliente (Azure, AWS, otra compañía...)
  tipo       text,                 -- IPsec site-to-site, WireGuard, OpenVPN, Site Magic / SD-WAN, ...
  equipo_a   uuid references public.equipos(id) on delete set null,
  equipo_b   uuid references public.equipos(id) on delete set null,
  red_a      text,                 -- ej. 192.168.1.0/24
  red_b      text,
  estado     text default 'Activa',
  notas      text,
  created_at timestamptz not null default now()
);
alter table public.vpns enable row level security;

-- 3) Permisos: igual que los grupos (con supabase-roles.sql: cada quien ve solo sus compañías)
do $$
declare tb text; pol record; con_roles boolean := to_regprocedure('public.acceso_cliente(text,text)') is not null;
begin
  foreach tb in array array['sedes', 'vpns'] loop
    for pol in select policyname from pg_policies where schemaname = 'public' and tablename = tb loop
      execute format('drop policy %I on public.%I', pol.policyname, tb);
    end loop;
    if con_roles then
      execute format('create policy %I on public.%I for select to authenticated using (acceso_cliente(cliente))', tb || '_ver', tb);
      execute format('create policy %I on public.%I for insert to authenticated with check (acceso_cliente(cliente, ''editar''))', tb || '_crear', tb);
      execute format('create policy %I on public.%I for update to authenticated using (acceso_cliente(cliente, ''editar'')) with check (acceso_cliente(cliente, ''editar''))', tb || '_editar', tb);
      execute format('create policy %I on public.%I for delete to authenticated using (acceso_cliente(cliente, ''borrar''))', tb || '_borrar', tb);
    else
      execute format('create policy %I on public.%I for all to authenticated using (true) with check (true)', tb || '_all', tb);
    end if;
    execute format('revoke all on public.%I from anon', tb);
    execute format('grant select, insert, update, delete on public.%I to authenticated', tb);
  end loop;
end $$;

-- 4) Historial de actividad (si está instalado): también registra ubicaciones y VPN
create or replace function public.act_registrar()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  secretos  text[] := array['password','win_key','office_key','anydesk_pw','pc_user_pw','pc_admin_pw','pc_users','claves'];
  ignorar   text[] := array['id','created_at','updated_at','creado_por','pw_history'];
  o jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  n jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  r jsonb := coalesce(n, o);
  cat text := case tg_table_name when 'equipos' then 'device' when 'grupos' then 'group' when 'sedes' then 'location' when 'vpns' then 'vpn' when 'cloud_items' then 'cloud' else 'client' end;
  pre text := case tg_table_name when 'equipos' then 'device' when 'grupos' then 'group' when 'sedes' then 'location' when 'vpns' then 'vpn' when 'cloud_items' then 'cloud' else 'client' end;
  cli text := case tg_table_name when 'clientes' then r ->> 'nombre' else r ->> 'cliente' end;
  normales jsonb; secretas jsonb;
begin
  if tg_op = 'INSERT' then
    insert into actividad (usuario, user_id, categoria, evento, severidad, cliente, objeto_id, objeto, tipo)
    values (act_usuario(), auth.uid(), cat, pre || '_created', 1, cli, (r ->> 'id')::uuid, r ->> 'nombre', coalesce(coalesce(r ->> 'tipo', r ->> 'clase'), r ->> 'clase'));

  elsif tg_op = 'DELETE' then
    -- guarda una copia SIN contraseñas por si hay que recuperar los datos
    insert into actividad (usuario, user_id, categoria, evento, severidad, cliente, objeto_id, objeto, tipo, cambios)
    values (act_usuario(), auth.uid(), cat, pre || '_deleted', 4, cli, (r ->> 'id')::uuid, r ->> 'nombre', coalesce(r ->> 'tipo', r ->> 'clase'),
            jsonb_strip_nulls(o - secretos - ignorar));

  else -- UPDATE
    normales := act_diff(o, n, ignorar || secretos);
    secretas := act_diff(o, n, ignorar || array(select jsonb_object_keys(n) except select unnest(secretos)));
    if normales <> '{}'::jsonb then
      insert into actividad (usuario, user_id, categoria, evento, severidad, cliente, objeto_id, objeto, tipo, cambios)
      values (act_usuario(), auth.uid(), cat, pre || '_updated', 1, cli, (r ->> 'id')::uuid, r ->> 'nombre', coalesce(r ->> 'tipo', r ->> 'clase'), normales);
    end if;
    if secretas <> '{}'::jsonb then
      -- solo el NOMBRE del campo, nunca el valor
      insert into actividad (usuario, user_id, categoria, evento, severidad, cliente, objeto_id, objeto, tipo, cambios)
      values (act_usuario(), auth.uid(), 'security', 'password_changed', 3, cli, (r ->> 'id')::uuid, r ->> 'nombre', coalesce(r ->> 'tipo', r ->> 'clase'),
              (select jsonb_object_agg(k, jsonb_build_array(case when o ->> k is null or o ->> k in ('', '[]') then null else '•••' end, case when n ->> k is null or n ->> k in ('', '[]') then null else '•••' end))
               from jsonb_object_keys(secretas) k));
    end if;
  end if;
  return null;
end $$;

do $$ declare tb text; begin
  if to_regclass('public.actividad') is not null then
    foreach tb in array array['sedes', 'vpns'] loop
      if not exists (select 1 from pg_trigger where tgname = 'act_' || tb) then
        execute format('create trigger %I after insert or update or delete on public.%I for each row execute function public.act_registrar()', 'act_' || tb, tb);
      end if;
    end loop;
  end if;
end $$;

notify pgrst, 'reload schema';
