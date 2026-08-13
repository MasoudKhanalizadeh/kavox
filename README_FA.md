# Kavox Lite

ابزار Bash-only برای اجرای تکرارپذیر تست‌های ذخیره‌سازی با FIO روی Linux،
Bare Metal، ماشین مجازی و چند LUN موازی.

> هشدار: آماده‌سازی Dataset یک نوشتن واقعی 1 TiB روی هر مسیر انتخابی انجام می‌دهد
> و Jobهای Write/Mixed محتوای Dataset را تغییر می‌دهند. این ابزار را فقط روی
> فضای اختصاصی تست اجرا کنید؛ هرگز مسیر فایل‌سیستم Root یا دادهٔ تولیدی را ندهید.

[English README](README.md)

## قابلیت‌ها

- یک منوی تعاملی برای پیکربندی، آماده‌سازی Dataset، اجرا، تحلیل و مقایسه؛
- ۱۹ Profile آماده شامل Random، Sequential، Mixed و Zipf؛
- اجرای موازی روی چند LUN و اجرای ترتیبی Jobها و Repeatها؛
- سه سیاست Queue Depth: برابری QD کل، QD کل سفارشی و QD ثابت به‌ازای هر LUN؛
- خروجی Normal و JSON+ از همان اجرای FIO؛
- محاسبهٔ IOPS، Bandwidth، Latency، p50/p95/p99/p99.9، Mean، Median، SD و CV؛
- تله‌متری اختیاری iostat و Snapshot سیستم قبل/بعد تست؛
- نام‌گذاری معنادار پوشهٔ نتیجه بر اساس محیط، تعداد LUN، QD، Jobها، Runtime و Repeat؛
- محافظت از Dataset موجود، خروجی SHA-256 و Self-testهای بدون I/O واقعی.

## نیازمندی‌ها

- Linux و Bash 4 یا جدیدتر؛
- `fio`، `jq`، `awk`، `mountpoint`، `findmnt`، `stat`، `sha256sum` و `readlink`؛
- فایل‌سیستم XFS برای مسیرهای Benchmark؛
- `iostat` از بستهٔ `sysstat` اختیاری است.

روی Ubuntu/Debian:

```bash
sudo apt update
sudo apt install fio jq sysstat
```

## شروع سریع

```bash
git clone https://github.com/MasoudKhanalizadeh/kavox.git
cd kavox
chmod +x *.sh tests/*.sh tests/mock_bin/*
./kavox.sh
```

برای تست طولانی بهتر است از `tmux` استفاده شود:

```bash
tmux new -s kavox
./kavox.sh
```

## روند پیشنهادی

از منوی اصلی گزینهٔ `Guided workflow` را اجرا کنید:

```text
Configuration -> Dependency check -> Dataset status -> Read-only samples
-> Optional metadata -> Job selection -> Benchmark -> Analysis
```

Dataset هر LUN در مسیر زیر قرار می‌گیرد:

```text
MOUNT_PATH/fio-test/fio-data-1TiB.bin
```

وضعیت‌ها:

- `READY`: اندازه دقیق 1 TiB و Marker معتبر؛
- `RECOVERABLE`: فایل 1 TiB موجود است اما Marker معتبر ندارد و بازنویسی نمی‌شود؛
- `MISSING`: فایل وجود ندارد و می‌تواند پس از تأیید صریح ساخته شود؛
- `WRONG SIZE/CONFLICT`: توقف ایمن برای بررسی دستی.

## سیاست‌های Queue Depth

1. `normalize-profile` — پیش‌فرض پیشنهادی؛ QD کل Profile تک-LUN حفظ و میان LUNها تقسیم می‌شود.
2. `custom-total` — یک QD کل دلخواه دقیقاً میان همهٔ LUNها تقسیم می‌شود.
3. `per-lun-profile` — Profile اصلی روی هر LUN تکرار می‌شود و QD کل با تعداد LUN رشد می‌کند.

در حالت برابری QD، سهم اضافه میان Repeatها می‌چرخد تا یک LUN همیشه بار بیشتری نگیرد.
مقادیر واقعی `numjobs` و `iodepth` در `qd_plan.tsv` و Jobهای Renderشده ثبت می‌شوند.

## خروجی‌ها

نمونهٔ نام Result:

```text
baremetal_3lun_qd-equal-profile_jobs-01-03-15_rt300s_r3_tag-raid5-pool-a_20260812-003015
```

ساختار خلاصه:

```text
results/RUN_NAME/
├── run.env
├── benchmark_metadata.tsv
├── manifest.tsv
├── qd_plan.tsv
├── run.log
├── SHA256SUMS
├── system/
├── JOB/repeat-XX/
└── analysis/
    ├── aggregate_statistics.json
    ├── aggregate_statistics.tsv
    ├── aggregate_statistics.csv
    ├── final_result.json
    └── FINAL_REPORT.txt
```

واحد Bandwidth در گزارش‌ها MiB/s و واحد Latency برابر ms است.

## Self-test

این تست‌ها از Mock استفاده می‌کنند و I/O واقعی روی SAN انجام نمی‌دهند:

```bash
make test
```

## حریم خصوصی نتایج

پوشه‌های Result ممکن است hostname، شناسهٔ دیسک/LUN، WWN، Serial و اطلاعات SAN
را ثبت کنند. فایل `.gitignore` از Commit تصادفی خروجی‌ها جلوگیری می‌کند، اما پیش
از انتشار هر Result آن را دستی بازبینی و در صورت نیاز ناشناس‌سازی کنید.

## وضعیت پروژه

این مخزن نسخهٔ اولیهٔ عمومی **Kavox Lite v0.1.0** است. Kavox Lite هستهٔ عملیاتی
و سادهٔ Runner است؛ توسعهٔ آینده می‌تواند مدیریت اجرای SSH، Resume/Continue،
تعریف Suite و Result Tracking مرکزی را به نسخهٔ کامل Kavox اضافه کند.

## مجوز

[MIT License](LICENSE)

