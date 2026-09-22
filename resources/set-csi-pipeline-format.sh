#!/bin/bash
# Align the CSI-2 media pipeline pad formats with the sensor before the camera
# container starts.
#
# Background: the RP1 CFE derives the number of bytes it consumes per line from
# the media bus format on the csi2 pads. If a pad is left on a format that does
# not match what the sensor sends (observed: csi2 source pad on Y16_1X16 while
# the sensor sends Y10_1X10), the CFE misreads the line length and the captured
# frame is torn into displaced line groups. That state survives container
# restarts, so it has to be corrected before streaming starts.
#
# The script reads the sensor pad format and applies exactly that format to the
# csi2 sink and source pads, so it adapts to sensor, resolution and bit depth
# without hardcoding them.
set -euo pipefail

CSI_DRIVER="rp1-cfe"
SENSOR_MATCH="vc_mipi_camera"
FALLBACK_FMT="Y10_1X10/2592x1944"
WAIT_SECONDS="${CSI_WAIT_SECONDS:-15}"

log() { echo "[csi-pipeline-format] $*"; }

if ! command -v media-ctl >/dev/null 2>&1; then
	log "media-ctl not available, nothing to do."
	exit 0
fi

# The media node number is not stable across devices and boots.
find_media_node() {
	local m
	for m in /dev/media*; do
		[ -e "$m" ] || continue
		if media-ctl -d "$m" -p 2>/dev/null | grep -q "$CSI_DRIVER"; then
			echo "$m"
			return 0
		fi
	done
	return 1
}

MEDIA=""
for _ in $(seq 1 "$WAIT_SECONDS"); do
	if MEDIA=$(find_media_node); then
		break
	fi
	sleep 1
done

if [ -z "$MEDIA" ]; then
	log "No $CSI_DRIVER media device found after ${WAIT_SECONDS}s, nothing to do."
	exit 0
fi
log "Using media device $MEDIA"

TOPOLOGY=$(media-ctl -d "$MEDIA" -p 2>/dev/null || true)

SENSOR=$(echo "$TOPOLOGY" | grep -oE "${SENSOR_MATCH} [0-9]+-[0-9a-f]+" | head -1 || true)
if [ -z "$SENSOR" ]; then
	log "No $SENSOR_MATCH entity found on $MEDIA, nothing to do."
	exit 0
fi
log "Sensor entity: $SENSOR"

# Format of the sensor source pad is the reference for the whole link.
FMT=$(media-ctl -d "$MEDIA" --get-v4l2 "\"${SENSOR}\":0" 2>/dev/null |
	grep -oE 'fmt:[A-Z0-9_]+/[0-9]+x[0-9]+' | head -1 | cut -d: -f2 || true)

if [ -z "$FMT" ]; then
	FMT="$FALLBACK_FMT"
	log "Could not read sensor pad format, falling back to $FMT"
else
	log "Sensor pad format: $FMT"
fi

rc=0
for pad in '"'"${SENSOR}"'":0' '"csi2":0' '"csi2":4'; do
	if media-ctl -d "$MEDIA" -V "${pad} [fmt:${FMT}]" 2>/dev/null; then
		log "Set ${pad} to ${FMT}"
	else
		# Fails while the pipeline is streaming; that is worth reporting but
		# must not keep the platform from starting.
		log "WARNING: could not set ${pad} to ${FMT} (pipeline busy or format unsupported)"
		rc=1
	fi
done

log "Resulting pad formats:"
media-ctl -d "$MEDIA" -p 2>/dev/null |
	awk '/entity .*: csi2/,/entity .*: pisp-fe/' |
	grep -E 'pad0: SINK|pad4: SOURCE|fmt:' | sed 's/^/[csi-pipeline-format]   /' || true

if [ "$rc" -ne 0 ]; then
	log "Finished with warnings."
fi
exit 0
