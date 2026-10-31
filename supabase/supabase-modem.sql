-- =====================================================
--  Modo del módem: Router (NAT) / IP Passthrough / IP fija / Bridge
--  + bloque de IP fija + lado privado (LAN, WiFi, otros equipos)
--  Supabase > SQL Editor > New query > pega todo > Run
--  Se puede correr más de una vez sin problema. No borra nada.
-- =====================================================
-- Ejemplo: {"modo":"passthrough","pt_asig":"fixed","pt_mac":"74:AC:B9:11:22:33",
--           "fija":true,"n":"5","ini":"108.200.10.9","fin":"108.200.10.13","gw":"108.200.10.14","mask":"255.255.255.248",
--           "lan_ip":"192.168.1.254","wifi":"on","otros":"si","otros_nota":"Teléfonos AT&T"}
alter table public.equipos
  add column if not exists modem jsonb not null default '{}'::jsonb;

notify pgrst, 'reload schema';
