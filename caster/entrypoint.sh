#!/usr/bin/env bash
# Render the WeatherStar 4000+ kiosk page on a virtual display and publish it
# as a 24/7 video channel.
#
#   Xvfb :99  ->  Chromium (kiosk)  ->  ffmpeg x11grab  ->  libx264 ----\
#                                                                        tee -> RTSP to MediaMTX
#   /music/**/*.mp3 -> concat playlist -> ffmpeg -> aac    -------------/    \-> MPEG-TS multicast
#
# Adapted from FlightTrackerDisplay/caster/entrypoint.sh. What is different:
#
#   * Audio is real. The radar caster ships a silent track; this channel plays
#     the WeatherStar music. Rather than capturing the browser's audio (which
#     needs a PulseAudio server inside the container) ffmpeg plays the mp3
#     folder itself. Kiosk mode hides the toolbar and track name, so nothing
#     on screen can fall out of sync with what is heard.
#   * 4:2:0 and limited (TV) range by default. The radar is 1px green strokes
#     and gains from yuv444p/full range; the weather display is photographic
#     backgrounds and large type, and the IPTV targets (set-top boxes, Apple TV
#     apps) are far happier with plain High-profile 4:2:0 at TV range.
#   * The page URL is built from a ZIP code so one env var defines the channel.

set -uo pipefail

WIDTH="${WIDTH:-1920}"
HEIGHT="${HEIGHT:-1080}"
FRAMERATE="${FRAMERATE:-30}"
DISPLAY_NUM="${DISPLAY:-:99}"

log() { echo "[caster] $*"; }

# ---------------------------------------------------------------- channel URL
# Either hand the caster a complete PAGE_URL, or let it build one:
#
#   WEB_URL        where the ws4kp web container answers (host networking, so
#                  localhost rather than a compose DNS name)
#   CHANNEL_ZIP    the location. Any string the app's search box accepts works
#                  (a ZIP, "Tuscaloosa, AL", an airport), ZIP is just the
#                  simplest.
#   CHANNEL_LATLON optional "lat,lon". When present the page skips the ArcGIS
#                  geocoder on every load/reload and goes straight to the
#                  forecast. Strongly recommended for a 24/7 channel so a
#                  geocoder outage cannot blank the stream after a reload.
#   CHANNEL_QUERY  optional extra permalink parameters to append, e.g.
#                  "travel-checkbox=true&settings-units-select=us".
#                  Use the app's "Copy Permalink" button to discover them.
WEB_URL="${WEB_URL:-http://localhost:8080/}"
CHANNEL_ZIP="${CHANNEL_ZIP:-}"
CHANNEL_LATLON="${CHANNEL_LATLON:-}"
CHANNEL_QUERY="${CHANNEL_QUERY:-}"

urlencode() {
  local s="$1" out="" c
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) out+=$(printf '%%%02X' "'$c") ;;
    esac
  done
  printf '%s' "$out"
}

if [[ -z "${PAGE_URL:-}" ]]; then
  if [[ -z "${CHANNEL_ZIP}" ]]; then
    log "FATAL: set CHANNEL_ZIP (or a full PAGE_URL)"
    exit 1
  fi
  QS="latLonQuery=$(urlencode "${CHANNEL_ZIP}")"
  if [[ -n "${CHANNEL_LATLON}" ]]; then
    LAT="${CHANNEL_LATLON%%,*}"
    LON="${CHANNEL_LATLON##*,}"
    QS+="&latLon=$(urlencode "{\"lat\":${LAT},\"lon\":${LON}}")"
  fi
  # kiosk=true hides every control and auto-plays the slideshow. The page's own
  # music stays off (mediaPlaying is a sticky setting that defaults to false):
  # audio comes from ffmpeg below, so Chromium has nothing to decode.
  QS+="&kiosk=true"
  [[ -n "${CHANNEL_QUERY}" ]] && QS+="&${CHANNEL_QUERY#&}"
  PAGE_URL="${WEB_URL%%\?*}?${QS}"
fi
log "channel page: ${PAGE_URL}"

