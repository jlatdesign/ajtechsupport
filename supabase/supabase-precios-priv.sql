-- =====================================================
--  🔒 Precios privados (v9.10) — PASO 1 de 2
--  Crea las tablas solo admin y COPIA ahí tarifas, salarios, márgenes y precios.
--  No borra nada todavía: la app actual sigue funcionando.
--  Crea además un respaldo de presu_config y presupuestos.
--
--  Supabase > SQL Editor > New query > pega todo > Run
--  Requiere supabase-roles.sql, supabase-presupuestos.sql y supabase-stock.sql.
--  Se puede correr más de una vez: no pisa lo que ya esté en las tablas privadas.
-- =====================================================

-- 1) Respaldo (RLS sin políticas: nadie lo lee desde la app)
create table if not exists public.presu_config_resp910 as select * from public.presu_config;
create table if not exists public.presupuestos_resp910 as select * from public.presupuestos;
alter table public.presu_config_resp910 enable row level security;
alter table public.presupuestos_resp910 enable row level security;
revoke all on public.presu_config_resp910, public.presupuestos_resp910 from anon, authenticated;

-- 2) Tablas privadas
create table if not exists public.presu_config_priv (
  id         integer primary key default 1 check (id = 1),
  datos      jsonb not null default '{}'::jsonb,   -- tarifas, salarios, márgenes, precios por punto, materiales, renta, equipos_p
  updated_at timestamptz not null default now()
);
create table if not exists public.presupuesto_priv (
  presupuesto_id uuid primary key references public.presupuestos(id) on delete cascade,
  datos      jsonb not null default '{}'::jsonb,   -- tarifa, salario, meta y precios por línea
  totales    jsonb not null default '{}'::jsonb,   -- total, mano, mensual
  updated_at timestamptz not null default now()
);
alter table public.presu_config_priv enable row level security;
alter table public.presupuesto_priv enable row level security;

-- 3) Total que el admin libera al operador
alter table public.presupuestos
  add column if not exists total_liberado   numeric,
  add column if not exists mensual_liberado numeric,
  add column if not exists liberado_at      timestamptz;

do $$
declare pol record;
begin
  for pol in select policyname, tablename from pg_policies where schemaname = 'public' and tablename in ('presu_config_priv', 'presupuesto_priv') loop
    execute format('drop policy %I on public.%I', pol.policyname, pol.tablename);
  end loop;
  execute 'create policy pcpriv_admin on public.presu_config_priv for all to authenticated using (es_admin()) with check (es_admin())';
  execute 'create policy ppriv_admin  on public.presupuesto_priv  for all to authenticated using (es_admin()) with check (es_admin())';
  execute 'revoke all on public.presu_config_priv, public.presupuesto_priv from anon, authenticated';
  execute 'grant select, insert, update on public.presu_config_priv to authenticated';
  execute 'grant select, insert, update, delete on public.presupuesto_priv to authenticated';
end $$;

-- 4) Funciones para separar lo privado (mismas listas que PR_PRIV_* en index.html)
create or replace function public.presu_j_unir(a jsonb, b jsonb)
returns jsonb language plpgsql immutable as $$
declare k text; v jsonb; r jsonb := coalesce(a, '{}'::jsonb);
begin
  for k, v in select key, value from jsonb_each(coalesce(b, '{}'::jsonb)) loop
    if jsonb_typeof(r -> k) = 'object' and jsonb_typeof(v) = 'object' then r := jsonb_set(r, array[k], public.presu_j_unir(r -> k, v));
    else r := jsonb_set(r, array[k], v, true); end if;
  end loop;
  return r;
end $$;

create or replace function public.presu_j_solo(o jsonb, claves text[])
returns jsonb language sql immutable as $$
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) from jsonb_each(coalesce(o, '{}'::jsonb)) where key = any(claves)
$$;

-- Lo privado de la configuración
create or replace function public.presu_priv_de_config(c jsonb)
returns jsonb language plpgsql immutable as $$
declare r jsonb; tp text; T jsonb; v jsonb; it jsonb; k text; x jsonb;
begin
  r := public.presu_j_solo(c, array['tarifa','salario','cargas','extra','margen_mat','margen_eq','contingencia','pp','recargo_alt','renta']);
  if jsonb_typeof(c -> 'mat') = 'object' then r := r || jsonb_build_object('mat', (c -> 'mat') - 'desperdicio'); end if;
  if jsonb_typeof(c -> 'equipos') = 'array' and jsonb_array_length(c -> 'equipos') > 0 then
    r := r || jsonb_build_object('equipos_p', (select coalesce(jsonb_object_agg(e ->> 'm', e -> 'p'), '{}'::jsonb) from jsonb_array_elements(c -> 'equipos') e where e ->> 'm' <> '' and e -> 'p' is not null));
  end if;
  if jsonb_typeof(c -> 'tt') = 'object' then
    r := r || jsonb_build_object('tt', '{}'::jsonb);
    for tp, T in select key, value from jsonb_each(c -> 'tt') loop
      v := public.presu_j_solo(T, array['tarifa','salario','nivel','servidor','sitio','backup_tb','m365','hosting','dominio','mant','soporte','red','impresora']);
      if jsonb_typeof(T -> 'items') = 'object' then
        it := '{}'::jsonb;
        for k, x in select key, value from jsonb_each(T -> 'items') loop
          if x ? 'f' then it := it || jsonb_build_object(k, jsonb_build_object('f', x -> 'f')); end if;
        end loop;
        v := v || jsonb_build_object('items', it);
      end if;
      r := jsonb_set(r, array['tt', tp], v, true);
    end loop;
  end if;
  return r;
