#!/bin/bash
# Copyright Rodney Padgett - see License for details
# ChangeLog:
#  28-08-2020  Add --user-agent="" to wget - classicFM server rejects requests from wget
#  19-12-2020  Change the pid control and wait for radio stop.
#  26-03-2020  Get rid of dlBBC and download urls directly from www.radiofeeds.co.uk
#  27-03-2021  Define radio stations in bash arrays for easy update of urls
#  31-12-2021  Add status command; handle SIGINT and SIGTERM
#  04-02-2022  Improve format of bash array for presets: use just one array instead of multiple arrays for each field.
#              Change 'format' specifier for stream from playlist type to compression type; this is how radiofeeds urls are organised
#  13-02-2022  Add mpd_player(): waits for mpd to start streaming until told to stop
#              Use bash builtin wait instead of while loops
#  20-08-2022  ffplay now plays hls .m3u8 directly - add in m3u8 urls directly. Stop using radiofeeds - site not stable.
#  07-01-2023  Add FILTER_PRESET intended for equalisation purposes
#  27-10-2023  Updated BBC streams from https://gist.github.com/bpsib/67089b959e4fa898af69fea59ad74bc3, replace 96000 with 320000 for hq steams.
#  07-04-2024  Add wait_for_mpd_server() and wait_for_mpd_stream(); cleanups and bug fixes to start_player().
#  06-10-2024  Add ability to automatically add local icecast stations from the server defined by ICECAST_SERVER_JSON_URL. Requires curl and jq.
#
USER=$(id -u -n)

if [ "$USER" == "root" ]; then
   echo "Refusing to start as root."
   exit 1;
fi

RADIO_DIR="/tmp/radio-$USER"

# Apply audio filters if -f option is given
# This must be a valid ffmpeg audio filter chain (do not prepend -af or -f:a)
# These examples reduce volume to prevent clipping.
# Bass boost
#FILTER_PRESET="volume=-10dB,equalizer=f=50:width_type=h:width=50:g=10"
#
# Cambridge audio speakers room compensation for flat response 30Hz-17kHz
FILTER_PRESET="volume=-10dB,equalizer=f=90:width_type=h:width=30:g=-5,equalizer=f=60:width_type=h:width=30:g=8,equalizer=35:width_type=h:width=10:g=10"

# The function below will be used to check network connectivity to the mpd server
# before trying to connect to mpd.
# Notes
#     ping may be restricted to root on some systems; use function true to skip the check.
#     Any function should not block (use a timeout) and return non zero on error or zero on success.
#     The function will be called in a loop until it either returns zero or the rplay stop command is issued.
# Use ping:
#test_mpd_server_network() { ping -W 1 -c 1 "$1" > /dev/null 2>&1; }
# Check for a web server running on the mpd server:
test_mpd_server_network() { wget -q --connect-timeout=1 --tries=1 --spider "$1"; }
# Skip waiting for mpd:
#test_mpd_server_network() { true "$1"; }

# Radio presets:
# reference format stream description
#
#  reference: rplay preset name (used to select the preset)
#  format:
#     url:        play directly from url; stream specifies a url to a stream or playlist
#     mpd:        stream is from mpd: wait for playback to start
#  stream:
#     format is url: stream specifies the url of the stream.
#     format is mpd: stream specifies: <transport>:<server>:<port>; at present only transport=http is supported.
#  description: text description of preset (list command).
#BBC_SERVER="http://a.files.bbci.co.uk/media/live/manifesto/audio/simulcast/hls/uk/sbr_high/ak"
BBC_SERVER="http://as-hls-ww-live.akamaized.net/pool_904/live/ww/"

