create table if not exists public.clientes (
  id          uuid primary key default gen_random_uuid(),
  nombre      text not null,
  direccion   text,
  contacto    text,
  telefono    text,
  email       text,
  notas       text,
  created_at  timestamptz not null default now()
);

alter table public.clientes enable row level security;

do $$
begin
  if not exists (select 1 from pg_policies where tablename = 'clientes' and policyname = 'clientes_all') then
    create policy "clientes_all" on public.clientes for all to authenticated using (true) with check (true);
  end if;
end $$;

grant select, insert, update, delete on public.clientes to authenticated;

-- Crear la ficha de los clientes que ya existen en tus equipos
insert into public.clientes (nombre, direccion)
select e.cliente, max(e.direccion)
from public.equipos e
where e.cliente is not null
  and not exists (select 1 from public.clientes c where lower(trim(c.nombre)) = lower(trim(e.cliente)))
group by e.cliente;

notify pgrst, 'reload schema';
