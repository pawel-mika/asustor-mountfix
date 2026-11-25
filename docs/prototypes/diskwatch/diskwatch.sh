#!/bin/sh
# read-only observer: logs /proc/diskstats counters (reads/writes) whenever they change; output in tmpfs
out=/tmp/diskwatch.log
: > $out
prev=""
end=$(( $(date +%s) + 1800 ))
while [ $(date +%s) -lt $end ]; do
  cur=$(awk '$3 ~ /^(sd[a-d]|sd[a-d][24]|md[012])$/ {printf "%s:%s/%s ", $3, $4, $8}' /proc/diskstats)
  if [ "$cur" != "$prev" ]; then echo "$(date +%H:%M:%S) $cur" >> $out; prev="$cur"; fi
  sleep 5
done
echo "DONE $(date +%H:%M:%S)" >> $out
