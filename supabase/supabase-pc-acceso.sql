alter table public.equipos
  add column if not exists anydesk_pw   text,
  add column if not exists splashtop    text,
  add column if not exists pc_user      text,
  add column if not exists pc_user_pw   text,
  add column if not exists pc_admin     text,
  add column if not exists pc_admin_pw  text;

notify pgrst, 'reload schema';
