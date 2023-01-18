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

USER=$(id -u -n)
RADIO_DIR="/tmp/radio-$USER"

# Apply audio filters if -f option is given
# This must be a valid ffmpeg audio filter chain (do not prepend -af or -f:a)
FILTER_PRESET="volume=-10dB,equalizer=f=50:width_type=h:width=50:g=10"

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
BBC_SERVER="http://a.files.bbci.co.uk/media/live/manifesto/audio/simulcast/hls/uk/sbr_high/ak"
PRESET=( "bbc1" "url" "$BBC_SERVER/bbc_radio_one.m3u8" "BBC Radio one" \
         "bbc2" "url" "$BBC_SERVER/bbc_radio_two.m3u8" "BBC Radio two" \
         "bbc3" "url" "$BBC_SERVER/bbc_radio_three.m3u8" "BBC Radio three" \
         "bbc4" "url" "$BBC_SERVER/bbc_radio_fourfm.m3u8" "BBC Radio four" \
         "bbc6" "url" "$BBC_SERVER/bbc_6music.m3u8" "BBC Radio 6music" \
         "cfm" "url" "http://icecast.thisisdax.com/ClassicFMMP3" "ClassicFM" \
         "mpd" "mpd" "http:192.168.10.2:8090" "mpd server (mp3)" \
       )

list_presets() {
   local -i r=0 f=1 s=2 d=3 n=${#PRESET[@]}
   while [ $r -lt $n ]; do
      printf "%s\t %s\n" "${PRESET[$r]}" "${PRESET[$d]}"
      let r+=4 f+=4 s+=4 d+=4
   done
}

show_help() {
   echo "Play radio streams"
   echo "Requires ffmpeg (ffplay) and mpc (mpd streaming control)"
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
   echo ""
}

setup() {
   mkdir "$RADIO_DIR"
   echo "-1" > "$RADIO_DIR/pid"
}

stop_player() {
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

   wait "$FFPLAY_PID"
   FFPLAY_EXIT_CODE="$?"
   echo "-1" > "$RADIO_DIR/pid"
   if [ "$FFPLAY_EXIT_CODE" -gt 0 ]; then # ffplay received SIGTERM (123) or rplay recieved a trapped signal
      [ "$STOP_SIG" -gt 0 ] && kill "$FFPLAY_PID"
      return 1
   fi
   return 0
}

show_status() {
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

# mpd_player <host> <stream> <filter>
mpd_player() {
   STOP_SIG=0
   trap 'STOP_SIG=1' SIGINT SIGTERM

   while [ "$STOP_SIG" -eq 0 ]; do
      MPC_PID=-1
      MPC_EXIT_CODE=-1
      RPLAY_MPD_STATUS=$(mpc status -h "$1")
      if [ "$?" -ne 0 ]; then
         echo "mpd server $1 not found."
         exit 1
      fi
      echo "$RPLAY_MPD_STATUS" | grep -e "paused" -e "playing" >/dev/null
      if [ "$?" -ne 0 ]; then   # Wait for playback to start
         echo "Waiting for mpd..."
         mpc idle -h "$1" > /dev/null &
         MPC_PID="$!"
         echo "$MPC_PID" > "$RADIO_DIR/pid"
         wait "$MPC_PID"
         MPC_EXIT_CODE="$?"
         echo "-1" > "$RADIO_DIR/pid"
      fi
      if [ "$MPC_EXIT_CODE" -gt 0 ]; then   # mpc received SIGTERM (143) or rplay recieved a trapped signal
         [ "$STOP_SIG" -gt 0 ] && kill "$MPC_PID"
         break
      fi

      echo "Playing..."
      start_player "$2" "$3"
      [ "$?" -gt 0 ] && break
   done
   exit 0
}

[ ! -d "$RADIO_DIR" ] && setup

cd "$RADIO_DIR"

# Built-in commands
DO_FILTER=""
case "$1" in
   help) show_help; exit 0 ;;
   list) list_presets; exit 0 ;;
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

URL=""
SRV=""
declare -i r=0 f=1 s=2 d=3 n=${#PRESET[@]}
while [ $r -lt $n ]; do
   if [ "$1" == "${PRESET[$r]}" ]; then
      case "${PRESET[$f]}" in
         url) URL="${PRESET[$s]}" ;;
         mpd) SRV=$(echo "${PRESET[$s]}" | cut -d':' -f2);
              URL=$(echo "${PRESET[$s]}" | awk -F: '{ printf "%s://%s:%s\n", $1, $2, $3 }') ;;
         *) URL="" ;;
      esac
      break
   fi
   let r+=4 f+=4 s+=4 d+=4
done

if [ -z "$URL" ]; then
   echo "Unknown preset: $1"
   show_help
   exit 1
fi

stop_player
if [ "$?" -ne 0 ]; then
   echo "Stop player failed!"
   exit 1
fi

if [ ! -z "$SRV" ]; then
   mpd_player "$SRV" "$URL" "$DO_FILTER" &
else
   echo "Playing $1: $URL"
   start_player "$URL" "$DO_FILTER" &
fi

exit 0
