# Kavox Lite

**مخزن رسمی:** [https://github.com/MasoudKhanalizadeh/kavox](https://github.com/MasoudKhanalizadeh/kavox)
**پشتیبانی:** [گزارش باگ، پرسش و راه‌های ارتباط](SUPPORT.md)

ابزار Bash-only برای اجرای تکرارپذیر تست‌های ذخیره‌سازی با FIO روی Linux،
Bare Metal، ماشین مجازی و چند LUN موازی.

> هشدار: آماده‌سازی Dataset به‌اندازه مقدار تنظیم‌شده روی هر مسیر انتخابی نوشتن واقعی انجام می‌دهد
> و Jobهای Write/Mixed محتوای Dataset را تغییر می‌دهند. این ابزار را فقط روی
> فضای اختصاصی تست اجرا کنید؛ هرگز مسیر فایل‌سیستم Root یا دادهٔ تولیدی را ندهید.

[English README](README.md)

## قابلیت‌ها

- یک منوی تعاملی برای پیکربندی، آماده‌سازی Dataset، اجرا، تحلیل و مقایسه؛
- اندازه قابل‌تنظیم Dataset برای هر LUN با واحدهای باینری هم‌تراز؛
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

## اندازه Dataset

هنگام پیکربندی محیط، Kavox اندازه Dataset هر LUN را می‌پرسد. مقدار باید عدد
صحیح و دارای یکی از واحدهای باینری `MiB`، `GiB` یا `TiB` باشد؛ برای مثال:

```text
512MiB
20GiB
500GiB
1TiB
```

حداقل اندازه `64MiB` است و مقدار باید بر `1MiB` بخش‌پذیر باشد. واحدهای مبهم
مانند `GB` و مقادیر اعشاری مانند `1.5TiB` پذیرفته نمی‌شوند. مقدار پیش‌فرض
همچنان `1TiB` است.

برای هر اندازه، فایل و Marker جداگانه ساخته می‌شود؛ مثلاً `20GiB` از فایل
`fio-data-20GiB.bin` استفاده می‌کند. تغییر اندازه هیچ Dataset موجود با اندازه
دیگر را Truncate یا Overwrite نمی‌کند.

Dataset هر LUN در مسیر زیر قرار می‌گیرد:

```text
MOUNT_PATH/fio-test/fio-data-SIZE.bin
```

وضعیت‌ها:

- `READY`: فایل با اندازه تنظیم‌شده و Marker معتبر؛
- `RECOVERABLE`: فایل هم‌اندازه موجود است اما Marker معتبر ندارد و بازنویسی نمی‌شود؛
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
baremetal_3lun_ds-500GiB_qd-equal-profile_jobs-01-03-15_rt300s_r3_tag-raid5-pool-a_20260819-003015
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

نسخه فعلی **Kavox Lite v0.2.0** است. Kavox Lite هستهٔ عملیاتی
و سادهٔ Runner است؛ توسعهٔ آینده می‌تواند مدیریت اجرای SSH، Resume/Continue،
تعریف Suite و Result Tracking مرکزی را به نسخهٔ کامل Kavox اضافه کند.

## مجوز

[GNU AGPL v3](LICENSE)


## مجوز و پشتیبانی

Kavox تحت مجوز **AGPL-3.0-only** رایگان و متن‌باز است. جزئیات در
[NOTICE](NOTICE)، [سیاست علامت تجاری](TRADEMARKS.md) و
[مجوز تجاری](COMMERCIAL-LICENSE.md) آمده است. برای گزارش باگ، پرسش دربارهٔ
نحوهٔ استفاده یا پیدا کردن راه ارتباط مناسب، [SUPPORT.md](SUPPORT.md) را ببینید.
