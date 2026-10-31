-- =====================================================
--  🔄 Reinicios programados de equipos UniFi (v9.7)
--  Reinicio normal (APs, switches, gateways) o ciclo de PoE del puerto (teléfonos, cámaras, etc.)
--  Una regla puede llevar varios equipos: uno por uno (cada X minutos) o todos a la vez.
--  Una vez · cada N horas · diario · semanal (días) · mensual (día X, último día, 1er/2do/3er/4to/último lunes…)
--
--  Supabase > SQL Editor > New query > pega todo > Run
--  Requiere supabase-roles.sql. Se puede correr más de una vez. No borra nada.
--  Solo el Super admin (rol admin) lo ve y lo usa.
--
--  IMPORTANTE: también hay que publicar la Edge Function "reinicios" (edge-function-reinicios.ts)
--  y apagar "Verify JWT" en esa función (la llama el reloj de la base de datos, no un usuario).
-- =====================================================

create extension if not exists pg_cron;
create extension if not exists pg_net;

-- 1) Reglas de reinicio
create table if not exists public.reinicio_prog (
  id             uuid primary key default gen_random_uuid(),
  cliente        text not null,
  equipo_id      uuid not null,                 -- el equipo del inventario que se reinicia
  nombre         text,                          -- nombre del equipo (para el historial)
  modo           text not null default 'reinicio' check (modo in ('reinicio', 'poe')),
  switch_id      uuid,                          -- modo poe: el switch UniFi (equipo del inventario)
  puerto         integer,                       -- modo poe: número del puerto
  tipo           text not null check (tipo in ('una_vez', 'cada_horas', 'diario', 'semanal', 'mensual')),
  fecha_hora     timestamptz,                   -- una_vez: cuándo · cada_horas: desde cuándo
  horas          time[] not null default '{}',  -- diario / semanal / mensual: a qué hora(s)
  dias           integer[] not null default '{}',   -- semanal: 0=domingo … 6=sábado
  cada_h         integer check (cada_h between 1 and 168),
  mes_modo       text not null default 'dia' check (mes_modo in ('dia', 'nth')),
  dia_mes        integer check (dia_mes = -1 or dia_mes between 1 and 31),   -- -1 = último día del mes
  nth            integer check (nth = -1 or nth between 1 and 4),            -- -1 = el último
  nth_dia        integer check (nth_dia between 0 and 6),
  zona           text not null default 'America/New_York',
  hasta          timestamptz,                   -- opcional: deja de repetirse después de esta fecha
  activo         boolean not null default true,
  nota           text,
  proxima        timestamptz,                   -- la calcula la base de datos
  ultima         timestamptz,
  ultimo_estado  text,
  ultimo_msg     text,
  creado_por     text,
  created_at     timestamptz not null default now()
);
-- varios equipos en una sola regla (uno por uno o todos a la vez)
alter table public.reinicio_prog add column if not exists objetivos jsonb not null default '[]'::jsonb;   -- [{"equipo_id":"…","modo":"reinicio|poe","switch_id":"…","puerto":7}]
alter table public.reinicio_prog add column if not exists escalonar_seg integer not null default 60;      -- 0 = todos a la vez
alter table public.reinicio_prog alter column equipo_id drop not null;
create index if not exists reinicio_prog_prox_idx on public.reinicio_prog (activo, proxima);
create index if not exists reinicio_prog_cli_idx on public.reinicio_prog (cliente);
alter table public.reinicio_prog enable row level security;

-- 2) Historial
create table if not exists public.reinicio_log (
  id          uuid primary key default gen_random_uuid(),
  prog_id     uuid,
  cliente     text,
  equipo_id   uuid,
  nombre      text,
  modo        text,
  origen      text check (origen in ('manual', 'programado')),
  estado      text check (estado in ('ok', 'error', 'omitido')),
  mensaje     text,
  autor       text,
  created_at  timestamptz not null default now()
);
create index if not exists reinicio_log_idx on public.reinicio_log (cliente, created_at desc);
create index if not exists reinicio_log_eq_idx on public.reinicio_log (equipo_id, created_at desc);
alter table public.reinicio_log enable row level security;

-- 2b) Cola: cada equipo de una regla con varios se reinicia a su hora (uno por uno)
create table if not exists public.reinicio_cola (
  id          uuid primary key default gen_random_uuid(),
  prog_id     uuid,
  cliente     text,
  objetivo    jsonb not null,               -- {"equipo_id","modo","switch_id","puerto"}
  origen      text not null default 'programado',
  autor       text,
  hacer_en    timestamptz not null,
  estado      text not null default 'pendiente' check (estado in ('pendiente', 'tomado', 'hecho')),
  created_at  timestamptz not null default now()
);
create index if not exists reinicio_cola_idx on public.reinicio_cola (estado, hacer_en);
alter table public.reinicio_cola enable row level security;