PRESET=( "bbc1" "url" "$BBC_SERVER/bbc_radio_one/bbc_radio_one.isml/bbc_radio_one-audio%3d320000.norewind.m3u8" "BBC Radio one" \
         "bbc2" "url" "$BBC_SERVER/bbc_radio_two/bbc_radio_two.isml/bbc_radio_two-audio%3d320000.norewind.m3u8" "BBC Radio two" \
         "bbc3" "url" "$BBC_SERVER/bbc_radio_three/bbc_radio_three.isml/bbc_radio_three-audio%3d320000.norewind.m3u8" "BBC Radio three" \
         "bbc4" "url" "$BBC_SERVER/bbc_radio_fourfm/bbc_radio_fourfm.isml/bbc_radio_fourfm-audio%3d320000.norewind.m3u8" "BBC Radio four" \
         "bbc6" "url" "$BBC_SERVER/bbc_6music/bbc_6music.isml/bbc_6music-audio%3d320000.norewind.m3u8" "BBC Radio 6music" \
         "cfm" "url" "http://icecast.thisisdax.com/ClassicFMMP3" "ClassicFM" \
         "mpd-lq" "mpd" "http://192.168.1.2:8090" "mpd server (mp3)" \
         "mpd-hq" "mpd" "http:192.168.1.2:8093" "mpd server (flac)" \
       )

# Local icecast server json status output
# The preset name is taken from the server name field.
# For example, to send output from pipewire or pulse to an icecast server can use:
# ffmpeg -f pulse -i alsa_output.usb-Focusrite_Scarlett_2i2_USB-00.analog-stereo.monitor \ # Change monitor device here
#        -ac 2 -c:a flac -f ogg \
#        -content_type 'application/ogg' -metadata artist="various" -metadata title="Monitor" \
#        -metadata album="none" -metadata year=$(date +%Y) -metadata genre="various" \
#        -ice_name "$(hostname)" -ice_description "Live stream" -ice_genre "various" -ice_url "http://$(hostname)/" \
#        icecast://source:password@server:port/$(hostname).ogg # Change icecast password and server details here
# This will create an icecast stream with same name as the hostname
# Comment the URL below if you don't use icecast
ICECAST_SERVER_JSON_URL="http://192.168.1.2:8095/status-json.xsl"

get_icecast_stations() {
   [ -z "$ICECAST_SERVER_JSON_URL" ] && return
   [ ! -e /usr/bin/jq ] && return
   [ ! -e /usr/bin/curl ] && return
   ICECAST_JSON="$(curl --silent "$ICECAST_SERVER_JSON_URL")"
   [ "$?" -ne 0 ] && return

   ICECAST_CHECK_JSON=$(echo "$ICECAST_JSON" | jq -r '.icestats.source | if type=="null" then "0" elif type=="array" then "1" else "2" end')
   case "$ICECAST_CHECK_JSON" in
      0) return ;;   # No stations
      1) echo "$ICECAST_JSON" | jq -r '.icestats.source[] | [.server_name, "url", .listenurl, "Icecast"] | @csv' ;;  # Multiple stations .source is an array
      2) echo "$ICECAST_JSON" | jq -r '.icestats.source | [.server_name, "url", .listenurl, "Icecast"] | @csv' ;; # Single station
   esac
}

