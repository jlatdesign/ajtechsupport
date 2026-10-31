-- =====================================================
--  Historial de actividad (quién cambió qué y cuándo)
--  Supabase > SQL Editor > New query > pega todo > Run
--  Se puede correr más de una vez sin problema.
-- =====================================================

create table if not exists public.actividad (
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now(),
  usuario     text,            -- usuario que hizo el cambio (sin @inventario.local)
  user_id     uuid,
  categoria   text,            -- device | security | client | group | access | data
  evento      text not null,   -- device_updated, password_changed, signed_in, ...
  severidad   smallint not null default 1,  -- 1 info · 2 bajo · 3 medio · 4 alto
  cliente     text,
  objeto_id   uuid,
  objeto      text,            -- nombre del equipo / grupo / cliente
  tipo        text,            -- tipo de equipo
  cambios     jsonb            -- {campo: [antes, después]}  (contraseñas NUNCA se guardan)
);

create index if not exists actividad_fecha_idx   on public.actividad (created_at desc);
create index if not exists actividad_objeto_idx  on public.actividad (objeto_id);

-- Seguridad: los usuarios con login solo pueden LEER el historial.
-- Nadie puede editarlo ni borrarlo desde la app.
alter table public.actividad enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'actividad' and policyname = 'actividad_select') then
    create policy "actividad_select" on public.actividad for select to authenticated using (true);
  end if;
end $$;
do $$ begin
  execute 'revoke all on public.actividad from anon, authenticated';
  execute 'grant select on public.actividad to authenticated';
end $$;

-- Usuario actual (del login)
create or replace function public.act_usuario()
returns text language sql stable as $$
  select coalesce(nullif(split_part(coalesce(auth.jwt() ->> 'email', ''), '@', 1), ''), 'system')
$$;

-- Diferencias entre la fila vieja y la nueva: {campo: [antes, después]}
create or replace function public.act_diff(o jsonb, n jsonb, ignorar text[])
returns jsonb language sql immutable as $$
  select coalesce(jsonb_object_agg(k, jsonb_build_array(left(o ->> k, 300), left(n ->> k, 300))), '{}'::jsonb)
  from (select jsonb_object_keys(n) k) keys
  where not (k = any(ignorar))
    and coalesce(nullif(o -> k, '""'::jsonb), 'null'::jsonb) is distinct from coalesce(nullif(n -> k, '""'::jsonb), 'null'::jsonb)
$$;

-- Trigger: registra cada alta, cambio y borrado
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
    values (act_usuario(), auth.uid(), cat, pre || '_created', 1, cli, (r ->> 'id')::uuid, r ->> 'nombre', r ->> 'tipo');

  elsif tg_op = 'DELETE' then
    -- guarda una copia SIN contraseñas por si hay que recuperar los datos
    insert into actividad (usuario, user_id, categoria, evento, severidad, cliente, objeto_id, objeto, tipo, cambios)
    values (act_usuario(), auth.uid(), cat, pre || '_deleted', 4, cli, (r ->> 'id')::uuid, r ->> 'nombre', r ->> 'tipo',
            jsonb_strip_nulls(o - secretos - ignorar));

  else -- UPDATE
    normales := act_diff(o, n, ignorar || secretos);
    secretas := act_diff(o, n, ignorar || array(select jsonb_object_keys(n) except select unnest(secretos)));
    if normales <> '{}'::jsonb then
      insert into actividad (usuario, user_id, categoria, evento, severidad, cliente, objeto_id, objeto, tipo, cambios)
      values (act_usuario(), auth.uid(), cat, pre || '_updated', 1, cli, (r ->> 'id')::uuid, r ->> 'nombre', r ->> 'tipo', normales);
    end if;
    if secretas <> '{}'::jsonb then
      -- solo el NOMBRE del campo, nunca el valor
      insert into actividad (usuario, user_id, categoria, evento, severidad, cliente, objeto_id, objeto, tipo, cambios)
      values (act_usuario(), auth.uid(), 'security', 'password_changed', 3, cli, (r ->> 'id')::uuid, r ->> 'nombre', r ->> 'tipo',
              (select jsonb_object_agg(k, jsonb_build_array(case when o ->> k is null or o ->> k in ('', '[]') then null else '•••' end, case when n ->> k is null or n ->> k in ('', '[]') then null else '•••' end))
               from jsonb_object_keys(secretas) k));
    end if;
  end if;
  return null;
end $$;

do $$ declare tb text; begin
  foreach tb in array array['equipos','grupos','clientes'] loop
    if not exists (select 1 from pg_trigger where tgname = 'act_' || tb) then
      execute format('create trigger %I after insert or update or delete on public.%I for each row execute function public.act_registrar()', 'act_' || tb, tb);
    end if;
  end loop;
end $$;

-- Eventos que manda la app: login, ver/copiar contraseñas, exportar, importar
create or replace function public.registrar_actividad(p_evento text, p_cliente text default null, p_objeto_id uuid default null,
                                                      p_objeto text default null, p_tipo text default null, p_detalle jsonb default null)
returns void language plpgsql security definer set search_path = public as $$
declare sev smallint; cat text;
begin
  if auth.uid() is null then raise exception 'no autorizado'; end if;
  select s, c into sev, cat from (values
    ('signed_in',          1::smallint, 'access'),
    ('account_pw_changed', 3::smallint, 'access'),
    ('password_viewed',    2::smallint, 'security'),
    ('password_copied',    2::smallint, 'security'),
    ('pw_history_viewed',  2::smallint, 'security'),
    ('export_backup',      3::smallint, 'data'),
    ('export_csv',         case when coalesce((p_detalle ->> 'pw')::boolean, false) then 3 else 2 end::smallint, 'data'),
    ('import_excel',       1::smallint, 'data')
  ) v(e, s, c) where e = p_evento;
  if sev is null then raise exception 'evento no permitido: %', p_evento; end if;
  insert into actividad (usuario, user_id, categoria, evento, severidad, cliente, objeto_id, objeto, tipo, cambios)
  values (act_usuario(), auth.uid(), cat, p_evento, sev, p_cliente, p_objeto_id, left(p_objeto, 200), p_tipo, p_detalle);
end $$;

do $$ begin
  execute 'revoke all on function public.registrar_actividad(text, text, uuid, text, text, jsonb) from public, anon';
  execute 'grant execute on function public.registrar_actividad(text, text, uuid, text, text, jsonb) to authenticated';
  execute 'revoke all on function public.act_registrar() from public, anon, authenticated';
end $$;

notify pgrst, 'reload schema';