-- 3) Llave secreta del reloj (nadie la puede leer desde la app; solo la base de datos y la Edge Function)
create table if not exists public.reinicio_cron (clave text not null);
alter table public.reinicio_cron enable row level security;
insert into public.reinicio_cron (clave)
  select replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '') where not exists (select 1 from public.reinicio_cron);

do $$
declare pol record;
begin
  for pol in select policyname, tablename from pg_policies where schemaname = 'public' and tablename in ('reinicio_prog', 'reinicio_log', 'reinicio_cron', 'reinicio_cola') loop
    execute format('drop policy %I on public.%I', pol.policyname, pol.tablename);
  end loop;
  execute 'create policy rp_ver    on public.reinicio_prog for select to authenticated using (es_admin())';
  execute 'create policy rp_crear  on public.reinicio_prog for insert to authenticated with check (es_admin())';
  execute 'create policy rp_editar on public.reinicio_prog for update to authenticated using (es_admin()) with check (es_admin())';
  execute 'create policy rp_borrar on public.reinicio_prog for delete to authenticated using (es_admin())';
  execute 'create policy rl_ver    on public.reinicio_log for select to authenticated using (es_admin())';
  execute 'create policy rc_ver    on public.reinicio_cola for select to authenticated using (es_admin())';
  -- el historial lo escribe solo la Edge Function; reinicio_cron no tiene políticas (nadie lo lee desde la app)
  execute 'revoke all on public.reinicio_prog, public.reinicio_log, public.reinicio_cron, public.reinicio_cola from anon';
  execute 'grant select on public.reinicio_cola to authenticated';
  execute 'revoke all on public.reinicio_cron from authenticated';
  execute 'grant select, insert, update, delete on public.reinicio_prog to authenticated';
  execute 'grant select on public.reinicio_log to authenticated';
end $$;

-- 4) ¿Cuándo toca el siguiente reinicio después de "desde"?
create or replace function public.reinicio_siguiente(p public.reinicio_prog, desde timestamptz)
returns timestamptz language plpgsql stable set search_path = public as $$
declare
  tz text := coalesce(nullif(p.zona, ''), 'America/New_York');
  d0 date; d date; h time; c timestamptz; ok boolean; ult int; paso interval; ancla timestamptz; k bigint;
  hs time[];
begin
  if not p.activo then return null; end if;
  if p.tipo = 'una_vez' then
    return case when p.fecha_hora > desde then p.fecha_hora end;
  end if;
  if p.tipo = 'cada_horas' then
    if coalesce(p.cada_h, 0) < 1 then return null; end if;
    paso := make_interval(hours => p.cada_h);
    ancla := coalesce(p.fecha_hora, date_trunc('hour', p.created_at));
    if ancla > desde then c := ancla;
    else k := floor(extract(epoch from (desde - ancla)) / extract(epoch from paso))::bigint + 1; c := ancla + paso * k; end if;
    return case when p.hasta is null or c <= p.hasta then c end;
  end if;
  select coalesce(array_agg(x order by x), '{}') into hs from unnest(p.horas) x;
  if array_length(hs, 1) is null then return null; end if;
  d0 := (desde at time zone tz)::date;
  for i in 0..400 loop
    d := d0 + i;
    if p.tipo = 'diario' then ok := true;
    elsif p.tipo = 'semanal' then ok := extract(dow from d)::int = any(p.dias);
    elsif p.tipo = 'mensual' then
      ult := extract(day from (date_trunc('month', d) + interval '1 month - 1 day'))::int;
      if p.mes_modo = 'nth' then
        ok := extract(dow from d)::int = p.nth_dia and (
              (p.nth > 0 and ceil(extract(day from d) / 7.0)::int = p.nth) or
              (p.nth = -1 and extract(day from d)::int > ult - 7));
      else
        ok := extract(day from d)::int = case when p.dia_mes = -1 then ult else least(p.dia_mes, ult) end;
      end if;
    else ok := false;
    end if;
    if ok then
      foreach h in array hs loop
        c := (d + h) at time zone tz;
        if c > desde then
          return case when p.hasta is null or c <= p.hasta then c end;
        end if;
      end loop;
    end if;
  end loop;
  return null;
end $$;

