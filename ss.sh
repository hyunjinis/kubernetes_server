#!/bin/bash
set -euo pipefail

# ===== 설정 =====
SERVER_IP="192.168.0.139"
NETPERF_PORT="12865"     # netperf control port(무시 대상)
pkt="1024"
DURATION=150
POD_NS="default"
POD_NAME="p1"            # ← 너 상황에 맞춰 p1로 설정

OUTDIR="p${pkt}_kubelet"
mkdir -p "$OUTDIR"

SS_CSV="$OUTDIR/ss_1s.csv"
echo "ts_ms,send_q,wscale,rto_ms,rtt_ms,cwnd,ssthresh,bytes_sent,bytes_retrans,bytes_acked,segs_out,segs_in,data_segs_out,pacing_rate,delivery_rate,delivered,app_limited,unacked,retrans,lastrcv_ms" > "$SS_CSV"

RAW_SS="$OUTDIR/ss_raw.txt"
# ===== netperf 시작 (Pod 내부) =====
kubectl exec "$POD_NAME" -n "$POD_NS" -- \
  sh -lc "netperf -H $SERVER_IP -p $NETPERF_PORT -l $DURATION -- -m $pkt" &
NP_BG=$!

# ===== 1초 주기 수집 (백그라운드) =====
(
  num(){ sed -E 's/^[^:]*://; s/ms$//; s/[GMK]bps$//; s/,/./g'; }

  # (A) 연결 성립 대기: 최대 20초
  
  for _ in {1..10}; do
    if kubectl exec "$POD_NAME" -n "$POD_NS" -- sh -lc \
      "ss -tn state established '( dst $SERVER_IP )'" 2>/dev/null | awk 'NR>1{exit 0} END{exit 1}'; then
      break
    fi
    sleep 1
  done

  # (B) 매초: 컨트롤 포트 제외한 **데이터 포트(=Peer Port)** 자동 선택 → 그 연결만 >파싱
  #for _ in $(seq 1 "$DURATION"); do
  for k in $(seq 1 10); do
    for i in {1..10}; do
      TS_MS=$(date +%s%3N)

    # 1) 현재 ESTABLISHED 중에서 서버 IP로 향하고, Peer Port != 12865 인 것만 골라 >첫 개 추출
      DPORT=$(kubectl exec "$POD_NAME" -n "$POD_NS" -- sh -lc \
        "ss -tn state established '( dst $SERVER_IP )' | \
         awk -v ctrl=':$NETPERF_PORT' '
           NR==1{next}
           {
             # 컬럼: Recv-Q Send-Q Local:Port  Peer:Port
             peer=\$5; split(peer,a,\":\");
             if (peer !~ ctrl && a[2] != \"\") { print a[2]; exit }
           }'" 2>/dev/null || true)

      RAW=""
      if [[ -n "${DPORT}" ]]; then
        # 2) 해당 **데이터 포트** 연결만 상세(TCP_INFO) 조회
        RAW="$(kubectl exec "$POD_NAME" -n "$POD_NS" -- sh -lc \
          "ss -tin '( dst $SERVER_IP and dport == :$DPORT )'" 2>/dev/null || true)"
      fi
      # 혹시 위가 비면 폴백: dst만 → 무필터
      if [[ -z "$RAW" ]]; then
        RAW="$(kubectl exec "$POD_NAME" -n "$POD_NS" -- sh -lc "ss -i dst $SERVER_IP" 2>/dev/null || true)"
      fi
      if [[ -z "$RAW" ]]; then
        RAW="$(kubectl exec "$POD_NAME" -n "$POD_NS" -- sh -lc "ss -i" 2>/dev/null || true)"
      fi

      # 멀티라인을 한 블록으로
      BLK="$(echo "$RAW" | awk '/^[A-Za-z]/{if(b){print b}; b=$0; next} {b=b" "$0} END{if(b)print b}' \
              | awk -v ctrl=":$NETPERF_PORT" '/ESTAB/ && /data_segs_out:/ && $0 !~ ctrl {print; exit}')"
      [[ -z "$BLK" ]] && BLK="$(echo "$RAW" | awk '/^[A-Za-z]/{if(b){print b}; b=$0; next} {b=b" "$0} END{if(b)print b}' \
              | awk -v ctrl=":$NETPERF_PORT" '/ESTAB/ && $0 !~ ctrl {print; exit}')"
      [[ -z "$BLK" ]] && BLK="$(echo "$RAW" | awk '/^[A-Za-z]/{if(b){print b}; b=$0; next} {b=b" "$0} END{if(b)print b}' | head -1)"

      PR=""
      DR=""
      if [[ -n "$BLK" ]]; then
        echo "$TS_MS,$BLK" >> "$RAW_SS"
      fi
      if [[ -n "$BLK" ]] && grep -q "bytes_acked:" <<<"$BLK"; then
        SENDQ=$(awk '{print $4}' <<<"$BLK")
        WSCALE=$(grep -o "wscale:[^ ]*"       <<<"$BLK" | head -1 | num)
        RTO=$(   grep -o "rto:[^ ]*"          <<<"$BLK" | head -1 | num)
        RTT=$(   grep -o "rtt:[^ ]*"          <<<"$BLK" | head -1 | cut -d/ -f1 | num)
        CWND=$(  grep -o "cwnd:[^ ]*"         <<<"$BLK" | head -1 | num)
        SSTHRESH=$(grep -o "ssthresh:[^ ]*"   <<<"$BLK" | head -1 | num)

        BS=$(   grep -o "bytes_sent:[^ ]*"    <<<"$BLK" | head -1 | num)
        BR=$(   grep -o "bytes_retrans:[^ ]*" <<<"$BLK" | head -1 | num)
        BA=$(   grep -o "bytes_acked:[^ ]*"   <<<"$BLK" | head -1 | num)
        SO=$(   grep -o "segs_out:[^ ]*"      <<<"$BLK" | head -1 | num)
        SI=$(   grep -o "segs_in:[^ ]*"       <<<"$BLK" | head -1 | num)
        DSO=$(  grep -o "data_segs_out:[^ ]*" <<<"$BLK" | head -1 | num)
        PR=$(awk '{for(i=1;i<=NF;i++) if($i=="pacing_rate"){print $(i+1); exit}}' <<<"$BLK" \
                | sed -E 's/,/./; s/[GMK]bps$//')
      
        DR=$(awk '{for(i=1;i<=NF;i++) if($i=="delivery_rate"){print $(i+1); exit}}' <<<"$BLK" \
                | sed -E 's/,/./; s/[GMK]bps$//')
        DELIV=$(grep -o "delivered:[^ ]*"     <<<"$BLK" | head -1 | num)

        if [[ "$BLK" =~ app_limited ]]; then APP=1; else APP=0; fi
        UNACKED=$(grep -o "unacked:[^ ]*"     <<<"$BLK" | head -1 | num)
        RETRANS=$(grep -o "retrans:[^ ]*"     <<<"$BLK" | head -1 | num | cut -d'/' -f1)
        LASTRCV=$(grep -o "lastrcv:[^ ]*"     <<<"$BLK" | head -1 | num)

        echo "$TS_MS,$SENDQ,$WSCALE,$RTO,$RTT,$CWND,$SSTHRESH,$BS,$BR,$BA,$SO,$SI,$DSO,$PR,$DR,$DELIV,$APP,$UNACKED,$RETRANS,$LASTRCV" >> "$SS_CSV"
      else
        echo "$TS_MS,,,,,,,,,,,,,,,,,," >> "$SS_CSV"
      fi

      sleep 1
    done  
  done
) &
SS_BG=$!

# ===== 10초 주기 × 10회 =====
for k in $(seq 1 10); do
  kubectl exec "$POD_NAME" -n "$POD_NS" -- \
    sh -lc "vnstat -tr 10" | awk '/tx/ {print strftime("%s"),$0}' >> "$OUTDIR/vnstat.txt" &
  sshpass -p 0000 ssh -o StrictHostKeyChecking=no rpi2@192.168.0.42 \
    "pidstat -G netperf 1 10" >> "$OUTDIR/pidstat_netperf.txt" &
  kubectl exec "$POD_NAME" -n "$POD_NS" -- \
    sh -lc "mpstat -P ALL 10 1" | awk '/Average/ {print strftime("%s"),$0}' >> "$OUTDIR/mpstat_cpu.txt"
  sleep 3
done

wait "$SS_BG" || true
wait "$NP_BG" || true
