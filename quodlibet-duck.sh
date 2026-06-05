#!/usr/bin/env bash
# Audio ducking for Quod Libet: lowers volume when a browser starts playing audio,
# restores it when the browser stops.
#
# Dependencies: bash, pactl (pipewire-pulse or pulseaudio), bc
#
# Usage: ./quodlibet-duck.sh [--daemonize]

set -euo pipefail

# --- Configuration ---
QUODLIBET_MATCH="Quod Libet"
BROWSER_MATCHES=("Firefox" "Librewolf" "LibreWolf" "Brave" "brave" "Chromium" "chrome")
FADE_DURATION=1.0
FADE_STEPS=30
DUCK_LEVEL=5
POLL_INTERVAL=0.3

QUODLIBET_SINK=""
ORIGINAL_VOLUME=""
DUCKED=false

get_quodlibet_sink() {
  pactl list sink-inputs 2>/dev/null | awk '
    /Sink Input #[0-9]+/ {
      match($3, /[0-9]+/)
      id = substr($3, RSTART, RLENGTH)
    }
    /application.name = / {
      gsub(/^[[:space:]]*application.name = "/, "", $0)
      gsub(/"$/, "", $0)
      if (tolower($0) ~ tolower("'"$QUODLIBET_MATCH"'")) { print id; exit }
    }
  '
}

get_active_browser_sinks() {
  local pattern
  pattern=$(
    IFS="|"
    echo "${BROWSER_MATCHES[*]}"
  )
  pactl list sink-inputs 2>/dev/null | awk -v pattern="$pattern" '
    /Sink Input #[0-9]+/ {
      match($3, /[0-9]+/)
      id = substr($3, RSTART, RLENGTH)
      corked[id] = "unknown"
      app[id] = ""
    }
    /Corked: (yes|no)/ { corked[id] = $2 }
    /application.name = / {
      gsub(/^[[:space:]]*application.name = "/, "", $0)
      gsub(/"$/, "", $0)
      app[id] = $0
    }
    END {
      for (id in app) {
        if (app[id] != "" && tolower(app[id]) ~ tolower(pattern) && corked[id] != "yes")
          print id
      }
    }
  ' | sort -u
}

get_volume_percent() {
  local id=$1
  pactl list sink-inputs 2>/dev/null | awk -v id="$id" '
    /Sink Input #'"$id"'/ {found=1; next}
    found && /Volume:/ {
      match($0, /[0-9]+%/, a)
      gsub(/%/, "", a[0])
      print a[0]
      exit
    }
  '
}

fade_to() {
  local id=$1
  local target=$2
  local current
  current=$(get_volume_percent "$id") || return 1
  [[ -z "$current" ]] && return 1
  current=$(echo "$current" | cut -d. -f1)

  for ((i = 1; i <= FADE_STEPS; i++)); do
    local pct
    pct=$(bc -l <<<"scale=2; $current + ($target - $current) * $i / $FADE_STEPS")
    pactl set-sink-input-volume "$id" "${pct}%" 2>/dev/null || true
    sleep "$(bc -l <<<"$FADE_DURATION / $FADE_STEPS")"
  done
  pactl set-sink-input-volume "$id" "${target}%" 2>/dev/null || true
}

monitor() {
  echo "quodlibet-duck: monitoring started (PID $$)"
  echo "  Fade duration: ${FADE_DURATION}s"
  echo "  Duck level: ${DUCK_LEVEL}%"
  echo "  Monitored browsers: ${BROWSER_MATCHES[*]}"

  while true; do
    QUODLIBET_SINK=$(get_quodlibet_sink)

    if [[ -z "$QUODLIBET_SINK" ]]; then
      if [[ "$DUCKED" == true ]]; then
        DUCKED=false
      fi
      sleep "$POLL_INTERVAL"
      continue
    fi

    browser_sinks=($(get_active_browser_sinks))

    if [[ ${#browser_sinks[@]} -gt 0 ]] && [[ "$DUCKED" == false ]]; then
      ORIGINAL_VOLUME=$(get_volume_percent "$QUODLIBET_SINK")
      echo "  Browser audio detected, ducking Quod Libet ${ORIGINAL_VOLUME}% -> ${DUCK_LEVEL}%"
      fade_to "$QUODLIBET_SINK" "$DUCK_LEVEL"
      DUCKED=true
    elif [[ ${#browser_sinks[@]} -eq 0 ]] && [[ "$DUCKED" == true ]]; then
      local restore_to="${ORIGINAL_VOLUME:-100}"
      echo "  Browser audio stopped, restoring Quod Libet ${DUCK_LEVEL}% -> ${restore_to}%"
      fade_to "$QUODLIBET_SINK" "$restore_to"
      DUCKED=false
      ORIGINAL_VOLUME=""
    fi

    sleep "$POLL_INTERVAL"
  done
}

case "${1:-}" in
--daemonize | -d)
  nohup "$0" >/dev/null 2>&1 &
  echo "quodlibet-duck: started in background (PID $!)"
  ;;
--help | -h)
  echo "Usage: $0 [--daemonize]"
  echo "  --daemonize, -d   Run in background"
  echo "  --help, -h        Show this help"
  ;;
"")
  monitor
  ;;
*)
  echo "Unknown option: $1"
  exit 1
  ;;
esac
