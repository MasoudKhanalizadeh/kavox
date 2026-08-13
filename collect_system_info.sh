#!/usr/bin/env bash

# Collect a read-only system snapshot for benchmark reproducibility.
# Usage: ./collect_system_info.sh OUTPUT_DIR MOUNT_PATHS_CSV [LABEL]

set -u
set -o pipefail

OUTPUT_DIR="${1:-}"
MOUNT_PATHS_CSV="${2:-}"
SNAPSHOT_LABEL="${3:-snapshot}"
DATASET_RELATIVE_PATH="fio-test/fio-data-1TiB.bin"

if [[ -z "$OUTPUT_DIR" || -z "$MOUNT_PATHS_CSV" ]]; then
    echo "Usage: $0 OUTPUT_DIR MOUNT_PATHS_CSV [LABEL]" >&2
    exit 2
fi

mkdir -p "$OUTPUT_DIR"

capture() {
    local output_file="$1"
    shift
    {
        echo "# command: $*"
        echo "# captured: $(date -Is)"
        if command -v "$1" >/dev/null 2>&1; then
            timeout 30 "$@"
            rc=$?
            if (( rc != 0 )); then
                echo "# command_exit_code=$rc"
            fi
        else
            echo "# unavailable: $1"
        fi
    } > "$OUTPUT_DIR/$output_file" 2>&1
}

capture_shell() {
    local output_file="$1"
    shift
    {
        echo "# shell: $*"
        echo "# captured: $(date -Is)"
        timeout 30 bash -c "$*"
        rc=$?
        if (( rc != 0 )); then
            echo "# command_exit_code=$rc"
        fi
    } > "$OUTPUT_DIR/$output_file" 2>&1
}

START_ISO="$(date -Is)"
HOSTNAME_VALUE="$(hostname 2>/dev/null || echo unknown)"
KERNEL_VALUE="$(uname -r 2>/dev/null || echo unknown)"
FIO_VERSION="$(fio --version 2>/dev/null || echo unavailable)"
VIRT_VALUE="$(systemd-detect-virt 2>/dev/null || echo none-or-unknown)"
UPTIME_SECONDS="$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)"

if command -v jq >/dev/null 2>&1; then
    jq -n \
        --arg schema_version "1.0" \
        --arg label "$SNAPSHOT_LABEL" \
        --arg captured_at "$START_ISO" \
        --arg hostname "$HOSTNAME_VALUE" \
        --arg kernel "$KERNEL_VALUE" \
        --arg fio_version "$FIO_VERSION" \
        --arg virtualization "$VIRT_VALUE" \
        --arg mount_paths "$MOUNT_PATHS_CSV" \
        --argjson uptime_seconds "${UPTIME_SECONDS:-0}" \
        '{schema_version:$schema_version,label:$label,captured_at:$captured_at,
          hostname:$hostname,kernel:$kernel,fio_version:$fio_version,
          virtualization:$virtualization,uptime_seconds:$uptime_seconds,
          mount_paths:($mount_paths|split(","))}' \
        > "$OUTPUT_DIR/snapshot.json"
else
    printf 'label=%s\ncaptured_at=%s\nhostname=%s\nkernel=%s\nfio_version=%s\nvirtualization=%s\nuptime_seconds=%s\nmount_paths=%s\n' \
        "$SNAPSHOT_LABEL" "$START_ISO" "$HOSTNAME_VALUE" "$KERNEL_VALUE" \
        "$FIO_VERSION" "$VIRT_VALUE" "$UPTIME_SECONDS" "$MOUNT_PATHS_CSV" \
        > "$OUTPUT_DIR/snapshot.txt"
fi