list_icecast_stations() {
   ICECAST_STATIONS=$(get_icecast_stations | tr '\n' ',' | tr -d '"')
   [ -z "$ICECAST_STATIONS" ] && return
   IFS=',' read -ra ICECAST_PRESET <<< "$ICECAST_STATIONS"

   local -i r=0 f=1 s=2 d=3 n=${#ICECAST_PRESET[@]}
   while [ $r -lt $n ]; do
      printf "%s\t %s\n" "${ICECAST_PRESET[$r]}" "${ICECAST_PRESET[$d]}"
      let r+=4 f+=4 s+=4 d+=4
   done
}

list_presets() {
   local -i r=0 f=1 s=2 d=3 n=${#PRESET[@]}
   while [ $r -lt $n ]; do
      printf "%s\t %s\n" "${PRESET[$r]}" "${PRESET[$d]}"
      let r+=4 f+=4 s+=4 d+=4
   done
}

show_help() {
   echo "Play radio streams"
   echo "Requires ffmpeg (ffplay), mpc (mpd streaming control), and jq (automatic local icecast stations)"
   echo "Usage:"
   echo "   $0 stop  - stops player"
   echo "   $0 list  - list presets"
   echo "   $0 status  - show status"
   echo "   $0 [options] <preset>  - play <preset>"
   echo "Options:"
   echo "   -f apply audio filter chain defined in FILTER_PRESET"
   echo "      Current definition is:"
   [ -z "$FILTER_PRESET" ] && "Undefined." || echo "      $FILTER_PRESET"
   echo "Presets:"
   echo "<preset> description"
   list_presets
   list_icecast_stations
   echo ""
}

setup() {
   mkdir "$RADIO_DIR"
   echo "-1" > "$RADIO_DIR/pid"
}

stop_player() {
   [ -f "$RADIO_DIR/mpd_wait" ] && rm "$RADIO_DIR/mpd_wait"
   [ ! -f "$RADIO_DIR/pid" ] && return 1
   PID=$(cat "$RADIO_DIR/pid")
   [ ! "$PID" -gt 0 ] && return 0

   kill "$PID"
   [ "$?" -gt 0 ] && return 2

   ((i=0))
   WAIT_STOP=$(cat "$RADIO_DIR/pid")
   while [ "$WAIT_STOP" -gt 0 ]; do
      sleep 1
      WAIT_STOP=$(cat "$RADIO_DIR/pid")
      ((i++))
      [ $i -gt 10 ] && return 2
   done

   return 0
}

# start_player <stream> <ffmpeg audio filter specification>
# <ffmpeg audio filter specification> must be a valid ffmpeg audio filter chain.
# NOTE ffplay.c main() always returns 0 if initialisation of sdl and ffmpeg is
# successful, even if the stream was not opened.
start_player() {
   STOP_SIG=0
   trap 'STOP_SIG=1' SIGINT SIGTERM

   [ ! -x /usr/bin/ffplay ] && return 1
   [ ! -w "$RADIO_DIR/pid" ] && return 1
   if [ -z "$2" ]; then
      FFPLAY_ARGS="-autoexit -hide_banner -loglevel quiet -nodisp"
   else
      echo "start_player(): applying filters: $2"
      FFPLAY_ARGS="-autoexit -hide_banner -loglevel quiet -nodisp -af $2"
   fi

   /usr/bin/ffplay $FFPLAY_ARGS "$1" &
   FFPLAY_PID="$!"
   echo "$FFPLAY_PID" > "$RADIO_DIR/pid"
   [ "$STOP_SIG" -gt 0 ] && kill "$FFPLAY_PID"
   wait "$FFPLAY_PID"
   FFPLAY_EXIT_CODE="$?"
   echo "-1" > "$RADIO_DIR/pid"
   [ "$FFPLAY_EXIT_CODE" -gt 0 ] && return 1 # ffplay received SIGTERM (123) or rplay recieved a trapped signal

   return 0
}

show_status() {
   if [ -f "$RADIO_DIR/mpd_wait" ]; then
      echo "Waiting for mpd server..."
   fi
   if [ ! -f "$RADIO_DIR/pid" ]; then
      echo "1 Stopped"
      return 1
   fi
   PID=$(cat "$RADIO_DIR/pid")
   if [ ! "$PID" -gt 0 ]; then
      echo "-1 Stopped"
      return -1
   fi
   PLAYING=$(ps -q "$PID" -o args= | awk '{ print $NF }')
   if [ -z "$PLAYING" ]; then
      echo "-2 Playing:Unknown"
      return -2
   fi
   echo "0 Playing:$PLAYING"
   return 0
}

# wait_for_mpd_server <host>
# Waits for server to become available, then mpd
wait_for_mpd_server() {
   STOP_SIG=0
   trap 'STOP_SIG=1' SIGINT SIGTERM

   touch "$RADIO_DIR/mpd_wait"

   # Wait for network
   while [ "$STOP_SIG" -eq 0 ]; do
      [ ! -f "$RADIO_DIR/mpd_wait" ]  && break
      test_mpd_server_network "$1"
      [ "$?" -eq 0 ] && break
      sleep 1
   done

   # Wait for mpd server
   while [ "$STOP_SIG" -eq 0 ]; do
      [ ! -f "$RADIO_DIR/mpd_wait" ]  && break
      STATUS=$(mpc status -h "$1" "%state%")
      if [ "$?" -eq 0 ]; then
         printf "$STATUS"
         return 0
      fi
      sleep 1
   done

   return 1
}

# wait_for_mpd_stream <host>
# Wait for mpd to start streaming (status is paused or playing)
wait_for_mpd_stream() {
   STOP_SIG=0
   trap 'STOP_SIG=1' SIGINT SIGTERM


   while [ "$STOP_SIG" -eq 0 ]; do
      # Check if stream is started (player reports paused or playing)
      RPLAY_MPD_STATUS=$(mpc status -h "$1" "%state%")
      echo "$RPLAY_MPD_STATUS" | grep -e "paused" -e "playing" >/dev/null
      [ "$?" -eq 0 ] && return 0;

      mpc idle -h "$1" "player" > /dev/null &
      MPC_PID="$!"
      [ -z "$MPC_PID" ] && break
      echo "$MPC_PID" > "$RADIO_DIR/pid"
      wait "$MPC_PID"
      MPC_EXIT_CODE=$?
      echo "-1" > "$RADIO_DIR/pid"
      [ "$MPC_EXIT_CODE" -gt 0 ] && break # mpc received SIGTERM (143) or other problem
   done

   return 1
}

# mpd_player <host> <stream> <filter>
mpd_player() {
   STOP_SIG=0
   trap 'STOP_SIG=1' SIGINT SIGTERM

   SRV=$(echo "$1" | tr -d '/' | cut -d':' -f2)
   URL="$1"
   FILTER="$2"

   while [ "$STOP_SIG" -eq 0 ]; do
      echo "Connecting to mpd server..."
      RPLAY_MPD_STATUS=$(wait_for_mpd_server "$SRV")
      if [ "$?" -ne 0 ]; then
         echo "mpd server $SRV wait cancelled. Exit mpd player."
         exit 1
      fi

      wait_for_mpd_stream "$SRV"
      [ "$?" -ne 0 ] && break   # mpc received SIGTERM (143) or other problem

      echo "Playing..."
      start_player "$URL" "$FILTER"
      [ "$?" -gt 0 ] && break
   done
   exit 0
}

# Retunrs: 100 for url stream, 200 for mpd stream, 0 for no match and 1 for matched but unknown stream type
get_url() {
   local -n pArray=$1
   local selected="$2"
   local -i ret=0 r=0 f=1 s=2 d=3 n=${#pArray[@]}
   while [ $r -lt $n ]; do
      if [ "$selected" == "${pArray[$r]}" ]; then
         case "${pArray[$f]}" in
            url)
               let ret=100
               URL="${pArray[$s]}"
            ;;
            mpd)
               let ret=200
               URL="${pArray[$s]}"
            ;;
            *)
               let ret=1;
               URL="${pArray[$f]}" ;;
         esac
         break
      fi
      let r+=4 f+=4 s+=4 d+=4
   done
   echo "$URL"
   exit $ret
}

