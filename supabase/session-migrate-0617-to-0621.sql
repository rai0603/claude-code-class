-- ============================================================
-- 場次設定 / 改期（半日班 + 一日班）一次執行
-- 在 Supabase SQL Editor 整段貼上執行。所有語句皆冪等（可重複跑）。
--
-- 背景：class_registrations / oneday_registrations 以 FK 參照各自的
-- *_sessions(session_date)。場次若未建立，報名寫入會觸發 FK 違反(23503)
-- → 前端「連線異常」。本段建立所有需要的場次。
-- ============================================================

-- ===========================================================
-- A. 半日展示班 · 第二梯：建立場次 + 改期 6/17 → 6/21
--    同時建立 6/21（新對外日期）與 6/17（相容舊 CDN/瀏覽器快取），
--    兩者皆視為第二梯、限額 16、開放報名 → 新舊前端皆可報名，零空窗。
-- ===========================================================
begin;

insert into public.class_sessions (session_date, title, capacity, is_open)
values ('2026-06-21', 'Claude 應用落地展示班（宜蘭蘇澳 · 第二梯）', 16, true)
on conflict (session_date) do update
  set title = excluded.title, capacity = excluded.capacity, is_open = excluded.is_open;

insert into public.class_sessions (session_date, title, capacity, is_open)
values ('2026-06-17', 'Claude 應用落地展示班（宜蘭蘇澳 · 第二梯 · 舊連結相容）', 16, true)
on conflict (session_date) do update
  set capacity = excluded.capacity, is_open = excluded.is_open;

commit;

-- ===========================================================
-- B. 一日實作上線班 · 第二梯：建立場次 6/28（限額 8、原價 6800）
-- ===========================================================
begin;

insert into public.oneday_sessions (session_date, title, capacity, price, is_open)
values ('2026-06-28', 'Claude Code 一日實作上線班（宜蘭蘇澳 · 第二梯）', 8, 6800, true)
on conflict (session_date) do update
  set title = excluded.title, capacity = excluded.capacity, price = excluded.price, is_open = excluded.is_open;

commit;

-- ===========================================================
-- 驗證：
-- 半日應有 06-07 / 06-17 / 06-21；一日應有 06-14 / 06-28
-- ===========================================================
select '半日' as 班別, session_date, title, capacity, is_open
  from public.class_sessions
union all
select '一日' as 班別, session_date, title, capacity, is_open
  from public.oneday_sessions
 order by 1, 2;


-- ============================================================
-- 【稍後清理 · 半日】等 CDN 快取過期（確認沒人再送 6/17）後單獨執行：
-- 把 6/17 報名併入 6/21 並刪除相容場次。
-- ============================================================
-- begin;
--   update public.class_registrations set session_date = '2026-06-21' where session_date = '2026-06-17';
--   delete from public.class_sessions where session_date = '2026-06-17';
-- commit;
