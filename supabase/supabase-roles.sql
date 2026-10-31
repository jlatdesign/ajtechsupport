-- =====================================================
--  Usuarios y permisos (versión 2)
--    👑 Super admin  · 👷 Operador  · 🏢 Cliente  · 🚫 Sin acceso
--  + quién está conectado  + desconexión por inactividad por usuario
--
--  Supabase > SQL Editor > New query > pega todo > Run
--  Se puede correr más de una vez sin problema. No borra datos.
--
--  La primera vez que se instaló, TODOS los usuarios que existían
--  quedaron como Super admin. Volver a correrlo NO cambia los roles.
-- =====================================================

-- 1) Perfil de cada usuario
create table if not exists public.perfiles (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  rol          text not null default 'cliente',
  clientes     text[] not null default '{}',      -- compañías que puede ver (solo rol cliente)
  puede_editar boolean not null default false,    -- cliente: agregar / editar / borrar equipos de sus compañías
  ver_claves   boolean not null default false,    -- ver contraseñas y licencias
  updated_at   timestamptz not null default now()
);
alter table public.perfiles enable row level security;
alter table public.perfiles
  add column if not exists visto_at    timestamptz,   -- última señal de vida (cada minuto mientras la app está abierta)
  add column if not exists visto_donde text,          -- en qué parte de la app está
  add column if not exists auto_logout_min integer;   -- desconexión por inactividad de ESTE usuario (null = apagado)
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'perfiles_auto_logout_check') then
    execute 'alter table public.perfiles add constraint perfiles_auto_logout_check check (auto_logout_min is null or auto_logout_min between 5 and 480)';
  end if;
end $$;

-- Roles permitidos (agrega 'operador')
do $$ declare c record; begin
  for c in select conname from pg_constraint where conrelid = 'public.perfiles'::regclass and contype = 'c' and pg_get_constraintdef(oid) ilike '%rol%' loop
    execute format('alter table public.perfiles drop constraint %I', c.conname);
  end loop;
  execute 'alter table public.perfiles add constraint perfiles_rol_check check (rol in (''admin'', ''operador'', ''cliente''))';
end $$;

-- Primera vez: los usuarios existentes pasan a ser Super admin
do $$ begin
  if not exists (select 1 from public.perfiles where rol = 'admin') then
    insert into public.perfiles (user_id, rol, puede_editar, ver_claves)
    select id, 'admin', true, true from auth.users
    on conflict (user_id) do update set rol = 'admin', puede_editar = true, ver_claves = true;
  end if;
end $$;

-- Ajustes generales (una sola fila)
create table if not exists public.ajustes (
  id              integer primary key default 1 check (id = 1),
  auto_logout     boolean not null default false,   -- cerrar sesión por inactividad (Operador y Cliente)
  auto_logout_min integer not null default 30 check (auto_logout_min between 5 and 480),
  updated_at      timestamptz not null default now()
);
insert into public.ajustes (id) values (1) on conflict (id) do nothing;
alter table public.ajustes enable row level security;

-- 2) Funciones de permiso
create or replace function public.es_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from perfiles where user_id = auth.uid() and rol = 'admin')
$$;

-- nivel: 'ver' | 'editar' | 'borrar' | 'claves'
--   admin    → todo
--   operador → ve y edita TODAS las compañías; no borra; claves si ver_claves
--   cliente  → solo sus compañías; editar/borrar si puede_editar; claves si ver_claves
create or replace function public.acceso_cliente(c text, nivel text default 'ver')
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from perfiles p
    where p.user_id = auth.uid()
      and (p.rol = 'admin'
           or (p.rol = 'operador' and (nivel in ('ver', 'editar') or (nivel = 'claves' and p.ver_claves)))
           or (p.rol = 'cliente'
               and exists (select 1 from unnest(p.clientes) x where lower(trim(x)) = lower(trim(c)))
               and (nivel = 'ver' or (nivel in ('editar', 'borrar') and p.puede_editar) or (nivel = 'claves' and p.ver_claves))))
  )
$$;

