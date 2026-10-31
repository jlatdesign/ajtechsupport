-- =====================================================
--  Inventario de Network: campos de red para los equipos
--  Supabase > SQL Editor > New query > pega todo > Run
--  Se puede correr más de una vez sin problema. No borra nada.
-- =====================================================
alter table public.equipos
  add column if not exists isp          text,   -- proveedor de internet (Comcast, AT&T, Spectrum...)
  add column if not exists cuenta_isp   text,   -- número de cuenta / circuito del proveedor
  add column if not exists ip_publica   text,   -- IP pública / estática
  add column if not exists ssid         text,   -- nombre de la red Wi-Fi
  add column if not exists firmware     text,
  add column if not exists puertos      text,   -- ej. 24 + 4 SFP, PoE
  add column if not exists conectado_a  uuid references public.equipos(id) on delete set null;  -- uplink

notify pgrst, 'reload schema';
