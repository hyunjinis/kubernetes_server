#!/usr/bin/env bash
# attach-mode: 트래픽(예: netperf)은 외부에서 이미 실행 중
# 사용법:
#   sudo ./nagle_attach.sh <DEV> <DST_IP> [DURATION_SEC] [SS_INTERVAL_MS]
# 예시:
#   sudo ./nagle_attach.sh eth0 192.168.0.139 30 200

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: sudo $0 <DEV> <DST_IP> [DURATION_SEC=30] [SS_INTERVAL_MS=200]"
  exit 2
fi

DEV="$1"
DST="$2"
DUR="${3:-30}"
SSINT_MS="${4:-200}"

# ----- tracefs/debugfs mount & TRACE path 선택 -----
sudo mkdir -p /sys/kernel/tracing /sys/kernel/debug
sudo mount -t tracefs nodev /sys/kernel/tracing 2>/dev/null || true
sudo mount -t debugfs nodev /sys/kernel/debug 2>/dev/null || true

if [[ -d /sys/kernel/tracing ]]; then
  TRACE=/sys/kernel/tracing
else
  TRACE=/sys/kernel/debug/tracing
fi

if [[ ! -d "$TRACE" ]]; then
  echo "[!] tracefs/debugfs unavailable"; exit 1
fi

# ftrace 가능 체크
if ! grep -q 'function_graph' "$TRACE/available_tracers"; then
  echo "[!] function_graph tracer not available"; exit 1
fi

# ----- 타깃 함수 (존재하는 것만 선택) -----
want=(
  tcp_write_xmit __tcp_push_pending_frames tcp_push
  tcp_nagle_test tcp_pacing_check tcp_small_queue_check tcp_tso_should_defer
  validate_xmit_skb __skb_gso_segment skb_udp_tunnel_segment
)
avail="$TRACE/available_filter_functions"
sel=()
for fn in "${want[@]}"; do
  if grep -qw "^$fn$" "$avail" || grep -qw "$fn " "$avail"; then sel+=("$fn"); fi