-- 3) Reglas por tabla (RLS)
do $$
declare pol record;
begin
  for pol in select policyname, tablename from pg_policies
             where schemaname = 'public' and tablename in ('equipos', 'grupos', 'clientes', 'actividad', 'perfiles', 'ajustes') loop
    execute format('drop policy %I on public.%I', pol.policyname, pol.tablename);
  end loop;

  -- EQUIPOS
  execute 'create policy equipos_ver    on public.equipos for select to authenticated using (acceso_cliente(cliente))';
  execute 'create policy equipos_crear  on public.equipos for insert to authenticated with check (acceso_cliente(cliente, ''editar''))';
  execute 'create policy equipos_editar on public.equipos for update to authenticated using (acceso_cliente(cliente, ''editar'')) with check (acceso_cliente(cliente, ''editar''))';
  execute 'create policy equipos_borrar on public.equipos for delete to authenticated using (acceso_cliente(cliente, ''borrar''))';
  -- GRUPOS
  execute 'create policy grupos_ver    on public.grupos for select to authenticated using (acceso_cliente(cliente))';
  execute 'create policy grupos_crear  on public.grupos for insert to authenticated with check (acceso_cliente(cliente, ''editar''))';
  execute 'create policy grupos_editar on public.grupos for update to authenticated using (acceso_cliente(cliente, ''editar'')) with check (acceso_cliente(cliente, ''editar''))';
  execute 'create policy grupos_borrar on public.grupos for delete to authenticated using (acceso_cliente(cliente, ''borrar''))';
  -- CLIENTES (crear, editar y borrar compañías: solo Super admin)
  execute 'create policy clientes_ver    on public.clientes for select to authenticated using (acceso_cliente(nombre))';
  execute 'create policy clientes_crear  on public.clientes for insert to authenticated with check (es_admin())';
  execute 'create policy clientes_editar on public.clientes for update to authenticated using (es_admin()) with check (es_admin())';
  execute 'create policy clientes_borrar on public.clientes for delete to authenticated using (es_admin())';
  -- ACTIVIDAD (solo lectura)
  if to_regclass('public.actividad') is not null then
    execute 'create policy actividad_ver on public.actividad for select to authenticated using (es_admin() or (cliente is not null and acceso_cliente(cliente)))';
  end if;
  -- PERFILES y AJUSTES (solo lectura; se cambian con las funciones de admin)
  execute 'create policy perfiles_ver on public.perfiles for select to authenticated using (user_id = auth.uid() or es_admin())';
  execute 'create policy ajustes_ver  on public.ajustes  for select to authenticated using (true)';

  execute 'revoke select on public.equipos from anon, authenticated';
  execute 'grant select (id, cliente, grupo_id) on public.equipos to authenticated';
  execute 'grant insert, update, delete on public.equipos to authenticated';
  execute 'revoke all on public.perfiles from anon, authenticated';
  execute 'grant select on public.perfiles to authenticated';
  execute 'revoke all on public.ajustes from anon, authenticated';
  execute 'grant select on public.ajustes to authenticated';
end $$;

-- 4) Lista de equipos para la app (quita las contraseñas si el usuario no puede verlas)
create or replace function public.equipos_listar()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(
           case when acceso_cliente(e.cliente, 'claves') then to_jsonb(e)
                else to_jsonb(e) - array['password','win_key','office_key','anydesk_pw','pc_user_pw','pc_admin_pw','pc_users','pw_history'] end
           order by e.cliente, e.nombre), '[]'::jsonb)
  from equipos e
  where acceso_cliente(e.cliente)
$$;

-- 5) Si alguien sin permiso de contraseñas guarda un equipo, sus contraseñas no se tocan
create or replace function public.proteger_claves()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return new; end if;
  if tg_op = 'INSERT' then
    if acceso_cliente(new.cliente, 'claves') then return new; end if;
    new.password := null; new.win_key := null; new.office_key := null; new.anydesk_pw := null;
    new.pc_user_pw := null; new.pc_admin_pw := null; new.pc_users := '[]'::jsonb; new.pw_history := '[]'::jsonb;
  else
    if acceso_cliente(old.cliente, 'claves') and acceso_cliente(new.cliente, 'claves') then return new; end if;
    new.password := old.password; new.win_key := old.win_key; new.office_key := old.office_key; new.anydesk_pw := old.anydesk_pw;
    new.pc_user_pw := old.pc_user_pw; new.pc_admin_pw := old.pc_admin_pw; new.pc_users := old.pc_users; new.pw_history := old.pw_history;
  end if;
  return new;
end $$;

do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'equipos_proteger_claves') then
    execute 'create trigger equipos_proteger_claves before insert or update on public.equipos for each row execute function public.proteger_claves()';
  end if;
end $$;

-- 6) Funciones de la app
create or replace function public.mi_perfil()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare p perfiles; aj ajustes;
begin
  select * into p from perfiles where user_id = auth.uid();
  if not found then return jsonb_build_object('rol', null); end if;
  select * into aj from ajustes where id = 1;
  return jsonb_build_object(
    'rol', p.rol, 'clientes', to_jsonb(p.clientes),
    'editar',   p.rol in ('admin', 'operador') or p.puede_editar,
    'borrar',   p.rol = 'admin' or (p.rol = 'cliente' and p.puede_editar),
    'claves',   p.rol = 'admin' or p.ver_claves,
    'exportar', p.rol <> 'operador',
    'prefs',    coalesce(to_jsonb(p) -> 'prefs', '{}'::jsonb),
    'logout',   p.auto_logout_min);   -- por usuario (lo pone el Super admin en 👥 Usuarios)
end $$;

-- Señal de vida: la app la manda cada minuto. Al admin le devuelve quién está en línea.
create or replace function public.latido(p_donde text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return null; end if;
  update perfiles set visto_at = case when p_donde = '__salio__' then now() - interval '1 hour' else now() end,
                      visto_donde = case when p_donde = '__salio__' then visto_donde else left(p_donde, 120) end
  where user_id = auth.uid();
  if not es_admin() then return null; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', p.user_id, 'email', u.email, 'rol', p.rol, 'donde', p.visto_donde, 'visto', p.visto_at)
                           order by p.visto_at desc), '[]'::jsonb)
          from perfiles p join auth.users u on u.id = p.user_id
          where p.visto_at > now() - interval '2 minutes');
