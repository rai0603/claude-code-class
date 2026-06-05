-- ============================================================
-- 一日實作上線班：報名 + 優惠碼折扣 + 後台 + 折扣碼管理
-- 專案：DiDiPo Pro (ref nxjtndpfccmzbrvfxczw)
-- 沿用 class_admin（後台密碼）與 notify_config（Email 通知）。
-- 在 Supabase SQL Editor 貼上整段執行一次即可。可重複執行。
-- ============================================================

-- 場次（首梯 6/14，8 人，原價 6800）
create table if not exists public.oneday_sessions (
  session_date date primary key,
  title    text,
  capacity int  not null default 8,
  price    int  not null default 6800,
  is_open  boolean not null default true
);
insert into public.oneday_sessions(session_date,title,capacity,price,is_open)
values ('2026-06-14','Claude Code 一日實作上線班（首梯）',8,6800,true)
on conflict (session_date) do nothing;
alter table public.oneday_sessions enable row level security;

-- 折扣碼
create table if not exists public.discount_codes (
  code       text primary key,
  label      text,
  price      int  not null default 4080,   -- 套用後價格
  is_active  boolean not null default true,
  max_uses   int,                          -- null = 不限次數
  used_count int  not null default 0,
  expires_at timestamptz,
  created_at timestamptz not null default now()
);
alter table public.discount_codes enable row level security;

-- 報名
create table if not exists public.oneday_registrations (
  id             uuid primary key default gen_random_uuid(),
  created_at     timestamptz not null default now(),
  session_date   date not null default '2026-06-14' references public.oneday_sessions(session_date),
  name           text not null,
  phone          text not null,
  email          text not null,
  transfer_last5 text,
  discount_code  text,
  price          int  not null,
  status         text not null default 'pending' check (status in ('pending','paid','checked_in','cancelled')),
  note           text
);
create unique index if not exists oneday_uniq_email
  on public.oneday_registrations(session_date, lower(email)) where status <> 'cancelled';
alter table public.oneday_registrations enable row level security;

-- ------------------------------------------------------------
-- 查名額 + 原價
-- ------------------------------------------------------------
create or replace function public.get_oneday_seats(p_session date default '2026-06-14')
returns json language plpgsql security definer set search_path=public as $$
declare v_cap int; v_open boolean; v_price int; v_taken int;
begin
  select capacity,is_open,price into v_cap,v_open,v_price from oneday_sessions where session_date=p_session;
  if v_cap is null then v_cap:=8; v_open:=true; v_price:=6800; end if;
  select count(*) into v_taken from oneday_registrations where session_date=p_session and status<>'cancelled';
  return json_build_object('capacity',v_cap,'taken',v_taken,'remaining',greatest(v_cap-v_taken,0),
                           'is_open',coalesce(v_open,true),'price',v_price);
end; $$;

-- ------------------------------------------------------------
-- 驗證優惠碼（公開，只回價格/標籤，不外洩名單）
-- ------------------------------------------------------------
create or replace function public.check_discount(p_code text)
returns json language plpgsql security definer set search_path=public as $$
declare r record;
begin
  if coalesce(trim(p_code),'')='' then return json_build_object('valid',false); end if;
  select * into r from discount_codes where upper(code)=upper(trim(p_code));
  if not found then return json_build_object('valid',false,'message','優惠碼無效'); end if;
  if not r.is_active then return json_build_object('valid',false,'message','優惠碼已停用'); end if;
  if r.expires_at is not null and r.expires_at < now() then return json_build_object('valid',false,'message','優惠碼已過期'); end if;
  if r.max_uses is not null and r.used_count >= r.max_uses then return json_build_object('valid',false,'message','優惠碼已用完'); end if;
  return json_build_object('valid',true,'price',r.price,'label',coalesce(r.label,''));
end; $$;

-- ------------------------------------------------------------
-- 報名（容量檢查 + 優惠碼計價，全部 server 端，防偽造）
-- ------------------------------------------------------------
create or replace function public.register_oneday(
  p_name text, p_phone text, p_email text, p_last5 text default null,
  p_code text default null, p_session date default '2026-06-14'
) returns json language plpgsql security definer set search_path=public as $$
declare v_cap int; v_open boolean; v_base int; v_taken int; v_id uuid;
        v_price int; v_code text; r record; v_remaining int;
        v_key text; v_from text; v_to text;
