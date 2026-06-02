-- ============================================================
-- 新報名 Email 通知（Resend）
-- 在 register_for_class 內用 pg_net 非同步寄信，失敗不影響報名。
-- Resend API key 存在 notify_config（RLS 鎖死），不進前端 / repo。
-- 在 Supabase SQL Editor 貼上整段執行一次即可。
-- ============================================================

create extension if not exists pg_net;

-- 通知設定（RLS 鎖死，前端讀不到）
create table if not exists public.notify_config (
  key   text primary key,
  value text
);
alter table public.notify_config enable row level security;
insert into public.notify_config(key, value) values
  ('resend_api_key', null),                  -- ← 待你填入 re_xxx
  ('notify_from',    'onboarding@resend.dev'),
  ('notify_to',      'rai0603@gmail.com')
on conflict (key) do nothing;

-- 重新定義 register_for_class：原邏輯不變，最後加 Email 通知
create or replace function public.register_for_class(
  p_name text, p_phone text, p_email text,
  p_last5 text default null, p_session date default '2026-06-07'
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cap int; v_open boolean; v_taken int; v_id uuid; v_remaining int;
begin
  if coalesce(trim(p_name),'')='' or coalesce(trim(p_phone),'')='' or coalesce(trim(p_email),'')='' then
    return json_build_object('ok', false, 'reason','invalid', 'message','請完整填寫姓名 / 電話 / Email');
  end if;
  if position('@' in p_email) = 0 then
    return json_build_object('ok', false, 'reason','invalid', 'message','Email 格式不正確');
  end if;

  select capacity, is_open into v_cap, v_open
  from public.class_sessions where session_date = p_session for update;
  if v_cap is null then v_cap := 20; v_open := true; end if;

  if not coalesce(v_open, true) then
    return json_build_object('ok', false, 'reason','closed', 'message','本場次報名已關閉');
  end if;

  select count(*) into v_taken
  from public.class_registrations
  where session_date = p_session and status <> 'cancelled';

  if v_taken >= v_cap then
    return json_build_object('ok', false, 'reason','full', 'message','本場次名額已滿', 'remaining', 0);
  end if;

  if exists (
    select 1 from public.class_registrations
    where session_date = p_session and lower(email) = lower(p_email) and status <> 'cancelled'
  ) then
    return json_build_object('ok', false, 'reason','duplicate', 'message','這個 Email 已報名過本場次');
  end if;

  insert into public.class_registrations (session_date, name, phone, email, transfer_last5)
  values (p_session, trim(p_name), trim(p_phone), trim(p_email), nullif(trim(p_last5),''))
  returning id into v_id;

  v_remaining := greatest(v_cap - (v_taken+1), 0);

  -- ===== Email 通知（非阻斷：失敗不影響報名）=====
  declare
    v_key text; v_from text; v_to text;
  begin
    select value into v_key from public.notify_config where key = 'resend_api_key';
    if v_key is not null and v_key <> '' then
      select value into v_from from public.notify_config where key = 'notify_from';
      select value into v_to   from public.notify_config where key = 'notify_to';
      perform net.http_post(
        url := 'https://api.resend.com/emails',
        headers := jsonb_build_object('Authorization', 'Bearer '||v_key, 'Content-Type', 'application/json'),
        body := jsonb_build_object(
          'from',    coalesce(v_from, 'onboarding@resend.dev'),
          'to',      jsonb_build_array(coalesce(v_to, 'rai0603@gmail.com')),
          'subject', '🎉 新報名：'||trim(p_name)||'（剩 '||v_remaining||' 位）',
          'html',
            '<h2>半日班新報名</h2>'||
            '<table cellpadding="6" style="font-size:15px;border-collapse:collapse">'||
            '<tr><td><b>姓名</b></td><td>'||trim(p_name)||'</td></tr>'||
            '<tr><td><b>電話</b></td><td>'||trim(p_phone)||'</td></tr>'||
            '<tr><td><b>Email</b></td><td>'||trim(p_email)||'</td></tr>'||
            '<tr><td><b>匯款末五碼</b></td><td>'||coalesce(nullif(trim(p_last5),''),'（未填）')||'</td></tr>'||
            '<tr><td><b>剩餘名額</b></td><td>'||v_remaining||' / '||v_cap||'</td></tr>'||
            '</table>'||
            '<p style="margin-top:14px"><a href="https://rai0603.github.io/claude-code-class/admin.html">→ 前往報名後台</a></p>'
        )
      );
    end if;
  exception when others then
    null;  -- 通知失敗不影響報名
  end;

  return json_build_object('ok', true, 'id', v_id, 'remaining', v_remaining);
end;
$$;
