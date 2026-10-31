-- =====================================================
--  Servicios por cliente (IT, Network, Telefonía, Cloud, Printer)
--  Supabase > SQL Editor > New query > pega todo > Run
--  Se puede correr más de una vez sin problema.
-- =====================================================

-- Ejemplo de lo que se guarda:
-- {"it": {"excl": ["cctv","tel"], "nota": ""}, "net": {}, "tel": {"nota": "3CX · 12 ext."}}
-- (si la llave existe, el servicio está activo)
alter table public.clientes
  add column if not exists servicios jsonb not null default '{}'::jsonb;

notify pgrst, 'reload schema';
