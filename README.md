# VMware Disk Utilization Query

Query ini digunakan untuk memonitor dan menganalisis **disk utilization VM VMware**
berdasarkan data monitoring Zabbix.

Laporan mencakup:
- Average disk usage (%)
- Current disk usage (%)
- 95th percentile disk usage (P95)
- Power state VM (On / Off / Suspended)

Query dirancang untuk kebutuhan operasional, capacity planning,
dan analisis risiko disk penuh (disk saturation).

---

## Output Columns

| Column | Description |
|------|------------|
| vm | Nama VM |
| partition_name | Nama partition/filesystem |
| PowerState | Powered On / Off / Suspended |
| current_disk_pct | Disk usage terkini (%) |
| average_disk_pct | Rata-rata disk usage periode (%) |
| percentile_95th_pct | 95th percentile disk usage (%) |

---

## Documentation

- [Overview & Architecture](overview.md)
- [CTE Reference](cte-reference.md)
- [Assumptions & Design Decisions](assumptions-and-design.md)
- [Troubleshooting Guide](troubleshooting.md)

---

## Notes

- Query menggunakan `trends_uint` untuk analisis historis
- Query menggunakan `history_uint` untuk kondisi terkini (current state)
- Threshold ditentukan dari parameter dashboard (Grafana/Zabbix UI)