begin
  if coalesce(trim(p_name),'')='' or coalesce(trim(p_phone),'')='' or coalesce(trim(p_email),'')='' then
    return json_build_object('ok',false,'reason','invalid','message','請完整填寫姓名 / 電話 / Email'); end if;
  if position('@' in p_email)=0 then return json_build_object('ok',false,'reason','invalid','message','Email 格式不正確'); end if;

  select capacity,is_open,price into v_cap,v_open,v_base from oneday_sessions where session_date=p_session for update;
  if v_cap is null then v_cap:=8; v_open:=true; v_base:=6800; end if;
  if not coalesce(v_open,true) then return json_build_object('ok',false,'reason','closed','message','本梯次報名已關閉'); end if;

  select count(*) into v_taken from oneday_registrations where session_date=p_session and status<>'cancelled';
  if v_taken>=v_cap then return json_build_object('ok',false,'reason','full','message','本梯次名額已滿','remaining',0); end if;

  if exists(select 1 from oneday_registrations where session_date=p_session and lower(email)=lower(p_email) and status<>'cancelled') then
    return json_build_object('ok',false,'reason','duplicate','message','這個 Email 已報名過本梯次'); end if;

  -- 計價
  v_price:=v_base; v_code:=null;
  if coalesce(trim(p_code),'')<>'' then
    select * into r from discount_codes where upper(code)=upper(trim(p_code)) for update;
    if found and r.is_active
       and (r.expires_at is null or r.expires_at>=now())
       and (r.max_uses is null or r.used_count<r.max_uses) then
      v_price:=r.price; v_code:=r.code;
      update discount_codes set used_count=used_count+1 where code=r.code;
    end if;
  end if;

  insert into oneday_registrations(session_date,name,phone,email,transfer_last5,discount_code,price)
  values (p_session,trim(p_name),trim(p_phone),trim(p_email),nullif(trim(p_last5),''),v_code,v_price)
  returning id into v_id;
  v_remaining:=greatest(v_cap-(v_taken+1),0);

  -- Email 通知（沿用 notify_config，非阻斷）
  begin
    select value into v_key from notify_config where key='resend_api_key';
    if v_key is not null and v_key<>'' then
      select value into v_from from notify_config where key='notify_from';
      select value into v_to   from notify_config where key='notify_to';
      perform net.http_post(
        url:='https://api.resend.com/emails',
        headers:=jsonb_build_object('Authorization','Bearer '||v_key,'Content-Type','application/json'),
        body:=jsonb_build_object('from',coalesce(v_from,'onboarding@resend.dev'),
          'to',jsonb_build_array(coalesce(v_to,'rai0603@gmail.com')),
          'subject','🎓 一日班新報名：'||trim(p_name)||'（NT$'||v_price||'，剩 '||v_remaining||' 位）',
          'html','<h2>一日實作班新報名</h2><table cellpadding="6" style="font-size:15px">'||
            '<tr><td><b>姓名</b></td><td>'||trim(p_name)||'</td></tr>'||
            '<tr><td><b>電話</b></td><td>'||trim(p_phone)||'</td></tr>'||
            '<tr><td><b>Email</b></td><td>'||trim(p_email)||'</td></tr>'||
            '<tr><td><b>優惠碼</b></td><td>'||coalesce(v_code,'（無）')||'</td></tr>'||
            '<tr><td><b>應收金額</b></td><td>NT$'||v_price||'</td></tr>'||
            '<tr><td><b>末五碼</b></td><td>'||coalesce(nullif(trim(p_last5),''),'（未填）')||'</td></tr>'||
            '<tr><td><b>剩餘名額</b></td><td>'||v_remaining||' / '||v_cap||'</td></tr></table>'));
    end if;
  exception when others then null; end;

  return json_build_object('ok',true,'id',v_id,'price',v_price,'base_price',v_base,'discounted',(v_price<v_base),'remaining',v_remaining);
end; $$;

