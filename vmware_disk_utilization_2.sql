WITH time_param AS (
  SELECT
    CASE
      WHEN '${time_range}' = '30 days ago'
        THEN UNIX_TIMESTAMP(NOW() - INTERVAL 30 DAY)
      ELSE UNIX_TIMESTAMP(CONCAT(${year}, '-', LPAD(${month}, 2, '0'), '-01 00:00:00'))
    END AS start_ts,
    CASE
      WHEN '${time_range}' = '30 days ago'
        THEN UNIX_TIMESTAMP(NOW())
      ELSE UNIX_TIMESTAMP(DATE_ADD(CONCAT(${year}, '-', LPAD(${month}, 2, '0'), '-01 00:00:00'), INTERVAL 1 MONTH))
    END AS end_ts,
    CASE
      WHEN '${time_range}' = '30 days ago' THEN 1 ELSE 0
    END AS is_rolling_30
),

threshold_param AS (
  SELECT
    CASE
      WHEN '${threshold}' = '<=60.00' THEN 0
      WHEN '${threshold}' = '>60.00 AND <=70.00' THEN 60
      WHEN '${threshold}' = '>70.00 AND <=80.00' THEN 70
      WHEN '${threshold}' = '>80.00 AND <=90.00' THEN 80
      WHEN '${threshold}' = '>90.00' THEN 90
    END AS lower_bound,
    CASE
      WHEN '${threshold}' = '<=60.00' THEN 60
      WHEN '${threshold}' = '>60.00 AND <=70.00' THEN 70
      WHEN '${threshold}' = '>70.00 AND <=80.00' THEN 80
      WHEN '${threshold}' = '>80.00 AND <=90.00' THEN 90
      WHEN '${threshold}' = '>90.00' THEN 100
    END AS upper_bound
),

grup AS (
  SELECT groupid
  FROM hstgrp
  WHERE name LIKE '%01_Critical%'
    AND name NOT LIKE '%SAP%'
),

list_server AS (
  SELECT DISTINCT h.hostid, h.name AS vm_name
  FROM hosts h
  JOIN hosts_groups hg ON hg.hostid = h.hostid
  JOIN grup g ON g.groupid = hg.groupid
  WHERE h.name NOT LIKE 'tbn-com-hp%'
    AND h.name NOT LIKE 'tbn-com-mdm%'
    AND h.name NOT LIKE 'VC02 - tbn-com-lnv%'
    AND h.name NOT LIKE 'VC02 - tbn-mgt-lnv%'
),

items_used AS (
  SELECT
    i.itemid,
    i.hostid,
    SUBSTRING_INDEX(SUBSTRING_INDEX(i.key_, ',used', 1), '},', -1) AS partition_name
  FROM items i
  WHERE (i.name LIKE '%VMware: Used disk space on %'
         OR i.key_ = 'vmware.vm.vfs.fs.size[{$VMWARE.URL},{$VMWARE.VM.UUID},%,used]')
),

items_free AS (
  SELECT
    i.itemid,
    i.hostid,
    SUBSTRING_INDEX(SUBSTRING_INDEX(i.key_, ',free', 1), '},', -1) AS partition_name
  FROM items i
  WHERE (i.name LIKE '%VMware: Free disk space on %'
         OR i.key_ = 'vmware.vm.vfs.fs.size[{$VMWARE.URL},{$VMWARE.VM.UUID},%,free]')
),

item_pair AS (
  SELECT
    u.hostid,
    u.partition_name,
    MIN(u.itemid) AS used_itemid,
    MIN(f.itemid) AS free_itemid
  FROM items_used u
  JOIN items_free f
    ON f.hostid = u.hostid
   AND f.partition_name = u.partition_name
  GROUP BY u.hostid, u.partition_name
),

detail AS (
  SELECT
    ls.hostid,
    ls.vm_name,
    tu.clock AS clock,
    FROM_UNIXTIME(tu.clock, '%Y-%m-%d') AS day,
    ip.partition_name,
    tu.value_avg / (1024*1024*1024) AS used_gib,
    tf.value_avg / (1024*1024*1024) AS free_gib,
    (tu.value_avg / NULLIF((tu.value_avg + tf.value_avg),0)) * 100 AS usage_pct
  FROM time_param p
  CROSS JOIN item_pair ip
  JOIN list_server ls ON ls.hostid = ip.hostid
  JOIN trends_uint tu
    ON tu.itemid = ip.used_itemid
   AND tu.clock >= p.start_ts AND tu.clock < p.end_ts
  JOIN trends_uint tf
    ON tf.itemid = ip.free_itemid
   AND tf.clock  = tu.clock
),

daily AS (
  SELECT
    hostid,
    vm_name,
    partition_name,
    day,
    AVG(used_gib)  AS used_gib,
    AVG(free_gib)  AS free_gib,
    AVG(usage_pct) AS usage_pct
  FROM detail
  GROUP BY hostid, vm_name, partition_name, day
),

