echo "== ACPI power meter devices (ACPI000D)"
for d in /sys/bus/acpi/devices/ACPI000D:*; do
  [ -e "$d" ] || continue
  h=$(ls -d $d/physical_node/hwmon/hwmon* 2>/dev/null | head -1; ls -d /sys/class/hwmon/*/device 2>/dev/null | while read x; do [ "$(readlink -f $x)" = "$(readlink -f $d/physical_node 2>/dev/null)" ] && dirname $x; done | head -1)
  echo "$(basename $d) path=$(cat $d/path 2>/dev/null) uid=$(cat $d/uid 2>/dev/null)"
done | head -24
echo "== hwmon meters: oem_info | model | interval | accuracy | is_battery | cap"
for h in /sys/class/hwmon/hwmon*; do i=$(cat $h/power1_oem_info 2>/dev/null) || continue; [ -n "$i" ] || continue
  dev=$(readlink -f $h/device); echo "$(basename $h) [$i] model=$(cat $h/power1_model_number 2>/dev/null) acc=$(cat $h/power1_accuracy 2>/dev/null) int=$(cat $h/power1_average_interval 2>/dev/null)ms cap=$(cat $h/power1_cap 2>/dev/null) acpi=$(cat $dev/firmware_node/path 2>/dev/null)"; done
echo "== strings near the meter names in the ACPI tables"
for t in /sys/firmware/acpi/tables/DSDT /sys/firmware/acpi/tables/SSDT*; do
  sudo strings -n 4 $t 2>/dev/null | grep -n -iE "power socket|ap power|total power|rail power|dram power|module|PMD|_PMC|meter" | sed "s|^|$(basename $t): |" | head -15
done
which iasl acpidump 2>&1 | head -2
