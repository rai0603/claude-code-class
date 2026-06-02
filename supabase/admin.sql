-- ============================================================
-- Claude 半日班 報名後台（查詢 + 修改狀態）
-- 專案：DiDiPo Pro (ref nxjtndpfccmzbrvfxczw)
-- 在 Supabase SQL Editor 貼上整段執行一次即可。可重複執行。
-- 注意：本檔不含管理密碼；密碼由 service_role 另外寫入 class_admin。
-- ============================================================

-- 管理密碼存放（單列，RLS 鎖死，前端讀不到）
create table if not exists public.class_admin (
  id    int primary key default 1,
  token text,
  constraint class_admin_singleton check (id = 1)
);
insert into public.class_admin (id, token) values (1, null)
on conflict (id) do nothing;
alter table public.class_admin enable row level security;  -- 無 anon policy

-- ------------------------------------------------------------
-- 後台：列出某場次所有報名（需正確管理密碼）
-- ------------------------------------------------------------
create or replace function public.admin_list_registrations(
  p_token text, p_session date default '2026-06-07'
)
returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from public.class_admin
    where id = 1 and token is not null and token = p_token
  ) then
    return json_build_object('ok', false, 'message', '管理密碼錯誤');
  end if;

  return json_build_object(
    'ok', true,
    'capacity', coalesce((select capacity from public.class_sessions where session_date = p_session), 20),
    'rows', coalesce((
      select json_agg(row_to_json(t))
      from (
        select id, created_at, name, phone, email, transfer_last5, status
        from public.class_registrations
        where session_date = p_session
        order by created_at desc
      ) t
    ), '[]'::json)
  );
end;
$$;

-- ------------------------------------------------------------
-- 後台：修改某筆報名狀態（需正確管理密碼）
--   pending 待匯款 / paid 已收保證金(報名成功) / checked_in 已報到 / cancelled 取消
-- ------------------------------------------------------------
create or replace function public.admin_set_status(
  p_token text, p_id uuid, p_status text
)
returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from public.class_admin
    where id = 1 and token is not null and token = p_token
  ) then
    return json_build_object('ok', false, 'message', '管理密碼錯誤');
  end if;

  if p_status not in ('pending','paid','checked_in','cancelled') then
    return json_build_object('ok', false, 'message', '狀態不合法');
  end if;

  update public.class_registrations set status = p_status where id = p_id;
  if not found then
    return json_build_object('ok', false, 'message', '找不到該筆報名');
  end if;

  return json_build_object('ok', true);
end;
$$;

-- 權限：前端 anon 只能呼叫這兩個（內部會驗密碼）
revoke all on function public.admin_list_registrations(text,date) from public;
revoke all on function public.admin_set_status(text,uuid,text) from public;
grant execute on function public.admin_list_registrations(text,date) to anon, authenticated;
grant execute on function public.admin_set_status(text,uuid,text) to anon, authenticated;
