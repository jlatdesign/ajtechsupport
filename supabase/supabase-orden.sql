-- =====================================================
--  Clientes fijados (📌) + orden manual de clientes
--  + preferencias de cada usuario (columnas de la tabla)
--  Supabase > SQL Editor > New query > pega todo > Run
--  Requiere que ya hayas corrido supabase-roles.sql.
--  Se puede correr más de una vez sin problema. No borra nada.
-- =====================================================

-- 1) Clientes: fijado y orden
alter table public.clientes
  add column if not exists fijado boolean not null default false,
  add column if not exists orden  integer;

-- Reordenar no debe llenar el historial de actividad
create or replace function public.act_diff(o jsonb, n jsonb, ignorar text[])
returns jsonb language sql immutable as $$
  select coalesce(jsonb_object_agg(k, jsonb_build_array(left(o ->> k, 300), left(n ->> k, 300))), '{}'::jsonb)
  from (select jsonb_object_keys(n) k) keys
  where not (k = any(ignorar || array['orden', 'fijado']))
    and coalesce(nullif(o -> k, '""'::jsonb), 'null'::jsonb) is distinct from coalesce(nullif(n -> k, '""'::jsonb), 'null'::jsonb)
$$;

-- Guardar el orden de todos los clientes de una vez (solo Super admin)
create or replace function public.ordenar_clientes(p_ids uuid[])
returns void language plpgsql security definer set search_path = public as $$
begin
  if not es_admin() then raise exception 'solo el Super admin'; end if;
  update clientes c set orden = x.pos
  from unnest(p_ids) with ordinality as x(id, pos)
  where c.id = x.id and c.orden is distinct from x.pos;
end $$;

-- 2) Preferencias de cada usuario (se guardan en su perfil, lo siguen en cualquier computadora)
alter table public.perfiles
  add column if not exists prefs jsonb not null default '{}'::jsonb;

create or replace function public.guardar_prefs(p jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'no autorizado'; end if;
  if p is null or jsonb_typeof(p) <> 'object' or octet_length(p::text) > 20000 then raise exception 'preferencias no válidas'; end if;
  update perfiles set prefs = coalesce(prefs, '{}'::jsonb) || p where user_id = auth.uid();
end $$;

-- (mi_perfil vive en supabase-roles.sql y ya incluye las preferencias)

do $$ begin
  execute 'revoke all on function public.ordenar_clientes(uuid[]) from public, anon';
  execute 'revoke all on function public.guardar_prefs(jsonb) from public, anon';
  execute 'grant execute on function public.ordenar_clientes(uuid[]), public.guardar_prefs(jsonb) to authenticated';
end $$;

notify pgrst, 'reload schema';