# ---------------------------------------------------------------- video quality
# PIX_FMT: yuv420p is what every hardware decoder plays. yuv444p (the radar
#   default) keeps full chroma but needs the High 4:4:4 profile, which many
#   set-top boxes refuse. Switch only if you are watching on VLC/mpv/browsers.
PIX_FMT="${PIX_FMT:-yuv420p}"

# CRF: lower is better quality. 18 is near-lossless for this content; the
#   mostly-static picture means the average bitrate sits well under the cap.
CRF="${CRF:-18}"

# Ceiling for the rate so a full-screen change cannot spike the network.
VIDEO_BITRATE="${VIDEO_BITRATE:-8000k}"
BUFSIZE="${BUFSIZE:-16000k}"

# Encoder effort. `slow` is affordable on a near-static page.
PRESET="${PRESET:-slow}"

# B-frames must stay off for WebRTC readers on MediaMTX ("WebRTC doesn't
# support H264 streams with B-frames"). `-preset slow` turns them on, hence the
# explicit override. Set WEBRTC_COMPAT=0 to reclaim ~15-20% bitrate if you never
# watch over WebRTC.
WEBRTC_COMPAT="${WEBRTC_COMPAT:-1}"
if [[ "${WEBRTC_COMPAT}" == "1" ]]; then
  X264_EXTRA=":bframes=0"
else
  X264_EXTRA=""
fi

# Browser zoom. The WeatherStar display is a 640x480 stage the kiosk CSS scales
# to the viewport, so at 1080p the browser is already upscaling. DEVICE_SCALE=2
# at 3840x2160 renders text and strokes at native density instead.
DEVICE_SCALE="${DEVICE_SCALE:-1}"

# Output colour range. `limited` (16-235) is broadcast/TV range and what IPTV
# decoders expect; `full` (0-255) is what x11grab captures. Either way the
# stream is tagged explicitly so players do not guess. Set OUT_RANGE=full if
# blacks look lifted on a PC player.
OUT_RANGE="${OUT_RANGE:-limited}"
case "${OUT_RANGE}" in
  full)    X264_RANGE=pc ;;
  limited) X264_RANGE=tv ;;
  *)
    log "FATAL: OUT_RANGE must be 'full' or 'limited', got '${OUT_RANGE}'"
    exit 1
    ;;
esac

# ---------------------------------------------------------------- audio
# MUSIC_DIR: searched recursively for *.mp3. The image bakes in server/music,
#   which holds one subfolder per playlist (default, christmas, ...). Point this
#   at the folder for the season; pointing it at /music itself plays everything
#   mixed together. Mount your own folder over /music to replace the library.
# MUSIC_VOLUME: linear gain on the music, 1.0 = unchanged.
# MUSIC_SHUFFLE: 1 reshuffles the folder on each pass, 0 plays alphabetically.
# MUSIC=0 disables music and sends a silent track instead (some decoders and
#   MediaMTX's RTMP output still want an audio stream to exist).
MUSIC="${MUSIC:-1}"
MUSIC_DIR="${MUSIC_DIR:-/music/default}"
MUSIC_VOLUME="${MUSIC_VOLUME:-1.0}"
MUSIC_SHUFFLE="${MUSIC_SHUFFLE:-1}"
# How many passes through the folder to write into the playlist. ffmpeg's
# concat demuxer plays the list once and then the audio simply ends while video
# carries on, so the list is made long enough to outlive any ffmpeg process
# (with ~15 tracks this is weeks of audio). The encode loop below restarts
# ffmpeg, and therefore the playlist, if it ever does run out.
MUSIC_PASSES="${MUSIC_PASSES:-1000}"
PLAYLIST=/tmp/playlist.txt

