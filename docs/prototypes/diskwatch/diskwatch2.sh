#!/bin/sh
# read-only observer, no root. Logs disk counters on change; when a data HDD partition (sd[a-c]4) changes,
# also logs processes that burned CPU or sat in D-state in the preceding ~3s window. Output in tmpfs.
out=/tmp/diskwatch2.log
: > $out
snap() { awk 'BEGIN{FS=") "} {pid=$1; sub(/ .*/,"",pid); comm=$1; sub(/^[^(]*\(/,"",comm); split($2,b," "); print pid "\t" comm "\t" b[1] "\t" (b[12]+b[13])}' /proc/[0-9]*/stat 2>/dev/null; }
snap > /tmp/dw_prev
prev=""; prevhdd=""
end=$(( $(date +%s) + 1800 ))
while [ $(date +%s) -lt $end ]; do
  sleep 3
  cur=$(awk '$3 ~ /^(sd[a-d]|sd[a-d][24]|md[012])$/ {printf "%s:%s/%s ", $3, $4, $8}' /proc/diskstats)
  hdd=$(awk '$3 ~ /^sd[a-c]4$/ {printf "%s/%s ", $4, $8}' /proc/diskstats)
  snap > /tmp/dw_cur
  if [ "$cur" != "$prev" ]; then echo "$(date +%H:%M:%S) $cur" >> $out; prev="$cur"; fi
  if [ "$hdd" != "$prevhdd" ]; then
    echo "$(date +%H:%M:%S) HDD-ACTIVITY candidates:" >> $out
    awk -F'\t' 'NR==FNR{t[$1]=$4; next} (($1 in t) && $4>t[$1]) {print "   cpu+" ($4-t[$1]) " " $2 " (pid " $1 ")"} $3=="D" {print "   D-state " $2 " (pid " $1 ")"}' /tmp/dw_prev /tmp/dw_cur >> $out
    prevhdd="$hdd"
  fi
  mv /tmp/dw_cur /tmp/dw_prev
done
echo "DONE $(date +%H:%M:%S)" >> $out