[ ! -d "$RADIO_DIR" ] && setup

cd "$RADIO_DIR"

# Built-in commands
DO_FILTER=""
case "$1" in
   help) show_help; exit 0 ;;
   list) list_presets; list_icecast_stations; exit 0 ;;
   stop) stop_player; exit 0 ;;
   status) show_status; exit 0 ;;
   -f) DO_FILTER="$FILTER_PRESET"; shift ;;
esac

if [ -z "$1" ]; then
   echo "No preset specified"
   show_help
   exit 1
fi

STOP_SIG=0
trap 'STOP_SIG=1' SIGINT SIGTERM

URL=$(get_url PRESET "$1")
pTYPE="$?"
case "$pTYPE" in
   1) echo "Unknown stream type: $URL"; exit 1 ;;
   0) # Supplied station is not in the PRESET array; try icecast
      ICECAST_STATIONS=$(get_icecast_stations | tr '\n' ',' | tr -d '"')
      if [ ! -z "$ICECAST_STATIONS" ]; then
         IFS=',' read -ra ICECAST_PRESET <<< "$ICECAST_STATIONS"
         URL=$(get_url ICECAST_PRESET "$1")
         pTYPE="$?"
      fi
   ;;
esac

case "$pTYPE" in
   0) echo "Unknown preset: $1"; show_help; exit 1 ;;
   1) echo "Unknown stream type: $URL"; exit 1 ;;
esac

if [ -z "$URL" ]; then
   echo "ERROR: URL is empty"
   exit 1
fi

stop_player
if [ "$?" -ne 0 ]; then
   echo "Stop player failed!"
   exit 1
fi

case "$pTYPE" in
   100) start_player "$URL" "$DO_FILTER" & ;;
   200) mpd_player "$URL" "$DO_FILTER" & ;;
   *) echo "Unknown return code from get_url(): $pTYPE"; exit 1;
esac

exit 0
