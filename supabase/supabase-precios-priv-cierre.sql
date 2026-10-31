-- =====================================================
--  🔒 Precios privados (v9.10) — PASO 2 de 2 (CIERRE)
--  Corre esto SOLO cuando la app 9.10 ya esté publicada y el Super admin vea sus precios bien.
--  Borra los valores privados de presu_config y presupuestos, y les quita el costo a los operadores.
--  Requiere supabase-precios-priv.sql. Se puede correr más de una vez.
--  Los valores anteriores quedan en presu_config_resp910 y presupuestos_resp910.
-- =====================================================

-- 1) Presupuestos creados después del paso 1 con la app anterior
insert into public.presupuesto_priv (presupuesto_id, datos, totales)
select p.id, public.presu_priv_de_datos(p.datos), public.presu_j_solo(p.totales, array['total','mano','mensual'])
from public.presupuestos p
on conflict (presupuesto_id) do nothing;

-- 2) Borra lo privado de las tablas que lee el operador
update public.presu_config set datos = public.presu_limpiar_config(datos) where id = 1;
update public.presupuestos set datos = public.presu_limpiar_datos(datos), totales = public.presu_totales_op(totales);

-- 3) Si un operador guarda, no puede meter precios ni tocar el total liberado.
--    Si cambia el contenido del presupuesto, el total liberado se retira hasta que el admin lo revise.
create or replace function public.presu_proteger()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or es_admin() then return new; end if;   -- auth.uid() null = Edge Function o SQL Editor
  new.datos := presu_limpiar_datos(new.datos);
  new.totales := presu_totales_op(new.totales);
  if tg_op = 'INSERT' then
    new.total_liberado := null; new.mensual_liberado := null; new.liberado_at := null;
  elsif new.datos is distinct from old.datos then
    new.total_liberado := null; new.mensual_liberado := null; new.liberado_at := null;
  else
    new.total_liberado := old.total_liberado; new.mensual_liberado := old.mensual_liberado; new.liberado_at := old.liberado_at;
  end if;
  return new;
end $$;
drop trigger if exists presu_proteger on public.presupuestos;
create trigger presu_proteger before insert or update on public.presupuestos for each row execute function public.presu_proteger();

-- 4) Stock: el operador no lee ni escribe el costo
create or replace function public.stock_proteger()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or es_admin() then return new; end if;
  if tg_op = 'INSERT' then new.costo := null; else new.costo := old.costo; end if;
  return new;
end $$;
drop trigger if exists stock_proteger on public.stock_items;
create trigger stock_proteger before insert or update on public.stock_items for each row execute function public.stock_proteger();
drop trigger if exists stock_mov_proteger on public.stock_mov;
create trigger stock_mov_proteger before insert on public.stock_mov for each row execute function public.stock_proteger();

do $$
declare cols text;
begin
  revoke select on public.stock_items, public.stock_mov from anon, authenticated;
  select string_agg(quote_ident(column_name), ', ') into cols from information_schema.columns
  where table_schema = 'public' and table_name = 'stock_items' and column_name <> 'costo';
  execute format('grant select (%s) on public.stock_items to authenticated', cols);
  select string_agg(quote_ident(column_name), ', ') into cols from information_schema.columns
  where table_schema = 'public' and table_name = 'stock_mov' and column_name <> 'costo';
  execute format('grant select (%s) on public.stock_mov to authenticated', cols);
end $$;

notify pgrst, 'reload schema';

-- 5) Comprobación: las dos filas deben decir 0
select 'presu_config con datos privados' as revision, count(*) as filas from public.presu_config
 where datos ?| array['tarifa','salario','cargas','extra','margen_mat','margen_eq','contingencia','pp','recargo_alt','renta']
union all
select 'presupuestos con datos privados', count(*) from public.presupuestos
 where datos ?| array['tarifa','salario','meta'] or totales ?| array['total','mano','mensual'];
