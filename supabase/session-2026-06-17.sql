-- ============================================================
-- 半日展示班 · 第二梯次場次設定（2026-06-17）
-- 專案：DiDiPo Pro (ref nxjtndpfccmzbrvfxczw)
-- 在 Supabase SQL Editor 貼上整段執行一次即可。可重複執行（idempotent）。
--   · 新增第二梯 6/17（週三）09:00–12:00，限額 16 人，開放報名
--   · 關閉首梯 6/07（已圓滿結束），報名資料保留、後台仍可切換查閱
-- 前後台以 session_date 區分梯次；報名/座位/後台 RPC 皆已支援 p_session。
-- ============================================================

-- 第二梯：存在則更新容量/開放狀態，不存在則新增
insert into public.class_sessions (session_date, title, capacity, is_open)
values ('2026-06-17', 'Claude 應用落地展示班（宜蘭蘇澳 · 第二梯）', 16, true)
on conflict (session_date) do update
  set title    = excluded.title,
      capacity = excluded.capacity,
      is_open  = excluded.is_open;

-- 首梯：關閉報名（資料保留，後台可切回查閱）
update public.class_sessions
   set is_open = false
 where session_date = '2026-06-07';

-- 驗證
select session_date, title, capacity, is_open
from public.class_sessions
order by session_date;