-- La próxima fecha se recalcula sola cuando se crea o se cambia una regla
create or replace function public.reinicio_prog_calc()
returns trigger language plpgsql set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.creado_por := coalesce(nullif(split_part(coalesce(auth.jwt() ->> 'email', ''), '@', 1), ''), new.creado_por);
    new.proxima := public.reinicio_siguiente(new, now());
  elsif new.proxima is not distinct from old.proxima then      -- la app cambió la regla (no fue el reloj)
    new.proxima := public.reinicio_siguiente(new, now());
  end if;
  return new;
end $$;
drop trigger if exists reinicio_prog_calc on public.reinicio_prog;
create trigger reinicio_prog_calc before insert or update on public.reinicio_prog for each row execute function public.reinicio_prog_calc();

-- Toma los reinicios que ya tocan y los pasa a la siguiente fecha (para que nunca se ejecuten dos veces)
create or replace function public.reinicio_tomar()
returns table (id uuid, tocaba timestamptz) language plpgsql security definer set search_path = public as $$
begin
  return query
  with due as (
    select r.id, r.proxima from public.reinicio_prog r
    where r.activo and r.proxima is not null and r.proxima <= now() + interval '20 seconds'
    for update skip locked
  )
  update public.reinicio_prog r set
    ultima  = now(),
    proxima = case when r.tipo = 'una_vez' then null else public.reinicio_siguiente(r, greatest(now(), r.proxima)) end,
    activo  = case when r.tipo = 'una_vez' then false else r.activo end
  from due where r.id = due.id
  returning r.id, due.proxima;
end $$;
revoke all on function public.reinicio_tomar() from public, anon, authenticated;

-- Toma de la cola los equipos a los que ya les toca
create or replace function public.reinicio_cola_tomar()
returns setof public.reinicio_cola language plpgsql security definer set search_path = public as $$
begin
  -- si algo quedó "tomado" más de 10 min (la función se cayó), se da por hecho para no repetirlo
  update public.reinicio_cola set estado = 'hecho' where estado = 'tomado' and hacer_en < now() - interval '10 minutes';
  return query
  with due as (select c.id from public.reinicio_cola c where c.estado = 'pendiente' and c.hacer_en <= now() + interval '20 seconds'
               order by c.hacer_en for update skip locked)
  update public.reinicio_cola c set estado = 'tomado' from due where c.id = due.id returning c.*;
end $$;
revoke all on function public.reinicio_cola_tomar() from public, anon, authenticated;

-- Las próximas N fechas de una regla (para verlas en la app)
create or replace function public.reinicio_proximas(p_id uuid, n integer default 5)
returns setof timestamptz language plpgsql stable security definer set search_path = public as $$
declare p public.reinicio_prog; c timestamptz; desde timestamptz := now();
begin
  if not es_admin() then return; end if;
  select * into p from public.reinicio_prog where id = p_id; if not found then return; end if;
  for i in 1..least(coalesce(n, 5), 20) loop
    c := public.reinicio_siguiente(p, desde); exit when c is null;
    return next c; desde := c;
    exit when p.tipo = 'una_vez';
  end loop;
end $$;
revoke all on function public.reinicio_proximas(uuid, integer) from public, anon;
grant execute on function public.reinicio_proximas(uuid, integer) to authenticated;

-- 5) El reloj: cada minuto revisa si algo toca; SOLO si toca llama a la Edge Function "reinicios"
do $$
begin
  if exists (select 1 from cron.job where jobname = 'reinicios-unifi') then perform cron.unschedule('reinicios-unifi'); end if;
end $$;
select cron.schedule('reinicios-unifi', '* * * * *', $cron$
  select net.http_post(
    url := 'https://eojunmqxbnxyjiazhwol.supabase.co/functions/v1/reinicios',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-key', (select clave from public.reinicio_cron limit 1)),
    body := '{"accion":"tick"}'::jsonb,
    timeout_milliseconds := 60000)
  where exists (select 1 from public.reinicio_prog where activo and proxima is not null and proxima <= now() + interval '20 seconds')
     or exists (select 1 from public.reinicio_cola where estado = 'pendiente' and hacer_en <= now() + interval '20 seconds');
$cron$);

-- limpieza: el historial de pg_net y de cron no crece para siempre
do $$
begin
  if exists (select 1 from cron.job where jobname = 'reinicios-limpieza') then perform cron.unschedule('reinicios-limpieza'); end if;
end $$;
select cron.schedule('reinicios-limpieza', '17 4 * * *', $cron$
  delete from cron.job_run_details where end_time < now() - interval '7 days';
  delete from public.reinicio_log where created_at < now() - interval '365 days';
  delete from public.reinicio_cola where estado = 'hecho' and hacer_en < now() - interval '30 days';
$cron$);

notify pgrst, 'reload schema';