end $$;

-- La configuración sin nada privado
create or replace function public.presu_limpiar_config(c jsonb)
returns jsonb language plpgsql immutable as $$
declare r jsonb; tp text; T jsonb; it jsonb; k text; x jsonb;
begin
  r := coalesce(c, '{}'::jsonb) - array['tarifa','salario','cargas','extra','margen_mat','margen_eq','contingencia','pp','recargo_alt','renta'];
  if jsonb_typeof(r -> 'mat') = 'object' then r := jsonb_set(r, '{mat}', public.presu_j_solo(r -> 'mat', array['desperdicio'])); end if;
  if jsonb_typeof(r -> 'equipos') = 'array' then
    r := jsonb_set(r, '{equipos}', (select coalesce(jsonb_agg(e - 'p'), '[]'::jsonb) from jsonb_array_elements(r -> 'equipos') e));
  end if;
  if jsonb_typeof(r -> 'tt') = 'object' then
    for tp, T in select key, value from jsonb_each(r -> 'tt') loop
      T := T - array['tarifa','salario','nivel','servidor','sitio','backup_tb','m365','hosting','dominio','mant','soporte','red','impresora'];
      if jsonb_typeof(T -> 'items') = 'object' then
        it := '{}'::jsonb;
        for k, x in select key, value from jsonb_each(T -> 'items') loop it := it || jsonb_build_object(k, x - 'f'); end loop;
        T := jsonb_set(T, '{items}', it);
      end if;
      r := jsonb_set(r, array['tt', tp], T);
    end loop;
  end if;
  return r;
end $$;

-- Lo privado de un presupuesto
create or replace function public.presu_priv_de_datos(d jsonb)
returns jsonb language sql immutable as $$
  select public.presu_j_solo(d, array['tarifa','salario','meta']) || jsonb_build_object('precios', jsonb_build_object(
    'eq',  (select coalesce(jsonb_agg(jsonb_build_object('m', e ->> 'm', 'p', e -> 'p')), '[]'::jsonb) from jsonb_array_elements(case when jsonb_typeof(d -> 'equipos')   = 'array' then d -> 'equipos'   else '[]'::jsonb end) e where nullif(e ->> 'p', '') is not null and nullif(e ->> 'p', '') <> '0'),
    'mat', (select coalesce(jsonb_agg(jsonb_build_object('d', e ->> 'd', 'p', e -> 'p')), '[]'::jsonb) from jsonb_array_elements(case when jsonb_typeof(d -> 'mat_extra') = 'array' then d -> 'mat_extra' else '[]'::jsonb end) e where nullif(e ->> 'p', '') is not null and nullif(e ->> 'p', '') <> '0'),
    'par', (select coalesce(jsonb_agg(jsonb_build_object('d', e ->> 'd', 'p', e -> 'p')), '[]'::jsonb) from jsonb_array_elements(case when jsonb_typeof(d -> 'partidas')  = 'array' then d -> 'partidas'  else '[]'::jsonb end) e where nullif(e ->> 'p', '') is not null and nullif(e ->> 'p', '') <> '0')))
$$;

-- Un presupuesto sin nada privado
create or replace function public.presu_limpiar_datos(d jsonb)
returns jsonb language plpgsql immutable as $$
declare r jsonb := coalesce(d, '{}'::jsonb) - array['tarifa','salario','meta']; k text;
begin
  foreach k in array array['equipos','mat_extra','partidas'] loop
    if jsonb_typeof(r -> k) = 'array' then
      r := jsonb_set(r, array[k], (select coalesce(jsonb_agg(e - 'p'), '[]'::jsonb) from jsonb_array_elements(r -> k) e));
    end if;
  end loop;
  return r;
end $$;

-- Lo único de "totales" que puede leer o escribir un operador
create or replace function public.presu_totales_op(tt jsonb)
returns jsonb language sql immutable as $$
  select public.presu_j_solo(tt, array['horas','personas','dias','semanas','modo','factor','tipo','sitio'])
