-- =====================================================
--  ☁️ Cloud Server: bitácora de los servidores del cliente en el data center
--  Servidores · Impresoras remotas (port forward) · Software y sus claves ·
--  Firewall · Contactos de proveedores · Bitácora de trabajos
--  Supabase > SQL Editor > New query > pega todo > Run
--  Requiere supabase-roles.sql (permisos). Se puede correr más de una vez. No borra nada.
-- =====================================================

-- 1) Todo lo del Cloud de un cliente. "clase" dice qué es:
--    server | usuario (RDP) | printer | software | carpeta | firewall | contacto
create table if not exists public.cloud_items (
  id         uuid primary key default gen_random_uuid(),
  cliente    text not null,
  clase      text not null,
  nombre     text not null,
  sede_id    uuid references public.sedes(id) on delete set null,
  datos      jsonb not null default '{}'::jsonb,   -- los campos de cada clase
  claves     jsonb not null default '[]'::jsonb,   -- [{usuario, password, nota}]  ← SECRETO (contraseñas de servers, software y usuarios RDP)
  orden      integer,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.cloud_items drop constraint if exists cloud_items_clase_check;
alter table public.cloud_items add constraint cloud_items_clase_check check (clase in ('server','usuario','printer','software','carpeta','firewall','contacto'));
create index if not exists cloud_items_cliente_idx on public.cloud_items (lower(cliente), clase);
alter table public.cloud_items enable row level security;

-- 2) Bitácora: cada trabajo, cambio, incidente o llamada al proveedor
create table if not exists public.cloud_log (
  id         uuid primary key default gen_random_uuid(),
  cliente    text not null,
  fecha      timestamptz not null default now(),
  usuario    text,
  user_id    uuid default auth.uid(),
  categoria  text,          -- cambio | mantenimiento | incidente | backup | actualizacion | llamada | nota
  item_id    uuid references public.cloud_items(id) on delete set null,
  texto      text not null,
  created_at timestamptz not null default now()
);
create index if not exists cloud_log_cliente_idx on public.cloud_log (lower(cliente), fecha desc);
alter table public.cloud_log enable row level security;

-- 3) Permisos: cada quien ve solo sus compañías
do $$
declare tb text; pol record;
begin
  foreach tb in array array['cloud_items', 'cloud_log'] loop
    for pol in select policyname from pg_policies where schemaname = 'public' and tablename = tb loop
      execute format('drop policy %I on public.%I', pol.policyname, tb);
    end loop;
    execute format('create policy %I on public.%I for select to authenticated using (acceso_cliente(cliente))', tb || '_ver', tb);
    execute format('create policy %I on public.%I for insert to authenticated with check (acceso_cliente(cliente, ''editar''))', tb || '_crear', tb);
    execute format('create policy %I on public.%I for delete to authenticated using (acceso_cliente(cliente, ''borrar''))', tb || '_borrar', tb);
    execute format('revoke all on public.%I from anon, authenticated', tb);
  end loop;
  -- cloud_items se edita; la bitácora NO se edita (solo se agrega o se borra)
  execute 'create policy cloud_items_editar on public.cloud_items for update to authenticated using (acceso_cliente(cliente, ''editar'')) with check (acceso_cliente(cliente, ''editar''))';
  -- Las claves NO se pueden leer directo de la tabla: solo con cloud_listar() y si el usuario puede ver contraseñas
  execute 'grant select (id, cliente, clase, nombre, sede_id, datos, orden, created_at, updated_at) on public.cloud_items to authenticated';
  execute 'grant insert, update, delete on public.cloud_items to authenticated';
  execute 'grant select, insert, delete on public.cloud_log to authenticated';
end $$;

-- 4) Lista para la app (con claves solo si el usuario puede verlas)
create or replace function public.cloud_listar()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(
           case when acceso_cliente(c.cliente, 'claves') then to_jsonb(c) else to_jsonb(c) - 'claves' end
           order by c.cliente, c.clase, c.orden nulls last, c.nombre), '[]'::jsonb)
  from cloud_items c
  where acceso_cliente(c.cliente)
$$;

-- 5) Quien no puede ver contraseñas tampoco las puede cambiar ni borrar sin querer
create or replace function public.cloud_proteger()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.updated_at := now();
  if auth.uid() is not null and not acceso_cliente(coalesce(new.cliente, old.cliente), 'claves') then
    if tg_op = 'INSERT' then new.claves := '[]'::jsonb; else new.claves := old.claves; end if;
  end if;
  return new;
end $$;
drop trigger if exists cloud_proteger on public.cloud_items;
create trigger cloud_proteger before insert or update on public.cloud_items for each row execute function public.cloud_proteger();

-- La bitácora siempre queda con el usuario real (no se puede poner otro nombre)
create or replace function public.cloud_log_autor()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.user_id := auth.uid();
  new.usuario := coalesce(nullif(split_part(coalesce(auth.jwt() ->> 'email', ''), '@', 1), ''), new.usuario, 'system');
  new.created_at := now();
  if new.fecha is null or new.fecha > now() + interval '1 day' then new.fecha := now(); end if;
  return new;
end $$;
drop trigger if exists cloud_log_autor on public.cloud_log;
create trigger cloud_log_autor before insert on public.cloud_log for each row execute function public.cloud_log_autor();

-- 6) Historial de actividad: también registra el Cloud (las claves NUNCA se guardan, solo "•••")
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


do $$ begin
  if to_regclass('public.actividad') is not null and not exists (select 1 from pg_trigger where tgname = 'act_cloud_items') then
    execute 'create trigger act_cloud_items after insert or update or delete on public.cloud_items for each row execute function public.act_registrar()';
  end if;
end $$;

do $$ begin
  execute 'revoke all on function public.cloud_listar() from public, anon';
  execute 'grant execute on function public.cloud_listar() to authenticated';
  execute 'revoke all on function public.cloud_proteger(), public.cloud_log_autor() from public, anon, authenticated';
end $$;

notify pgrst, 'reload schema';