build_playlist() {
  local tracks
  mapfile -t tracks < <(find "${MUSIC_DIR}" -type f -iname '*.mp3' 2>/dev/null | sort)
  if [[ ${#tracks[@]} -eq 0 ]]; then
    return 1
  fi
  : > "${PLAYLIST}"
  local pass line
  for (( pass = 0; pass < MUSIC_PASSES; pass++ )); do
    if [[ "${MUSIC_SHUFFLE}" == "1" ]]; then
      printf '%s\n' "${tracks[@]}" | shuf
    else
      printf '%s\n' "${tracks[@]}"
    fi | while IFS= read -r line; do
      # concat demuxer syntax: file 'path', with single quotes escaped as '\''
      printf "file '%s'\n" "${line//\'/\'\\\'\'}"
    done >> "${PLAYLIST}"
  done
  log "music: ${#tracks[@]} tracks from ${MUSIC_DIR}, ${MUSIC_PASSES} passes, shuffle=${MUSIC_SHUFFLE}"
  return 0
}

AUDIO_INPUT=()
AUDIO_FILTER=()
if [[ "${MUSIC}" == "1" ]] && build_playlist; then
  # -re paces the file input at real time so it stays in step with the live
  # x11grab video; without it ffmpeg would read audio as fast as the muxer
  # lets it. aresample async=1 papers over the sub-second timestamp gaps
  # between tracks (header duration vs. real length).
  #
  # Do NOT add first_pts=0 here. A library with mixed sample rates (this one
  # has 48k, 44.1k and 11.025k files) makes ffmpeg rebuild the audio filter
  # graph at every rate change, and a freshly built aresample with first_pts=0
  # pads silence from t=0 up to the current position -- minutes of dead air
  # at each such track boundary, then music again. Reproduced and fixed
  # 2026-11-07; see the git history of this line.
  AUDIO_INPUT=(-re -f concat -safe 0 -i "${PLAYLIST}")
  AUDIO_FILTER=(-af "aresample=44100:async=1,aformat=sample_fmts=fltp:channel_layouts=stereo,volume=${MUSIC_VOLUME}")
else
  [[ "${MUSIC}" == "1" ]] && log "music: no mp3 files found under ${MUSIC_DIR}; sending silence"
  AUDIO_INPUT=(-f lavfi -i anullsrc=channel_layout=stereo:sample_rate=44100)
fi

# ---------------------------------------------------------------- watchdog
# A browser that is alive but no longer painting is the failure this guards:
# x11grab keeps capturing the same stale framebuffer and ffmpeg keeps encoding
# it, so the stream "works" while showing a frozen forecast.
#
# The page publishes an incrementing counter in its document title while in
# kiosk mode (see server/scripts/index.mjs, startCasterBeacon). It advances
# from requestAnimationFrame, so a title that stops changing means the page is
# no longer painting, and the fix is to reload it.
WATCHDOG_INTERVAL="${WATCHDOG_INTERVAL:-30}"
WATCHDOG_STRIKES="${WATCHDOG_STRIKES:-2}"

# Preventive reload. A browser session that runs for weeks accumulates;
# reloading on a schedule keeps the heap young at the cost of a second of
# stale frame. Set 0 to disable and rely on the watchdog alone.
RECYCLE_INTERVAL="${RECYCLE_INTERVAL:-21600}"

MEDIAMTX_HOST="${MEDIAMTX_HOST:-}"
MEDIAMTX_PATH="${MEDIAMTX_PATH:-weather}"
MULTICAST_ADDR="${MULTICAST_ADDR:-}"
MULTICAST_PORT="${MULTICAST_PORT:-5004}"
MULTICAST_TTL="${MULTICAST_TTL:-4}"

cleanup() {
  log "shutting down"
  [[ -n "${WATCHDOG_PID:-}" ]] && kill "$WATCHDOG_PID" 2>/dev/null
  [[ -n "${FFMPEG_PID:-}" ]] && kill "$FFMPEG_PID" 2>/dev/null
  [[ -n "${CHROME_PID:-}" ]] && kill "$CHROME_PID" 2>/dev/null
  [[ -n "${XVFB_PID:-}"   ]] && kill "$XVFB_PID"   2>/dev/null
  exit 0
}
trap cleanup SIGTERM SIGINT

# ---------------------------------------------------------------- virtual display
log "starting Xvfb on ${DISPLAY_NUM} at ${WIDTH}x${HEIGHT}"
Xvfb "${DISPLAY_NUM}" -screen 0 "${WIDTH}x${HEIGHT}x24" -nolisten tcp &
XVFB_PID=$!

for _ in $(seq 1 40); do
  xdpyinfo -display "${DISPLAY_NUM}" >/dev/null 2>&1 && break
  sleep 0.25
done
if ! xdpyinfo -display "${DISPLAY_NUM}" >/dev/null 2>&1; then
  log "FATAL: Xvfb did not come up"
  exit 1
fi

# Xvfb draws a root pointer and x11grab composites it in. `-draw_mouse 0` on the
# grab is the real fix; parking it in the corner covers anything that ignores
# that flag.
if command -v xdotool >/dev/null 2>&1; then
  DISPLAY="${DISPLAY_NUM}" xdotool mousemove "$((WIDTH - 1))" "$((HEIGHT - 1))" 2>/dev/null \
    && log "pointer parked off the display"
fi

# ---------------------------------------------------------------- wait for the page
PAGE_HOST_URL="${PAGE_URL%%\?*}"
log "waiting for ${PAGE_HOST_URL}"
for _ in $(seq 1 60); do
  if wget -q --spider "${PAGE_HOST_URL}" 2>/dev/null; then
    log "page is up"
    break
  fi
  sleep 2
done

# ---------------------------------------------------------------- browser
# Fresh profile every start so a cached index.html cannot keep pointing at a
# previous build's hashed bundles after the web image updates.
PROFILE_DIR=/tmp/chrome-profile
rm -rf "${PROFILE_DIR}"
mkdir -p "${PROFILE_DIR}"

if [[ "${PAGE_URL}" == *\?* ]]; then
  CACHE_BUSTED_URL="${PAGE_URL}&_cb=$(date +%s)"
else
  CACHE_BUSTED_URL="${PAGE_URL}?_cb=$(date +%s)"
fi

log "launching chromium"
chromium \
  --no-sandbox \
  --disable-gpu \
  --disable-dev-shm-usage \
  --disable-software-rasterizer \
  --kiosk \
  --start-fullscreen \
  --window-size="${WIDTH},${HEIGHT}" \
  --window-position=0,0 \
  --force-device-scale-factor="${DEVICE_SCALE}" \
  --hide-scrollbars \
  --noerrdialogs \
  --disable-infobars \
  --disable-session-crashed-bubble \
  --disable-features=Translate,MediaRouter \
  --autoplay-policy=no-user-gesture-required \
  --mute-audio \
  --check-for-update-interval=31536000 \
  --user-data-dir="${PROFILE_DIR}" \
  --disk-cache-dir=/dev/null \
  --disk-cache-size=1 \
  --media-cache-size=1 \
  --aggressive-cache-discard \
  "${CACHE_BUSTED_URL}" >/tmp/chromium.log 2>&1 &
CHROME_PID=$!

# Give the page time to load its data, geocode (if no CHANNEL_LATLON) and paint
# the first forecast slide, so the stream never opens on the loading screen.
sleep 15

# ---------------------------------------------------------------- page watchdog
# Reloading is a keystroke (F5) to the existing window rather than a Chromium
# restart, so x11grab never loses its capture target and the stream continues.
page_title() {
  DISPLAY="${DISPLAY_NUM}" xdotool search --onlyvisible --class chromium 2>/dev/null \
    | head -1 | xargs -r -I{} xdotool getwindowname {} 2>/dev/null
}

reload_page() {
  local win
  win=$(DISPLAY="${DISPLAY_NUM}" xdotool search --onlyvisible --class chromium 2>/dev/null | head -1)
  if [[ -z "${win}" ]]; then
    log "watchdog: no chromium window found; cannot reload"
    return 1
  fi
  DISPLAY="${DISPLAY_NUM}" xdotool key --window "${win}" F5 2>/dev/null
}

watchdog_loop() {
  local last_title="" strikes=0 elapsed=0 title

  if ! command -v xdotool >/dev/null 2>&1; then
    log "watchdog: xdotool missing; freeze detection disabled, recycle only"
  fi

  while true; do
    sleep "${WATCHDOG_INTERVAL}"
    elapsed=$((elapsed + WATCHDOG_INTERVAL))

    if [[ "${RECYCLE_INTERVAL}" != "0" && ${elapsed} -ge ${RECYCLE_INTERVAL} ]]; then
      log "watchdog: scheduled recycle after ${elapsed}s"
      reload_page && elapsed=0 && strikes=0 && last_title=""
      continue
    fi

    command -v xdotool >/dev/null 2>&1 || continue

    title=$(page_title)
    # Empty title: window not up yet or mid-reload. Inconclusive, not a freeze.
    if [[ -z "${title}" ]]; then
      continue
    fi

    if [[ "${title}" == "${last_title}" ]]; then
      strikes=$((strikes + 1))
      log "watchdog: page appears frozen (${strikes}/${WATCHDOG_STRIKES}) title='${title}'"
      if [[ ${strikes} -ge ${WATCHDOG_STRIKES} ]]; then
        log "watchdog: reloading frozen page"
        reload_page
        strikes=0
        last_title=""
        elapsed=0
      fi
    else
      strikes=0
      last_title="${title}"
    fi
  done
}

watchdog_loop &
WATCHDOG_PID=$!
log "watchdog started (check ${WATCHDOG_INTERVAL}s, recycle ${RECYCLE_INTERVAL}s)"

# ---------------------------------------------------------------- outputs
# One encode, tee'd to whichever destinations are configured.
OUTPUTS=()
if [[ -n "${MEDIAMTX_HOST}" ]]; then
  OUTPUTS+=("[f=rtsp:rtsp_transport=tcp]rtsp://${MEDIAMTX_HOST}:8554/${MEDIAMTX_PATH}")
  log "output: rtsp://${MEDIAMTX_HOST}:8554/${MEDIAMTX_PATH}"
fi
if [[ -n "${MULTICAST_ADDR}" ]]; then
  OUTPUTS+=("[f=mpegts]udp://${MULTICAST_ADDR}:${MULTICAST_PORT}?pkt_size=1316&ttl=${MULTICAST_TTL}")
  log "output: udp://${MULTICAST_ADDR}:${MULTICAST_PORT}"
fi

if [[ ${#OUTPUTS[@]} -eq 0 ]]; then
  log "FATAL: neither MEDIAMTX_HOST nor MULTICAST_ADDR is set"
  exit 1
fi

TEE_TARGET=$(IFS='|'; echo "${OUTPUTS[*]}")

# ---------------------------------------------------------------- encode loop
# ffmpeg is supervised: if MediaMTX restarts or the network blips, the encode
# dies and must come straight back.
while true; do
  log "starting ffmpeg (${PIX_FMT}, ${OUT_RANGE} range, crf ${CRF}, preset ${PRESET})"

  # x11grab captures full-range RGB; the scale filter converts to the chosen
  # range explicitly and the -color_* flags tag the H.264 bitstream itself, so
  # the raw MPEG-TS multicast (which has no container metadata) still tells
  # players the truth.
  ffmpeg -hide_banner -loglevel warning \
    -f x11grab -draw_mouse 0 -framerate "${FRAMERATE}" -video_size "${WIDTH}x${HEIGHT}" -i "${DISPLAY_NUM}" \
    "${AUDIO_INPUT[@]}" \
    -vf "scale=in_range=full:out_range=${OUT_RANGE}:flags=lanczos+accurate_rnd" \
    "${AUDIO_FILTER[@]}" \
    -c:v libx264 -preset "${PRESET}" -tune stillimage -pix_fmt "${PIX_FMT}" \
    -crf "${CRF}" -maxrate "${VIDEO_BITRATE}" -bufsize "${BUFSIZE}" \
    -color_range "${X264_RANGE}" -colorspace bt709 \
    -color_primaries bt709 -color_trc bt709 \
    -x264-params "aq-mode=3:psy-rd=0.6${X264_EXTRA}" \
    -g $((FRAMERATE * 2)) -keyint_min "${FRAMERATE}" -sc_threshold 0 \
    -c:a aac -b:a 128k -ar 44100 \
    -map 0:v -map 1:a \
    -f tee "${TEE_TARGET}" &
  FFMPEG_PID=$!
  wait "$FFMPEG_PID"

  # No browser, nothing to capture: exit and let Docker's restart policy
  # rebuild the whole pipeline rather than encoding a black frame.
  if ! kill -0 "$CHROME_PID" 2>/dev/null; then
    log "chromium exited; restarting container"
    cleanup
  fi

  log "ffmpeg exited; retrying in 5s"
  sleep 5
done
