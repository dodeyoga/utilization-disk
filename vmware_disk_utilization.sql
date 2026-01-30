WITH
/* =============================================================================
   CTE: time_param
   Tujuan:
     - Menentukan rentang waktu analisis dalam UNIX timestamp.
     - Mendukung 2 mode: rolling 30 hari atau 1 bulan tertentu (year, month).
   Input (parameter):
     - ${time_range}, ${year}, ${month}
   Output (kolom kunci):
     - start_ts  : batas bawah (inclusive)
     - end_ts    : batas atas (exclusive)
     - is_rolling_30 : flag mode (1=rolling 30 hari, 0=bulanan)
   Assumptions & Caveats:
     - end_ts bersifat exclusive (clock < end_ts).
     - Mode bulanan selalu dimulai dari tanggal 01 00:00:00.
   ========================================================================== */
time_param AS (
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

/* =============================================================================
   CTE: threshold_param
   Tujuan:
     - Mengubah pilihan threshold (string) menjadi batas numerik untuk filter.
   Input (parameter):
     - ${threshold}
   Output (kolom kunci):
     - lower_bound : batas bawah (exclusive pada query utama)
     - upper_bound : batas atas (inclusive pada query utama)
   Assumptions & Caveats:
     - Filter di SELECT akhir: (avg_usage_pct > lower) dan (<= upper).
     - Jika ${threshold} tidak match salah satu string, lower/upper bisa NULL → hasil kosong.
   Catatan:
     - Dipakai untuk memfilter m.avg_usage_pct agar hanya keluar range tertentu.
   ========================================================================== */
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

/* =============================================================================
   CTE: grup
   Tujuan:
     - Menentukan scope group host/VM berdasarkan nama grup.
   Input (tabel):
     - hstgrp
   Output (kolom kunci):
     - groupid
   Kriteria:
     - nama grup mengandung 'TBN' dan tidak mengandung 'SAP'
   Assumptions & Caveats:
     - Pemilihan host sangat bergantung pada konsistensi penamaan group (LIKE '%TBN%').
   ========================================================================== */
grup AS (
  SELECT groupid
  FROM hstgrp
  WHERE name LIKE '%TBN%'
    AND name NOT LIKE '%SAP%'
),

/* =============================================================================
   CTE: list_server
   Tujuan:
     - Menghasilkan daftar VM target (hostid + vm_name) berdasarkan group terpilih.
     - Mengecualikan VM tertentu berdasarkan pola nama.
   Input (tabel/cte):
     - hosts, hosts_groups, grup
   Output (kolom kunci):
     - hostid
     - vm_name
   Assumptions & Caveats:
     - Jika ada host masuk beberapa grup, DISTINCT mencegah duplikasi.
     - Filter NOT LIKE bersifat “hard exclude”; perubahan naming bisa membuat host lolos/terbuang.
   ========================================================================== */
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

/* =============================================================================
   CTE: items_used
   Tujuan:
     - Mengambil item disk "used" per host + partition/filesystem.
     - Mengekstrak partition_name dari items.key_.
   Input (tabel):
     - items
   Output (kolom kunci):
     - itemid
     - hostid
     - partition_name
   Assumptions & Caveats:
     - Parsing partition_name bergantung format key_ yang stabil.
     - Jika ada variasi format key_ berbeda, partition_name bisa salah/blank → gagal pairing.
   ========================================================================== */
items_used AS (
  SELECT
    i.itemid,
    i.hostid,
    SUBSTRING_INDEX(SUBSTRING_INDEX(i.key_, ',used', 1), '},', -1) AS partition_name
  FROM items i
  WHERE (i.name LIKE '%VMware: Used disk space on %'
         OR i.key_ = 'vmware.vm.vfs.fs.size[{$VMWARE.URL},{$VMWARE.VM.UUID},%,used]')
),

/* =============================================================================
   CTE: items_free
   Tujuan:
     - Mengambil item disk "free" per host + partition/filesystem.
     - Mengekstrak partition_name dari items.key_.
   Input (tabel):
     - items
   Output (kolom kunci):
     - itemid
     - hostid
     - partition_name
   Assumptions & Caveats:
     - Harus menghasilkan partition_name yang identik dengan items_used untuk host yang sama.
   ========================================================================== */
items_free AS (
  SELECT
    i.itemid,
    i.hostid,
    SUBSTRING_INDEX(SUBSTRING_INDEX(i.key_, ',free', 1), '},', -1) AS partition_name
  FROM items i
  WHERE (i.name LIKE '%VMware: Free disk space on %'
         OR i.key_ = 'vmware.vm.vfs.fs.size[{$VMWARE.URL},{$VMWARE.VM.UUID},%,free]')
),

/* =============================================================================
   CTE: item_pair
   Tujuan:
     - Memasangkan item "used" dan "free" untuk host + partition yang sama.
     - Mengambil MIN(itemid) untuk menghindari duplikasi item yang sejenis.
   Input (cte):
     - items_used, items_free
   Output (kolom kunci):
     - hostid
     - partition_name
     - used_itemid
     - free_itemid
   Assumptions & Caveats:
     - Mengambil MIN(itemid) mengasumsikan item duplikat setara; jika tidak, bisa salah pilih item.
     - Jika salah satu sisi (used/free) tidak ada → partition tidak akan muncul sama sekali.
   ========================================================================== */
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

/* =============================================================================
   CTE: detail
   Tujuan:
     - Mengambil data trend (trends_uint) used & free dalam time window.
     - Menghitung used/free (GiB) dan usage_pct pada setiap clock.
   Input (cte/tabel):
     - time_param, item_pair, list_server, trends_uint (tu, tf)
   Output (kolom kunci):
     - hostid, vm_name, partition_name
     - clock, day
     - used_gib, free_gib
     - usage_pct
   Assumptions & Caveats:
     - Mengandalkan tf.clock = tu.clock; jika clock trend tidak sinkron, baris akan hilang.
     - trends_uint berisi nilai AVG bucket; bukan nilai mentah (history).
     - usage_pct bisa NULL bila (used+free)=0 (dibuat aman via NULLIF).
   Catatan:
     - tf.clock = tu.clock: mensinkronkan used & free pada bucket waktu yang sama.
   ========================================================================== */
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

/* =============================================================================
   CTE: daily
   Tujuan:
     - Agregasi data detail menjadi rata-rata harian per VM + partition.
   Input (cte):
     - detail
   Output (kolom kunci):
     - hostid, vm_name, partition_name, day
     - used_gib, free_gib, usage_pct (rata-rata harian)
   Assumptions & Caveats:
     - Rata-rata harian dihitung dari bucket trend yang tersedia (bisa kurang jika data missing).
   ========================================================================== */
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

/* =============================================================================
   CTE: monthly
   Tujuan:
     - Agregasi rata-rata periode (bulanan atau rolling 30 hari) dari data daily.
     - Membentuk label bulan: 'Last 30 Days' atau 'YYYY-MM'.
   Input (cte):
     - daily, time_param
   Output (kolom kunci):
     - hostid, vm_name, partition_name, bulan
     - avg_used_gib, avg_free_gib, avg_usage_pct
   Assumptions & Caveats:
     - Untuk mode rolling, label bulan diset 'Last 30 Days' (bukan YYYY-MM).
     - Untuk mode bulanan, grouping berbasis day → month; jika day format berubah, bisa error.
   ========================================================================== */
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

/* =============================================================================
   CTE: need_itemids
   Tujuan:
     - Membuat daftar itemid yang diperlukan untuk mengambil nilai "current" dari history_uint.
   Input (cte):
     - item_pair
   Output (kolom kunci):
     - itemid (gabungan used & free)
   Assumptions & Caveats:
     - UNION menghilangkan duplikasi itemid jika ada.
   ========================================================================== */
need_itemids AS (
  SELECT used_itemid AS itemid FROM item_pair
  UNION
  SELECT free_itemid AS itemid FROM item_pair
),

/* =============================================================================
   CTE: last_clock
   Tujuan:
     - Menentukan clock terbaru per itemid (dalam 6 jam terakhir) dari history_uint.
   Input (cte/tabel):
     - need_itemids, history_uint
   Output (kolom kunci):
     - itemid
     - max_clock
   Assumptions & Caveats:
     - Jika tidak ada data dalam 6 jam terakhir → item tidak muncul → current_disk jadi NULL.
     - Window 6 jam adalah kompromi: lebih sempit = lebih “fresh” tapi lebih sering NULL.
   ========================================================================== */
last_clock AS (
  SELECT h.itemid, MAX(h.clock) AS max_clock
  FROM history_uint h
  JOIN need_itemids n ON n.itemid = h.itemid
  WHERE h.clock >= UNIX_TIMESTAMP(NOW() - INTERVAL 6 HOUR)
  GROUP BY h.itemid
),

/* =============================================================================
   CTE: las_val
   Tujuan:
     - Mengambil nilai (value) pada max_clock untuk setiap itemid.
   Input (cte/tabel):
     - last_clock, history_uint
   Output (kolom kunci):
     - itemid, clock, value (latest)
   Assumptions & Caveats:
     - Jika ada lebih dari 1 row pada clock yang sama, MAX(value) dipakai (asumsi setara).
   ========================================================================== */
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

/* =============================================================================
   CTE: current_disk
   Tujuan:
     - Menghitung current_usage_pct per VM + partition dari latest used & free (history_uint).
   Input (cte):
     - list_server, item_pair, las_val
   Output (kolom kunci):
     - hostid, vm_name, partition_name
     - current_usage_pct
     - clock_used, clock_free (untuk audit sinkronisasi data)
   Assumptions & Caveats:
     - clock_used dan clock_free bisa berbeda (tergantung data terakhir masing-masing item).
     - Jika used atau free NULL → current_usage_pct NULL (menandakan data tidak lengkap).
   ========================================================================== */
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

/* =============================================================================
   CTE: ordered_daily
   Tujuan:
     - Memberikan urutan (rn) dan jumlah (cnt) data daily per host + partition,
       sebagai persiapan perhitungan percentile.
   Input (cte):
     - daily
   Output (kolom kunci):
     - hostid, vm_name, partition_name
     - usage_pct, rn, cnt
   Assumptions & Caveats:
     - ORDER BY usage_pct menaik; P95 diambil dari posisi CEIL(cnt*0.95).
     - Bila cnt kecil, P95 bisa “lompat” mendekati nilai maksimum.
   ========================================================================== */
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

/* =============================================================================
   CTE: p95
   Tujuan:
     - Mengambil nilai usage_pct pada posisi CEIL(cnt*0.95) sebagai 95th percentile (P95).
   Input (cte):
     - ordered_daily
   Output (kolom kunci):
     - hostid, vm_name, partition_name
     - p95_usage_pct
   Assumptions & Caveats:
     - Ini metode discrete percentile (ambil salah satu titik data), bukan interpolasi statistik.
   ========================================================================== */
p95 AS (
  SELECT
    hostid,
    vm_name,
    partition_name,
    MAX(CASE WHEN rn = CEIL(cnt * 0.95) THEN usage_pct END) AS p95_usage_pct
  FROM ordered_daily
  GROUP BY hostid, vm_name, partition_name
),

/* =============================================================================
   CTE: power_state
   Tujuan:
     - Mengambil power state VM terbaru (0/1/2) dari item VMware powerstate (window 1 jam).
   Input (tabel):
     - items, history_uint
   Output (kolom kunci):
     - hostid
     - power_state
   Assumptions & Caveats:
     - Jika tidak ada sampel 1 jam terakhir → VM akan tampil 'Unknown' pada SELECT akhir.
     - Menggunakan data history_uint (bukan trends) karena butuh nilai terbaru.
   ========================================================================== */
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

/* =============================================================================
   SELECT FINAL
   Tujuan:
     - Menampilkan VM + partition yang average usage%-nya masuk range threshold.
     - Menambahkan konteks: current usage%, P95 usage%, dan power state.
   Output:
     - vm, partition_name, PowerState, current_disk_pct, average_disk_pct, percentile_95th_pct
   Assumptions & Caveats:
     - Hanya avg_usage_pct yang dipakai untuk filter threshold (bukan current/P95).
     - LEFT JOIN membuat current_disk/p95/power_state bisa NULL/Unknown tanpa menghilangkan baris monthly.
   ========================================================================== */
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
  m.partition_name;
