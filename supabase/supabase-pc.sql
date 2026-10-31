-- =====================================================
--  Inventario: columnas nuevas para PC / Laptop / Servidor
--  Supabase > SQL Editor > New query > pegar todo > Run
--  (Se puede correr más de una vez sin problema)
-- =====================================================
alter table public.equipos
  add column if not exists first_name    text,
  add column if not exists last_name     text,
  add column if not exists departamento  text,
  add column if not exists celular       text,
  add column if not exists email         text,
  add column if not exists hostname      text,
  add column if not exists anydesk       text,
  add column if not exists so            text,
  add column if not exists cpu           text,
  add column if not exists ram           text,
  add column if not exists disco         text,
  add column if not exists win_key       text,
  add column if not exists office_key    text,
  add column if not exists antivirus     text,
  add column if not exists garantia      date,
  add column if not exists lbl_modelo    text,
  add column if not exists lbl_conexion  text,
  add column if not exists lbl_ip        text,
  add column if not exists imp_modelo    text,
  add column if not exists imp_conexion  text,
  add column if not exists imp_ip        text;

-- Recarga el esquema para que la app vea las columnas nuevas de inmediato
notify pgrst, 'reload schema';
