-- ============================================================
-- 半日展示班 · 第二梯次：建立場次 + 改期 2026-06-17 → 2026-06-21
--
-- 背景：class_registrations.session_date 以 FK 參照 class_sessions(session_date)。
-- 第二梯場次先前從未建立，導致任何報名都觸發 FK 違反（23503）→ 前端「連線異常」。
--
-- 本段同時建立 6/21（新對外日期）與 6/17（相容舊 CDN/瀏覽器快取仍指向的日期），
-- 兩者皆視為第二梯、限額 16、開放報名 → 不論訪客拿到新舊前端都能成功報名，零空窗。
-- 待 CDN 快取過期後，再執行最底部「清理」段落把 6/17 併入 6/21。
-- 在 Supabase SQL Editor 整段貼上執行。
-- ============================================================

begin;

-- 第二梯主場次（對外日期 6/21）
insert into public.class_sessions (session_date, title, capacity, is_open)
values ('2026-06-21', 'Claude 應用落地展示班（宜蘭蘇澳 · 第二梯）', 16, true)
on conflict (session_date) do update
  set title = excluded.title, capacity = excluded.capacity, is_open = excluded.is_open;

-- 相容場次（舊前端快取仍送 6/17，補建避免 FK 崩潰；視為同一梯）
insert into public.class_sessions (session_date, title, capacity, is_open)
values ('2026-06-17', 'Claude 應用落地展示班（宜蘭蘇澳 · 第二梯 · 舊連結相容）', 16, true)
on conflict (session_date) do update
  set capacity = excluded.capacity, is_open = excluded.is_open;

commit;

-- 驗證：應有 06-07 / 06-17 / 06-21 三列
select session_date, title, capacity, is_open
  from public.class_sessions
 order by session_date;


-- ============================================================
-- 【稍後清理】等 CDN 快取過期（確認沒人再送 6/17）後，單獨執行這段：
-- 把 6/17 的報名併入 6/21，並刪除相容場次。
-- ============================================================
-- begin;
--   update public.class_registrations set session_date = '2026-06-21' where session_date = '2026-06-17';
--   delete from public.class_sessions where session_date = '2026-06-17';
-- commit;
-- select session_date, title, capacity, is_open from public.class_sessions order by session_date;
