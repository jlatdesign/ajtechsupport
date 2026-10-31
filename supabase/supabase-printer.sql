alter table public.equipos
  add column if not exists prn_tipo  text,
  add column if not exists conexion  text;

notify pgrst, 'reload schema';