done
((${#sel[@]}>0)) || { echo "[!] none of target functions available"; exit 1; }

# ----- 추정 MSS (route MTU 기반) -----
MTU=$(ip route get "$DST" 2>/dev/null | awk '/mtu/ {for(i=1;i<=NF;i++) if($i=="mtu"){print $(i+1)}}')
[[ -z "${MTU}" ]] && MTU=$(ip -o link show dev "$DEV" | awk '{for(i=1;i<=NF;i++) if ($i=="mtu"){print $(i+1)}}')
[[ -z "${MTU}" ]] && { echo "[!] MTU not found"; exit 1; }
HDR=$([[ "$DST" == *:* ]] && echo 60 || echo 40)
MSS=$((MTU - HDR))
echo "[i] egress dev=$DEV, DST=$DST, MTU=$MTU → MSS≈$MSS"

# ----- tracepoint 존재 여부 -----
TP="$TRACE/events/net/net_dev_queue"
TP_ON=0
if [[ -d "$TP" ]]; then TP_ON=1; fi

# ----- 사전 초기화 -----
echo 0 | sudo tee "$TRACE/tracing_on" >/dev/null
:     | sudo tee "$TRACE/trace" >/dev/null
:     | sudo tee "$TRACE/set_ftrace_filter" >/dev/null
printf "%s\n" "${sel[@]}" | sudo tee "$TRACE/set_ftrace_filter" >/dev/null
echo function_graph | sudo tee "$TRACE/current_tracer" >/dev/null
echo 1 | sudo tee "$TRACE/options/funcgraph-retval" >/dev/null
echo 1 | sudo tee "$TRACE/options/funcgraph-duration" >/dev/null
if ((TP_ON)); then echo 1 | sudo tee "$TP/enable" >/dev/null; fi

# ----- ss -tin 스냅샷 백그라운드 수집 -----
SS_OUT="nagle_attach_ss_$(date +%Y%m%d_%H%M%S).log"
ss_snap_bg() {
  CNT=$(( (DUR*1000) / SSINT_MS ))
  for _ in $(seq 1 $CNT); do
    ss -tin | sed -n '1,60p' >> "$SS_OUT" 2>/dev/null
    usleep $((SSINT_MS*1000)) 2>/dev/null || sleep 0.$SSINT_MS
  done
}
command -v usleep >/dev/null || alias usleep='sleep'
ss_snap_bg & SS_PID=$!

# ----- 트레이싱 시작 -----
echo 1 | sudo tee "$TRACE/tracing_on" >/dev/null
echo "[i] tracing for ${DUR}s … (netperf는 외부에서 이미 실행 중이어야 합니다)"
sleep "$DUR"
echo 0 | sudo tee "$TRACE/tracing_on" >/dev/null
if ((TP_ON)); then echo 0 | sudo tee "$TP/enable" >/dev/null; fi

# ss 수집 종료 대기
kill "$SS_PID" 2>/dev/null || true
wait "$SS_PID" 2>/dev/null || true

# ----- 결과 저장 & 요약 -----
TS=$(date +%Y%m%d_%H%M%S)
OUT="nagle_attach_${TS}.trace"
sudo cat "$TRACE/trace" > "$OUT"

SUM="$OUT.summary"
{
  echo "=== Nagle/TSQ/Pacing decision summary (attach) ==="
  echo "dev=$DEV, dst=$DST, dur=${DUR}s, ss_interval=${SSINT_MS}ms"
  echo "MTU=$MTU → MSS≈$MSS"
  echo
  echo "[function hits]"
  for fn in "${sel[@]}"; do
    c=$(grep -c " $fn(" "$OUT" || true)
    printf "  %-24s %8d\n" "$fn" "$c"
  done

  # tcp_nagle_test 반환값
  if grep -q " tcp_nagle_test(" "$OUT"; then
    T=$(grep -c " tcp_nagle_test(" "$OUT" || true)
    T0=$(grep -c " tcp_nagle_test() .*returned 0" "$OUT" || true)
    T1=$(grep -c " tcp_nagle_test() .*returned 1" "$OUT" || true)
    echo -e "\n[tcp_nagle_test returns]"
    echo "  total : $T"
    echo "  ret=0 : $T0 (defer/sticky)"
    echo "  ret=1 : $T1 (send now)"
  fi

  # TSQ/pacing/TSO-defer 반환값
  for fn in tcp_small_queue_check tcp_pacing_check tcp_tso_should_defer; do
    if grep -q " $fn(" "$OUT"; then
      X=$(grep -c " $fn(" "$OUT" || true)
      X0=$(grep -c " $fn() .*returned 0" "$OUT" || true)
      X1=$(grep -c " $fn() .*returned 1" "$OUT" || true)
      echo -e "\n[$fn returns]"
      echo "  total : $X"
      echo "  ret=0 : $X0"
      echo "  ret=1 : $X1"
    fi
  done

  # len vs MSS 개략(가능할 때)
  if ((TP_ON)); then
    LENTMP=$(mktemp)
    grep -E "net_dev_queue:.*(dev=${DEV}|name=${DEV})" "$OUT" \
      | sed -E 's/.* (len|skb_len)=([0-9]+).*/\2/' \
      | grep -E '^[0-9]+$' > "$LENTMP" || true
    TOT=$(wc -l < "$LENTMP" | tr -d ' ')
    LEQ=0; GT=0
    if ((TOT>0)); then
      while read -r L; do
        if (( L <= MSS )); then LEQ=$((LEQ+1)); else GT=$((GT+1)); fi
      done < "$LENTMP"
    fi
    echo -e "\n[len vs MSS≈$MSS]"
    echo "  samples: $TOT"
    echo "  len<=MSS: $LEQ"
    echo "  len> MSS: $GT"
  fi

  echo -e "\n[files]"
  echo "  trace    : $OUT"
  echo "  summary  : $SUM"
  echo "  ss-snap  : $SS_OUT"
} | tee "$SUM"

echo "[i] done"