end $$;

create or replace function public.admin_usuarios()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not es_admin() then raise exception 'solo el Super admin'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object(
            'id', u.id, 'email', u.email, 'ultimo', u.last_sign_in_at, 'creado', u.created_at,
            'rol', p.rol, 'clientes', coalesce(to_jsonb(p.clientes), '[]'::jsonb),
            'editar', coalesce(p.puede_editar, false), 'claves', coalesce(p.ver_claves, false),
            'visto', p.visto_at, 'donde', p.visto_donde, 'logout', p.auto_logout_min) order by u.email), '[]'::jsonb)
          from auth.users u left join perfiles p on p.user_id = u.id);
end $$;

-- p_rol: 'admin' | 'operador' | 'cliente' | 'ninguno' (sin acceso)
create or replace function public.admin_guardar_perfil(p_user uuid, p_rol text, p_clientes text[] default '{}',
                                                       p_editar boolean default false, p_claves boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare correo text;
begin
  if not es_admin() then raise exception 'solo el Super admin'; end if;
  if p_rol not in ('admin', 'operador', 'cliente', 'ninguno') then raise exception 'rol no válido'; end if;
  if p_user = auth.uid() and p_rol <> 'admin' then raise exception 'no puedes quitarte el Super admin a ti mismo'; end if;
  select email into correo from auth.users where id = p_user;
  if correo is null then raise exception 'usuario no existe'; end if;
  if p_rol = 'ninguno' then
    delete from perfiles where user_id = p_user;
  else
    insert into perfiles (user_id, rol, clientes, puede_editar, ver_claves, updated_at)
    values (p_user, p_rol, case when p_rol = 'cliente' then coalesce(p_clientes, '{}') else '{}' end,
            p_rol in ('admin', 'operador') or p_editar, p_rol = 'admin' or p_claves, now())
    on conflict (user_id) do update set rol = excluded.rol, clientes = excluded.clientes,
      puede_editar = excluded.puede_editar, ver_claves = excluded.ver_claves, updated_at = now();
  end if;
  if to_regclass('public.actividad') is not null then
    execute 'insert into actividad (usuario, user_id, categoria, evento, severidad, objeto, cambios) values ($1, $2, ''access'', ''user_access_changed'', 3, $3, $4)'
    using coalesce(nullif(split_part(coalesce(auth.jwt() ->> 'email', ''), '@', 1), ''), 'system'), auth.uid(), split_part(correo, '@', 1),
          jsonb_build_object('rol', p_rol, 'clientes', to_jsonb(coalesce(p_clientes, '{}')), 'editar', p_editar, 'claves', p_claves);
  end if;
end $$;

-- Desconexión por inactividad de un usuario en específico (solo Super admin). p_min null = apagado
create or replace function public.admin_logout_usuario(p_user uuid, p_min integer)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not es_admin() then raise exception 'solo el Super admin'; end if;
  if p_user = auth.uid() then raise exception 'no puedes ponerte desconexión automática a ti mismo'; end if;
  if p_min is not null and (p_min < 5 or p_min > 480) then raise exception 'minutos no válidos'; end if;
  update perfiles set auto_logout_min = p_min, updated_at = now() where user_id = p_user;
  if not found then raise exception 'ese usuario no tiene acceso todavía'; end if;
end $$;

-- (ajuste general anterior; ya no se usa en la app, se deja por compatibilidad)
create or replace function public.admin_ajustes(p_auto_logout boolean, p_minutos integer)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not es_admin() then raise exception 'solo el Super admin'; end if;
  update ajustes set auto_logout = coalesce(p_auto_logout, auto_logout),
                     auto_logout_min = coalesce(p_minutos, auto_logout_min), updated_at = now()
  where id = 1;
end $$;

do $$ begin
  execute 'revoke all on function public.equipos_listar() from public, anon';
  execute 'revoke all on function public.mi_perfil() from public, anon';
  execute 'revoke all on function public.latido(text) from public, anon';
  execute 'revoke all on function public.admin_usuarios() from public, anon';
  execute 'revoke all on function public.admin_guardar_perfil(uuid, text, text[], boolean, boolean) from public, anon';
  execute 'revoke all on function public.admin_ajustes(boolean, integer) from public, anon';
  execute 'revoke all on function public.admin_logout_usuario(uuid, integer) from public, anon';
  execute 'grant execute on function public.admin_logout_usuario(uuid, integer) to authenticated';
  execute 'grant execute on function public.equipos_listar(), public.mi_perfil(), public.latido(text), public.admin_usuarios(),
           public.admin_guardar_perfil(uuid, text, text[], boolean, boolean), public.admin_ajustes(boolean, integer) to authenticated';
end $$;

notify pgrst, 'reload schema';
