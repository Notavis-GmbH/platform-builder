#!/bin/bash
# Pin the rp1-cfe (CSI/camera capture) interrupts to the same CPU cores
# reserved for the camera container (see cpuset in app_platform/docker-compose.yml),
# so IRQ handling isn't delayed behind unrelated work on other cores.
set -euo pipefail

CORES="2,3"

irqs=$(awk -F: '/rp1-cfe/ {gsub(/^ +/, "", $1); print $1}' /proc/interrupts)

if [ -z "$irqs" ]; then
	echo "No rp1-cfe interrupts found, nothing to pin." >&2
	exit 0
fi

for irq in $irqs; do
	echo "Pinning IRQ $irq (rp1-cfe) to CPUs $CORES"
	echo "$CORES" > "/proc/irq/$irq/smp_affinity_list"
done
