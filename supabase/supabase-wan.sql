-- =====================================================
--  WAN / Multi-WAN para Router, Firewall y Módem
--  Supabase > SQL Editor > New query > pega todo > Run
--  Se puede correr más de una vez sin problema. No borra nada.
-- =====================================================
-- Cada WAN: {"puerto":"WAN1","isp":"Comcast","conexion":"Cable","modo":"principal",
--            "ip":"73.1.2.3","velocidad":"1000/35","cuenta":"8497...","via":"<id del módem>"}
alter table public.equipos
  add column if not exists wans jsonb not null default '[]'::jsonb;

notify pgrst, 'reload schema';