monthly AS (
  SELECT
    d.hostid,
    d.vm_name,
    d.partition_name,
    CASE
      WHEN p.is_rolling_30 = 1 THEN 'Last 30 Days'
      ELSE DATE_FORMAT(STR_TO_DATE(d.day, '%Y-%m-%d'), '%Y-%m')
    END AS bulan,
    AVG(d.used_gib)  AS avg_used_gib,
    AVG(d.free_gib)  AS avg_free_gib,
    AVG(d.usage_pct) AS avg_usage_pct
  FROM daily d
  CROSS JOIN time_param p
  GROUP BY
    d.hostid, d.vm_name, d.partition_name,
    CASE
      WHEN p.is_rolling_30 = 1 THEN 'Last 30 Days'
      ELSE DATE_FORMAT(STR_TO_DATE(d.day, '%Y-%m-%d'), '%Y-%m')
    END
),

need_itemids AS (
  SELECT used_itemid AS itemid FROM item_pair
  UNION
  SELECT free_itemid AS itemid FROM item_pair
),

last_clock AS (
  SELECT h.itemid, MAX(h.clock) AS max_clock
  FROM history_uint h
  JOIN need_itemids n ON n.itemid = h.itemid
  WHERE h.clock >= UNIX_TIMESTAMP(NOW() - INTERVAL 6 HOUR)
  GROUP BY h.itemid
),

las_val AS (
  SELECT
    h.itemid,
    h.clock,
    MAX(h.value) AS value
  FROM history_uint h
  JOIN last_clock lc
    ON lc.itemid = h.itemid
   AND lc.max_clock = h.clock
  GROUP BY h.itemid, h.clock
),

current_disk AS (
  SELECT
    ls.hostid,
    ls.vm_name,
    ip.partition_name,
    vu.clock AS clock_used,
    vf.clock AS clock_free,
    CASE
      WHEN vu.value IS NULL OR vf.value IS NULL THEN NULL
      ELSE (vu.value / NULLIF((vu.value + vf.value),0)) * 100
    END AS current_usage_pct
  FROM list_server ls
  JOIN item_pair ip
    ON ip.hostid = ls.hostid
  LEFT JOIN las_val vu
    ON vu.itemid = ip.used_itemid
  LEFT JOIN las_val vf
    ON vf.itemid = ip.free_itemid
),

ordered_daily AS (
  SELECT
    hostid,
    vm_name,
    partition_name,
    usage_pct,
    ROW_NUMBER() OVER (PARTITION BY hostid, partition_name ORDER BY usage_pct) AS rn,
    COUNT(*) OVER (PARTITION BY hostid, partition_name) AS cnt
  FROM daily
),

p95 AS (
  SELECT
    hostid,
    vm_name,
    partition_name,
    MAX(CASE WHEN rn = CEIL(cnt * 0.95) THEN usage_pct END) AS p95_usage_pct
  FROM ordered_daily
  GROUP BY hostid, vm_name, partition_name
),

power_state AS (
  SELECT
    i.hostid,
    hu.value AS power_state
  FROM items i
  JOIN (
    SELECT
      itemid,
      value,
      ROW_NUMBER() OVER (PARTITION BY itemid ORDER BY clock DESC) AS rn
    FROM history_uint
    WHERE clock >= UNIX_TIMESTAMP(NOW() - INTERVAL 1 HOUR)
      AND clock <  UNIX_TIMESTAMP(NOW())
  ) hu
    ON hu.itemid = i.itemid AND hu.rn = 1
  WHERE i.key_ = 'vmware.vm.powerstate[{$VMWARE.URL},{$VMWARE.VM.UUID}]'
)

SELECT
  m.vm_name AS vm,
  m.partition_name,
  CASE
    WHEN ps.power_state = 0 THEN 'Powered Off'
    WHEN ps.power_state = 1 THEN 'Powered On'
    WHEN ps.power_state = 2 THEN 'Suspended'
    ELSE 'Unknown'
  END AS PowerState,
  cd.current_usage_pct AS current_disk_pct,
  m.avg_usage_pct AS average_disk_pct,
  p.p95_usage_pct AS percentile_95th_pct
FROM monthly m
JOIN threshold_param th
  ON m.avg_usage_pct > th.lower_bound
 AND m.avg_usage_pct <= th.upper_bound
LEFT JOIN current_disk cd
  ON cd.hostid = m.hostid
 AND cd.partition_name = m.partition_name
LEFT JOIN p95 p
  ON p.hostid = m.hostid
 AND p.partition_name = m.partition_name
LEFT JOIN power_state ps
  ON ps.hostid = m.hostid
ORDER BY
  m.avg_usage_pct DESC,
  m.vm_name,
  m.partition_name
