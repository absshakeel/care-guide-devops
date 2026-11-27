#!/usr/bin/env bash
# system_health.sh — Host health check script for Care Guide DevOps assessment
#
# Usage:
#   ./system_health.sh [--cpu N] [--mem N] [--disk N] [--json] [--help]
#
# Exit codes:
#   0 — all metrics within thresholds (healthy)
#   1 — at least one metric exceeds a warning threshold
#   2 — at least one metric exceeds a critical threshold (2× the warning value)
#
# Log rotation is handled by logrotate. See /etc/logrotate.d/system_health.

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults and constants
# ---------------------------------------------------------------------------
SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
readonly LOG_FILE="${LOG_FILE:-health_log.txt}"
TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
readonly TIMESTAMP

DEFAULT_CPU_WARN=80
DEFAULT_MEM_WARN=85
DEFAULT_DISK_WARN=80

cpu_threshold="${DEFAULT_CPU_WARN}"
mem_threshold="${DEFAULT_MEM_WARN}"
disk_threshold="${DEFAULT_DISK_WARN}"
json_output=false

# Exit status accumulator: 0=ok, 1=warning, 2=critical
exit_status=0
warnings=()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
_log() {
    # Write timestamped line to log file; print to stdout only in non-JSON mode
    local msg="[$TIMESTAMP] $*"
    if [[ "$json_output" != "true" ]]; then
        echo "$msg"
    fi
    echo "$msg" >> "$LOG_FILE"
}

_warn() {
    warnings+=("$*")
    _log "[WARNING] $*"
    if [[ $exit_status -lt 1 ]]; then exit_status=1; fi
}

_critical() {
    warnings+=("CRITICAL: $*")
    _log "[CRITICAL] $*"
    exit_status=2
}

_usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

OPTIONS:
  --cpu N     CPU warning threshold in percent (default: $DEFAULT_CPU_WARN)
  --mem N     Memory warning threshold in percent (default: $DEFAULT_MEM_WARN)
  --disk N    Disk warning threshold in percent (default: $DEFAULT_DISK_WARN)
  --json      Output metrics as a JSON object to stdout
  --help      Show this help message

EXIT CODES:
  0  Healthy — all metrics within thresholds
  1  Warning — one or more metrics above the warning threshold
  2  Critical — one or more metrics above 2× the warning threshold

EXAMPLES:
  $SCRIPT_NAME
  $SCRIPT_NAME --cpu 70 --mem 75 --disk 85 --json
  $SCRIPT_NAME --json | jq .cpu_percent
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cpu)
            [[ -n "${2:-}" ]] || { echo "Error: --cpu requires a value" >&2; exit 2; }
            cpu_threshold="$2"; shift 2 ;;
        --mem)
            [[ -n "${2:-}" ]] || { echo "Error: --mem requires a value" >&2; exit 2; }
            mem_threshold="$2"; shift 2 ;;
        --disk)
            [[ -n "${2:-}" ]] || { echo "Error: --disk requires a value" >&2; exit 2; }
            disk_threshold="$2"; shift 2 ;;
        --json)
            json_output=true; shift ;;
        --help|-h)
            _usage; exit 0 ;;
        *)
            echo "Unknown option: $1" >&2; _usage >&2; exit 2 ;;
    esac
done

# Derived critical thresholds (2× warning, capped at 100)
cpu_critical=$(( cpu_threshold * 2 > 100 ? 100 : cpu_threshold * 2 ))
mem_critical=$(( mem_threshold * 2 > 100 ? 100 : mem_threshold * 2 ))
disk_critical=$(( disk_threshold * 2 > 100 ? 100 : disk_threshold * 2 ))

# ---------------------------------------------------------------------------
# CPU usage (1-second sample)
# ---------------------------------------------------------------------------
_get_cpu_percent() {
    # Read /proc/stat twice with a 1-second gap and derive idle percentage.
    # Avoids spawning external tools like top/mpstat which may not be present.
    local line1 line2
    line1=$(grep -m1 '^cpu ' /proc/stat)
    sleep 1
    line2=$(grep -m1 '^cpu ' /proc/stat)

    # Fields: cpu user nice system idle iowait irq softirq
    read -r _ u1 n1 s1 i1 w1 _ _ <<< "$line1"
    read -r _ u2 n2 s2 i2 w2 _ _ <<< "$line2"

    local total1=$(( u1 + n1 + s1 + i1 + w1 ))
    local total2=$(( u2 + n2 + s2 + i2 + w2 ))
    local idle1=$i1
    local idle2=$i2

    local delta_total=$(( total2 - total1 ))
    local delta_idle=$(( idle2 - idle1 ))

    if [[ $delta_total -eq 0 ]]; then
        echo "0"
    else
        echo $(( (delta_total - delta_idle) * 100 / delta_total ))
    fi
}

cpu_percent=$(_get_cpu_percent)

if [[ $cpu_percent -ge $cpu_critical ]]; then
    _critical "CPU usage ${cpu_percent}% exceeds critical threshold ${cpu_critical}%"