-- ------------------------------------------------------------
-- 後台：報名名單 / 改狀態（沿用 class_admin 密碼）
-- ------------------------------------------------------------
create or replace function public.admin_list_oneday(p_token text, p_session date default '2026-06-14')
returns json language plpgsql security definer set search_path=public as $$
begin
  if not exists(select 1 from class_admin where id=1 and token is not null and token=p_token) then
    return json_build_object('ok',false,'message','管理密碼錯誤'); end if;
  return json_build_object('ok',true,
    'capacity',coalesce((select capacity from oneday_sessions where session_date=p_session),8),
    'price',coalesce((select price from oneday_sessions where session_date=p_session),6800),
    'rows',coalesce((select json_agg(row_to_json(t)) from (
       select id,created_at,name,phone,email,transfer_last5,discount_code,price,status
       from oneday_registrations where session_date=p_session order by created_at desc) t),'[]'::json));
end; $$;

create or replace function public.admin_set_oneday_status(p_token text,p_id uuid,p_status text)
returns json language plpgsql security definer set search_path=public as $$
begin
  if not exists(select 1 from class_admin where id=1 and token is not null and token=p_token) then
    return json_build_object('ok',false,'message','管理密碼錯誤'); end if;
  if p_status not in ('pending','paid','checked_in','cancelled') then
    return json_build_object('ok',false,'message','狀態不合法'); end if;
  update oneday_registrations set status=p_status where id=p_id;
  if not found then return json_build_object('ok',false,'message','找不到該筆'); end if;
  return json_build_object('ok',true);
end; $$;

-- ------------------------------------------------------------
-- 後台：折扣碼 建立 / 列表
-- ------------------------------------------------------------
create or replace function public.admin_create_discount(
  p_token text, p_code text, p_label text default null, p_price int default 4080,
  p_max_uses int default null, p_expires timestamptz default null
) returns json language plpgsql security definer set search_path=public as $$
begin
  if not exists(select 1 from class_admin where id=1 and token is not null and token=p_token) then
    return json_build_object('ok',false,'message','管理密碼錯誤'); end if;
  if coalesce(trim(p_code),'')='' then return json_build_object('ok',false,'message','請提供折扣碼'); end if;
  insert into discount_codes(code,label,price,max_uses,expires_at)
  values (upper(trim(p_code)),p_label,coalesce(p_price,4080),p_max_uses,p_expires)
  on conflict (code) do update set
    label=excluded.label, price=excluded.price, max_uses=excluded.max_uses,
    expires_at=excluded.expires_at, is_active=true;
  return json_build_object('ok',true,'code',upper(trim(p_code)));
end; $$;

create or replace function public.admin_list_discounts(p_token text)
returns json language plpgsql security definer set search_path=public as $$
begin
  if not exists(select 1 from class_admin where id=1 and token is not null and token=p_token) then
    return json_build_object('ok',false,'message','管理密碼錯誤'); end if;
  return json_build_object('ok',true,'rows',coalesce((select json_agg(row_to_json(t)) from (
    select code,label,price,is_active,max_uses,used_count,expires_at,created_at
    from discount_codes order by created_at desc) t),'[]'::json));
end; $$;

-- ------------------------------------------------------------
-- 權限
-- ------------------------------------------------------------
revoke all on function get_oneday_seats(date) from public;
revoke all on function check_discount(text) from public;
revoke all on function register_oneday(text,text,text,text,text,date) from public;
revoke all on function admin_list_oneday(text,date) from public;
revoke all on function admin_set_oneday_status(text,uuid,text) from public;
revoke all on function admin_create_discount(text,text,text,int,int,timestamptz) from public;
revoke all on function admin_list_discounts(text) from public;
grant execute on function get_oneday_seats(date) to anon,authenticated;
grant execute on function check_discount(text) to anon,authenticated;
grant execute on function register_oneday(text,text,text,text,text,date) to anon,authenticated;
grant execute on function admin_list_oneday(text,date) to anon,authenticated;
grant execute on function admin_set_oneday_status(text,uuid,text) to anon,authenticated;
grant execute on function admin_create_discount(text,text,text,int,int,timestamptz) to anon,authenticated;
grant execute on function admin_list_discounts(text) to anon,authenticated;
