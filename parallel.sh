#!/bin/bash

pods=("p1")
#rates=("500" "600" "300")
server_ip="192.168.0.139"
pkt=1024
vnstat_window=10
repeat=10
interval=10
remote_user="orin2"
remote_ip="192.168.0.3"
remote_pass="oslab1slab"

mkdir -p tes

for i in $(seq 1 $repeat); do
  echo "반복 $i / $repeat 시작"

  pids=()

  for idx in "${!pods[@]}"; do
    pod="${pods[$idx]}"

    (
      #echo "[$pod] 실행 시작"

      # netperf 실행
      kubectl exec -it "$pod" -- \
        netperf -H "$server_ip" -p 12865 -l 30 -- \
        -m "$pkt" >> tes/netperf_"$pod".txt &
      #netperf=$(sshpass -p 0000 ssh -o StrictHostKeyChecking=no rpi1@155.230.16.157 -p 40011 "pgrep netperf | paste -sd ',' -")

      sleep 1  # 트래픽 유발 대기

      # 성능 측정
      kubectl exec -it "$pod" -- \
        vnstat -tr "$vnstat_window" | awk '/tx/' | awk '{print $2, $4}' >> tes/vnstat_"$pod".txt &

      sshpass -p "$remote_pass" ssh -o StrictHostKeyChecking=no "$remote_user@$remote_ip" \
        "pidstat -G netperf 1 $vnstat_window" >> tes/pidstat_"$pod".txt &

      kubectl exec -it "$pod" -- \
        mpstat -P ALL "$vnstat_window" 1 | awk '/Average/' >> tes/mpstat_"$pod".txt &

      wait
      echo "✅   [$pod] 측정 완료"
    ) &
    pids+=($!)

    # <d83d><dd25> 여기서 타다닥 실행! 0.5~1초 간격
    sleep 0.5
  done

  for pid in "${pids[@]}"; do
    wait "$pid"
  done

  #echo "⏸️   ${interval}s 대기 중..."
  sleep "$interval"
done

echo "모든 측정 완료"