$$;

do $$ begin
  execute 'revoke all on function public.presu_j_unir(jsonb, jsonb), public.presu_j_solo(jsonb, text[]), public.presu_priv_de_config(jsonb), public.presu_limpiar_config(jsonb), public.presu_priv_de_datos(jsonb), public.presu_limpiar_datos(jsonb), public.presu_totales_op(jsonb) from public, anon, authenticated';
end $$;

-- 5) Copia la configuración: valores que estaban en el código + lo que ya guardaste en ⚙ (lo tuyo gana)
insert into public.presu_config_priv (id, datos)
select 1, public.presu_j_unir(
  $semilla${"tarifa":85,"salario":25,"cargas":0,"extra":1.5,"margen_mat":20,"margen_eq":15,"contingencia":10,"pp":{"drop_pared":225,"drop_techo":250,"cam_int":300,"cam_ext":350,"switch":200,"nvr":250,"rack":450,"fibra":650},"recargo_alt":{"14":0,"20":35,"30":60,"99":90},"renta":{"tijera":600,"boom":1200},"mat":{"cat6":0.35,"cat6p":0.55,"cat6a":0.75,"jack":6,"placa":3,"caja":6,"patch24":95,"cordon":4,"jhook":1.5,"emt":1.2,"fibra_pie":1.5,"fibra_term":150,"rack":260,"misc":5},"equipos_p":{"U7 Pro":189,"U7 Pro Max":279,"U7 Lite":99,"U7 Long-Range":159,"U7 Outdoor":249,"U6+":129,"U6 Mesh":179,"G5 Bullet":129,"G5 Turret Ultra":129,"G5 Dome":179,"G5 Pro":379,"AI Pro":499,"USW Lite 16 PoE":199,"USW Pro Max 24 PoE":799,"USW Pro Max 48 PoE":1199,"USW Enterprise 24 PoE":899,"UDM Pro Max":599,"UCG Fiber":279,"UNVR":299,"UNVR Pro":499,"HDD 8TB Surveillance":199,"UPS 1500VA rack":650,"Rack 12U pared":260},"tt":{"desmontaje":{"tarifa":75,"salario":22,"items":{"pc":{"f":4},"placas":{"f":2},"rec_pc":{"f":15},"rec_monitor":{"f":25},"discos":{"f":15},"viajes":{"f":300},"plafones":{"f":12},"firestop":{"f":15},"ups_bat":{"f":20},"contenedor":{"f":650}}},"mudanza":{"tarifa":75,"salario":22,"items":{"pc":{"f":4},"monitor":{"f":1},"viajes":{"f":300}}},"reparacion":{"tarifa":85,"salario":25,"items":{"recuperacion":{"f":300},"visitas":{"f":75}}},"web":{"tarifa":95,"salario":35,"hosting":25,"dominio":20,"mant":75},"software":{"tarifa":125,"salario":50,"soporte":18},"msp":{"tarifa":85,"salario":30,"nivel":{"basico":75,"estandar":125,"premium":200},"servidor":{"basico":150,"estandar":200,"premium":300},"sitio":50,"backup_tb":40,"m365":15,"red":10,"impresora":5},"libre":{"tarifa":85,"salario":25}}}$semilla$::jsonb,
  public.presu_priv_de_config(c.datos))
from public.presu_config c where c.id = 1
on conflict (id) do nothing;

-- 6) Copia cada presupuesto
insert into public.presupuesto_priv (presupuesto_id, datos, totales)
select p.id, public.presu_priv_de_datos(p.datos), public.presu_j_solo(p.totales, array['total','mano','mensual'])
from public.presupuestos p
on conflict (presupuesto_id) do nothing;

-- 7) Stock para la app: el costo solo le llega al Super admin
create or replace function public.stock_listar()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not es_staff() then return '[]'::jsonb; end if;
  return (select coalesce(jsonb_agg(case when es_admin() then to_jsonb(s) else to_jsonb(s) - 'costo' end order by s.nombre), '[]'::jsonb) from stock_items s);
end $$;

create or replace function public.stock_mov_listar(p_limite integer default 500)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not es_staff() then return '[]'::jsonb; end if;
  return (select coalesce(jsonb_agg(case when es_admin() then to_jsonb(m) else to_jsonb(m) - 'costo' end order by m.created_at desc), '[]'::jsonb)
          from (select * from stock_mov order by created_at desc limit least(greatest(coalesce(p_limite, 500), 1), 2000)) m);
end $$;

revoke all on function public.stock_listar(), public.stock_mov_listar(integer) from public, anon;
grant execute on function public.stock_listar(), public.stock_mov_listar(integer) to authenticated;

notify pgrst, 'reload schema';
