-- =====================================================
--  📦 Stock de la oficina: equipos y materiales para instalar (UniFi, racks, cable, jacks, patch cords…)
--  Condición: nuevo · caja abierta · usado · reacondicionado · dañado / RMA
--  Cada entrada, salida a un cliente, devolución o ajuste queda en el historial (stock_mov).
--  Funciona con pistola lectora de códigos (columna "codigo" = UPC / EAN de la caja).
--  Supabase > SQL Editor > New query > pega todo > Run
--  Requiere supabase-roles.sql y supabase-presupuestos.sql (usa es_staff()). Se puede correr más de una vez. No borra nada.
--  Solo el Super admin y los operadores lo ven (los usuarios "cliente" NO).
-- =====================================================

-- por si todavía no corriste supabase-presupuestos.sql
create or replace function public.es_staff()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from perfiles where user_id = auth.uid() and rol in ('admin', 'operador'))
$$;
revoke all on function public.es_staff() from public, anon;
grant execute on function public.es_staff() to authenticated;

-- 1) Productos (una fila por producto + condición; los que llevan serial guardan cada unidad en "series")
create table if not exists public.stock_items (
  id          uuid primary key default gen_random_uuid(),
  categoria   text not null default 'otro',
  marca       text,
  modelo      text,                         -- SKU / número de parte (ej. U7-Pro, USW-Pro-24-PoE)
  nombre      text not null,                -- descripción
  condicion   text not null default 'nuevo' check (condicion in ('nuevo', 'abierto', 'usado', 'reacondicionado', 'danado')),
  unidad      text not null default 'u',    -- u · ft · caja · rollo · paquete
  cantidad    numeric not null default 0,
  minimo      numeric,                      -- punto de reorden: avisa cuando hay esto o menos
  ubicacion   text,                         -- estante / gaveta / van
  costo       numeric,                      -- lo que te cuesta (solo lo ve el administrador en la app)
  precio      numeric,                      -- precio de venta
  proveedor   text,
  serializado boolean not null default false,
  series      jsonb not null default '[]'::jsonb,   -- [{"s":"serial","mac":"..","est":"disponible|reservado|salio","cli":"cliente","f":"fecha"}]
  notas       text,
  activo      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists stock_items_cat_idx on public.stock_items (categoria, nombre);
-- código de barras de la caja (UPC / EAN) para la pistola lectora (v8.8)
alter table public.stock_items add column if not exists codigo text;
create index if not exists stock_items_codigo_idx on public.stock_items (codigo);
alter table public.stock_items enable row level security;

-- 2) Movimientos
create table if not exists public.stock_mov (
  id          uuid primary key default gen_random_uuid(),
  item_id     uuid references public.stock_items(id) on delete cascade,
  tipo        text not null check (tipo in ('entrada', 'salida', 'devolucion', 'ajuste', 'reserva', 'libera')),
  cantidad    numeric not null default 0,   -- positivo; el tipo dice si suma o resta (ajuste: la diferencia con signo)
  saldo       numeric,                      -- cantidad que quedó después
  cliente     text,
  series      jsonb not null default '[]'::jsonb,
  costo       numeric,
  nota        text,
  creado_por  text,
  created_at  timestamptz not null default now()
);
create index if not exists stock_mov_item_idx on public.stock_mov (item_id, created_at desc);
create index if not exists stock_mov_fecha_idx on public.stock_mov (created_at desc);
alter table public.stock_mov enable row level security;

do $$
declare pol record;
begin
  for pol in select policyname, tablename from pg_policies where schemaname = 'public' and tablename in ('stock_items', 'stock_mov') loop
    execute format('drop policy %I on public.%I', pol.policyname, pol.tablename);
  end loop;
  execute 'create policy stk_ver    on public.stock_items for select to authenticated using (es_staff())';
  execute 'create policy stk_crear  on public.stock_items for insert to authenticated with check (es_staff())';
  execute 'create policy stk_editar on public.stock_items for update to authenticated using (es_staff()) with check (es_staff())';
  execute 'create policy stk_borrar on public.stock_items for delete to authenticated using (es_admin())';
  execute 'create policy stm_ver    on public.stock_mov for select to authenticated using (es_staff())';
  execute 'create policy stm_crear  on public.stock_mov for insert to authenticated with check (es_staff())';
  execute 'create policy stm_borrar on public.stock_mov for delete to authenticated using (es_admin())';
  execute 'revoke all on public.stock_items, public.stock_mov from anon';
  -- select: lo controla supabase-precios-priv-cierre.sql (v9.10), sin la columna costo
  execute 'grant insert, update, delete on public.stock_items to authenticated';
  execute 'grant insert, delete on public.stock_mov to authenticated';
end $$;

create or replace function public.stock_fecha()
returns trigger language plpgsql as $$ begin new.updated_at := now(); return new; end $$;
drop trigger if exists stock_fecha on public.stock_items;
create trigger stock_fecha before update on public.stock_items for each row execute function public.stock_fecha();

create or replace function public.stock_mov_autor()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.creado_por := coalesce(nullif(split_part(coalesce(auth.jwt() ->> 'email', ''), '@', 1), ''), new.creado_por);
  return new;
end $$;
drop trigger if exists stock_mov_autor on public.stock_mov;
create trigger stock_mov_autor before insert on public.stock_mov for each row execute function public.stock_mov_autor();

notify pgrst, 'reload schema';
