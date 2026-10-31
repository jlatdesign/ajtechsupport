-- =====================================================
--  Conexión con UniFi (Site Manager API)
--  Supabase > SQL Editor > New query > pega todo > Run
--  Se puede correr más de una vez sin problema. No borra nada.
-- =====================================================

-- Consolas UniFi que pertenecen a cada cliente (solo esas se consultan)
alter table public.clientes
  add column if not exists unifi_hosts jsonb not null default '[]'::jsonb;   -- [{"id":"...","nombre":"UDM Pro Stock Cargo"}]

-- Datos que vienen de UniFi en cada equipo
alter table public.equipos
  add column if not exists unifi_id      text,          -- id del equipo en UniFi
  add column if not exists unifi_estado  text,          -- online / offline
  add column if not exists unifi_update  boolean,       -- tiene actualización de firmware pendiente
  add column if not exists unifi_sync_at timestamptz;   -- última vez que se trajo de UniFi

-- Actualizar estado y firmware desde UniFi no debe llenar el historial de actividad
do $$ begin
  if to_regprocedure('public.act_diff(jsonb, jsonb, text[])') is not null then
    execute $f$
      create or replace function public.act_diff(o jsonb, n jsonb, ignorar text[])
      returns jsonb language sql immutable as $b$
        select coalesce(jsonb_object_agg(k, jsonb_build_array(left(o ->> k, 300), left(n ->> k, 300))), '{}'::jsonb)
        from (select jsonb_object_keys(n) k) keys
        where not (k = any(ignorar || array['orden', 'fijado', 'unifi_estado', 'unifi_update', 'unifi_sync_at', 'unifi_hosts']))
          and coalesce(nullif(o -> k, '""'::jsonb), 'null'::jsonb) is distinct from coalesce(nullif(n -> k, '""'::jsonb), 'null'::jsonb)
      $b$ $f$;
  end if;
end $$;

notify pgrst, 'reload schema';