capture date-time.txt date -Ins
capture timedatectl.txt timedatectl status
capture hostnamectl.txt hostnamectl status
capture uname.txt uname -a
capture os-release.txt sh -c 'cat /etc/os-release 2>/dev/null; echo; cat /etc/lsb-release 2>/dev/null'
capture uptime.txt uptime
capture virtualization.txt systemd-detect-virt
capture fio-version.txt fio --version
capture iostat-version.txt iostat -V
capture lscpu.txt lscpu
capture lscpu.json lscpu -J
capture free.txt free -b
capture meminfo.txt cat /proc/meminfo
capture vmstat-summary.txt vmstat -s
capture numa.txt numactl --hardware
capture cpu-governor.txt sh -c 'for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do [[ -r "$f" ]] && printf "%s=" "$f" && cat "$f"; done'
capture lsblk.txt lsblk -e 7 -o NAME,KNAME,PATH,TYPE,SIZE,ROTA,LOG-SEC,PHY-SEC,MIN-IO,OPT-IO,ALIGNMENT,VENDOR,MODEL,REV,SERIAL,WWN,FSTYPE,FSVER,LABEL,UUID,MOUNTPOINTS
capture lsblk.json lsblk -e 7 -O -J
capture findmnt.txt findmnt -A
capture findmnt.json findmnt -A -J
capture df.txt df -hT
capture blkid.txt blkid
capture mount.txt mount
capture lsscsi.txt lsscsi -t -g -s
capture multipath.txt multipath -ll
capture dmsetup-info.txt dmsetup info -c
capture dmsetup-table.txt dmsetup table
capture dmsetup-status.txt dmsetup status
capture pvs.txt pvs -a -o+devices
capture vgs.txt vgs -a
capture lvs.txt lvs -a -o+devices
capture lspci.txt lspci -nnk
capture dmidecode-system.txt dmidecode -t system
capture dmidecode-bios.txt dmidecode -t bios
capture dmidecode-baseboard.txt dmidecode -t baseboard
capture dmidecode-processor.txt dmidecode -t processor
capture dmidecode-memory.txt dmidecode -t memory
capture lsmod.txt lsmod
capture cmdline.txt cat /proc/cmdline
capture sysctl-storage-vm.txt sysctl vm.dirty_background_bytes vm.dirty_background_ratio vm.dirty_bytes vm.dirty_ratio vm.dirty_expire_centisecs vm.dirty_writeback_centisecs vm.swappiness vm.vfs_cache_pressure fs.aio-max-nr fs.file-max
capture interrupts.txt cat /proc/interrupts
capture softirqs.txt cat /proc/softirqs
capture ip-address.txt ip -details address show
capture ip-link.txt ip -details link show
capture ip-route.txt ip route show table all
capture sockets-summary.txt ss -s
capture processes.txt ps -eo pid,ppid,psr,ni,pri,stat,pcpu,pmem,comm,args --sort=-pcpu
capture top.txt top -b -n 1 -w 512
capture failed-services.txt systemctl --failed --no-pager
capture sensors.txt sensors
capture dmesg.txt dmesg -T
capture kernel-journal.txt journalctl -k -n 2000 --no-pager

{
    echo "# captured: $(date -Is)"
    for host in /sys/class/fc_host/host*; do
        [[ -d "$host" ]] || continue
        echo "[$(basename "$host")]"
        for field in port_name node_name port_state port_type speed supported_speeds fabric_name symbolic_name dev_loss_tmo; do
            if [[ -r "$host/$field" ]]; then
                printf '%s=' "$field"
                cat "$host/$field"
            fi
        done
        if [[ -d "$host/statistics" ]]; then
            for statistic in "$host"/statistics/*; do
                [[ -r "$statistic" ]] || continue
                printf 'statistics.%s=' "$(basename "$statistic")"
                cat "$statistic"
            done
        fi
        echo
    done
} > "$OUTPUT_DIR/fibre-channel.txt" 2>&1

{
    echo "# captured: $(date -Is)"
    for queue in /sys/block/*/queue; do
        [[ -d "$queue" ]] || continue
        device="$(basename "$(dirname "$queue")")"
        echo "[$device]"
        for field in scheduler nr_requests read_ahead_kb logical_block_size physical_block_size minimum_io_size optimal_io_size max_hw_sectors_kb max_sectors_kb rotational rq_affinity nomerges; do
            if [[ -r "$queue/$field" ]]; then
                printf '%s=' "$field"
                cat "$queue/$field"
            fi
        done
        echo
    done
} > "$OUTPUT_DIR/block-queue-settings.txt" 2>&1

IFS=',' read -r -a MOUNT_PATHS <<< "$MOUNT_PATHS_CSV"
TARGETS_DIR="$OUTPUT_DIR/targets"
mkdir -p "$TARGETS_DIR"
for index in "${!MOUNT_PATHS[@]}"; do
    mount_path="${MOUNT_PATHS[$index]}"
    while [[ "$mount_path" != "/" && "$mount_path" == */ ]]; do
        mount_path="${mount_path%/}"
    done
    printf -v target_label 'lun-%02d' "$((index + 1))"
    target_dir="$TARGETS_DIR/$target_label"
    mkdir -p "$target_dir"
    if [[ ! "$mount_path" =~ ^/[A-Za-z0-9._/-]+$ || "$mount_path" == "/" ]]; then
        printf 'invalid_mount_path=%s\n' "$mount_path" > "$target_dir/identity.txt"
        continue
    fi
    dataset="$mount_path/$DATASET_RELATIVE_PATH"
    capture_shell "targets/$target_label/identity.txt" \
        "printf 'mount_path=%s\\ndataset=%s\\n' '$mount_path' '$dataset'; findmnt -nro TARGET,SOURCE,FSTYPE,FS-OPTIONS,UUID,PARTUUID --target '$mount_path'; stat -c 'dataset_size_bytes=%s dataset_inode=%i dataset_blocks=%b dataset_block_size=%B' '$dataset' 2>&1"
    capture_shell "targets/$target_label/xfs-info.txt" "xfs_info '$mount_path'"
    capture_shell "targets/$target_label/space.txt" "df -B1 -T '$mount_path'; df -i -T '$mount_path'"
    capture_shell "targets/$target_label/source-tree.txt" "source=\$(findmnt -nro SOURCE --target '$mount_path'); lsblk -O -J \"\$source\" 2>&1 || lsblk -O -J"
done

sha256sum "$OUTPUT_DIR"/* 2>/dev/null | sed "s#${OUTPUT_DIR}/##" > "$OUTPUT_DIR/SHA256SUMS" || true

echo "System snapshot created: $OUTPUT_DIR"
