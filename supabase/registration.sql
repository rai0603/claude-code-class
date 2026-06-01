-- ============================================================
-- Claude Code 半日展示班 報名系統
-- 專案：DiDiPo Pro (ref nxjtndpfccmzbrvfxczw)
-- 在 Supabase SQL Editor 貼上整段執行一次即可。可重複執行（idempotent）。
-- ============================================================

-- 場次設定（容量可日後直接改這張表）
create table if not exists public.class_sessions (
  session_date date primary key,
  title        text,
  capacity     int  not null default 20,
  is_open      boolean not null default true
);

insert into public.class_sessions (session_date, title, capacity, is_open)
values ('2026-06-07', 'Claude 應用落地展示班（宜蘭蘇澳專場）', 20, true)
on conflict (session_date) do nothing;

-- 報名資料
create table if not exists public.class_registrations (
  id             uuid primary key default gen_random_uuid(),
  created_at     timestamptz not null default now(),
  session_date   date not null default '2026-06-07' references public.class_sessions(session_date),
  name           text not null,
  phone          text not null,
  email          text not null,
  transfer_last5 text,
  status         text not null default 'pending'
                 check (status in ('pending','paid','checked_in','cancelled')),
  note           text
);

-- 同場次同 email 不可重複（已取消者不算）
create unique index if not exists class_reg_unique_email_per_session
  on public.class_registrations (session_date, lower(email))
  where status <> 'cancelled';

-- 鎖死 RLS：不開任何 anon policy，個資只能由下方 SECURITY DEFINER 函式進出
alter table public.class_registrations enable row level security;
alter table public.class_sessions      enable row level security;

-- ------------------------------------------------------------
-- 查剩餘名額（只回聚合數字，不外洩任何個資）
-- ------------------------------------------------------------
create or replace function public.get_class_seats(p_session date default '2026-06-07')
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cap int; v_open boolean; v_taken int;
begin
  select capacity, is_open into v_cap, v_open
  from public.class_sessions where session_date = p_session;
  if v_cap is null then v_cap := 20; v_open := true; end if;

  select count(*) into v_taken
  from public.class_registrations
  where session_date = p_session and status <> 'cancelled';

  return json_build_object(
    'capacity',  v_cap,
    'taken',     v_taken,
    'remaining', greatest(v_cap - v_taken, 0),
    'is_open',   coalesce(v_open, true)
  );
end;
$$;

-- ------------------------------------------------------------
-- 報名（原子檢查容量 + 防重複 + 寫入）
-- ------------------------------------------------------------
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
  v_cap int; v_open boolean; v_taken int; v_id uuid;
begin
  if coalesce(trim(p_name),'')='' or coalesce(trim(p_phone),'')='' or coalesce(trim(p_email),'')='' then
    return json_build_object('ok', false, 'reason','invalid', 'message','請完整填寫姓名 / 電話 / Email');
  end if;
  if position('@' in p_email) = 0 then
    return json_build_object('ok', false, 'reason','invalid', 'message','Email 格式不正確');
  end if;

  -- 鎖定該場次列，序列化併發報名以免超賣
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

  return json_build_object('ok', true, 'id', v_id, 'remaining', greatest(v_cap - (v_taken+1), 0));
end;
$$;

-- ------------------------------------------------------------
-- 權限：前端 anon 只能呼叫這兩個函式，不能直接讀寫表
-- ------------------------------------------------------------
revoke all on function public.get_class_seats(date) from public;
revoke all on function public.register_for_class(text,text,text,text,date) from public;
grant execute on function public.get_class_seats(date) to anon, authenticated;
grant execute on function public.register_for_class(text,text,text,text,date) to anon, authenticated;
