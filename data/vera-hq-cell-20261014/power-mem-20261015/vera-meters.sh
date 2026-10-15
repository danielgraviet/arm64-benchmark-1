# read-only side logger: every Vera power meter incl. the ones power-sampler.py does not read, every 2 s
OUT=/mnt/data/bench/vera-meters-$(date -u +%Y%m%d_%H%M%S).tsv
H=""; N=""
for h in /sys/class/hwmon/hwmon*; do i=$(cat $h/power1_oem_info 2>/dev/null) || continue
  case "$i" in *"Power in uW"*|*"Energy In uJ"*) H="$H $h/power1_average"; N="$N|$i";; esac; done
echo "# t$N" | sudo tee $OUT >/dev/null
while :; do l="$(date +%s.%N | cut -c1-14)"; for f in $H; do l="$l $(sudo cat $f 2>/dev/null)"; done; echo "$l" | sudo tee -a $OUT >/dev/null; sleep 2; done