elif [[ $cpu_percent -ge $cpu_threshold ]]; then
    _warn "CPU usage ${cpu_percent}% exceeds warning threshold ${cpu_threshold}%"
fi

# ---------------------------------------------------------------------------
# Memory usage
# ---------------------------------------------------------------------------
_get_mem_values() {
    local total avail
    total=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    avail=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
    echo "$total $avail"
}

read -r mem_total mem_avail <<< "$(_get_mem_values)"
mem_used=$(( mem_total - mem_avail ))
mem_percent=$(( mem_used * 100 / mem_total ))
mem_total_mb=$(( mem_total / 1024 ))
mem_used_mb=$(( mem_used / 1024 ))

if [[ $mem_percent -ge $mem_critical ]]; then
    _critical "Memory usage ${mem_percent}% exceeds critical threshold ${mem_critical}%"
elif [[ $mem_percent -ge $mem_threshold ]]; then
    _warn "Memory usage ${mem_percent}% exceeds warning threshold ${mem_threshold}%"
fi

# ---------------------------------------------------------------------------
# Load average
# ---------------------------------------------------------------------------
read -r load1 load5 load15 _ _ < /proc/loadavg
cpu_count=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo)

# ---------------------------------------------------------------------------
# Disk usage — iterate all mounted filesystems
# ---------------------------------------------------------------------------
declare -A disk_data=()
disk_max_percent=0

# Use df with POSIX output; skip pseudo-filesystems
while IFS= read -r line; do
    # Fields: Filesystem 1K-blocks Used Available Use% Mounted
    local_fs=$(echo "$line" | awk '{print $1}')
    use_pct=$(echo "$line" | awk '{print $5}' | tr -d '%')
    mount=$(echo "$line" | awk '{print $6}')

    # Skip pseudo-filesystems and Docker overlay mounts
    case "$local_fs" in
        tmpfs|devtmpfs|sysfs|proc|cgroup*|devpts|overlay|none) continue ;;
    esac
    # Skip numeric-only use% (header or unusual lines)
    [[ "$use_pct" =~ ^[0-9]+$ ]] || continue

    disk_data["$mount"]=$use_pct

    if [[ $use_pct -ge $disk_critical ]]; then
        _critical "Disk ${mount} at ${use_pct}% exceeds critical threshold ${disk_critical}%"
    elif [[ $use_pct -ge $disk_threshold ]]; then
        _warn "Disk ${mount} at ${use_pct}% exceeds warning threshold ${disk_threshold}%"
    fi

    if [[ $use_pct -gt $disk_max_percent ]]; then
        disk_max_percent=$use_pct
    fi
done < <(df -P 2>/dev/null | tail -n +2)

# ---------------------------------------------------------------------------
# Top 5 processes by memory (RSS)
# ---------------------------------------------------------------------------
top5_mem=""
if command -v ps &>/dev/null; then
    top5_mem=$(ps aux --sort=-%mem 2>/dev/null | awk 'NR==1 || NR<=6' | head -6 || true)
fi

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if [[ "$json_output" == "true" ]]; then
    # Build disk JSON object
    disk_json="{"
    first=true
    for mount in "${!disk_data[@]}"; do
        [[ "$first" == "true" ]] || disk_json+=","
        disk_json+="\"${mount}\": ${disk_data[$mount]}"
        first=false
    done
    disk_json+="}"

    # Build warnings JSON array
    warn_json="["
    first=true
    for w in "${warnings[@]+"${warnings[@]}"}"; do
        [[ "$first" == "true" ]] || warn_json+=","
        # Escape double quotes inside warning strings
        escaped="${w//\"/\\\"}"
        warn_json+="\"${escaped}\""
        first=false
    done
    warn_json+="]"

    printf '{
  "timestamp": "%s",
  "cpu_percent": %s,
  "memory_percent": %s,
  "memory_used_mb": %s,
  "memory_total_mb": %s,
  "load_average": { "1m": "%s", "5m": "%s", "15m": "%s" },
  "disk_percent": %s,
  "cpu_count": %s,
  "exit_status": %s,
  "warnings": %s
}\n' \
        "$TIMESTAMP" "$cpu_percent" "$mem_percent" "$mem_used_mb" "$mem_total_mb" \
        "$load1" "$load5" "$load15" \
        "$disk_json" "$cpu_count" "$exit_status" "$warn_json"
else
    _log "=== System Health Report ==="
    _log "CPU:    ${cpu_percent}% (threshold: ${cpu_threshold}%)"
    _log "Memory: ${mem_percent}% used (${mem_used_mb} MB / ${mem_total_mb} MB, threshold: ${mem_threshold}%)"
    _log "Load:   ${load1} ${load5} ${load15} (${cpu_count} CPUs)"
    _log "Disk usage by filesystem:"
    for mount in "${!disk_data[@]}"; do
        _log "  ${mount}: ${disk_data[$mount]}%"
    done
    if [[ -n "$top5_mem" ]]; then
        _log "Top 5 processes by memory:"
        while IFS= read -r proc_line; do
            _log "  $proc_line"
        done <<< "$top5_mem"
    fi
    _log "Status: exit_code=${exit_status}"
fi

exit "$exit_status"

