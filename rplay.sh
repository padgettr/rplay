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

USER=$(id -u -n)
RADIO_DIR="/tmp/radio-$USER"

# Radio presets:
# reference format stream description
#
#  reference: rplay preset name (used to select the preset)
#  format: 
#     hls:        bbc hls streams
#     mp3 or aac: m3u or pls playlists using either mp3 or aac compression
#     url:        play directly from url; stream specifies a url
#     mpd:        stream is from mpd: wait for playback to start
#  stream:
#     format is url: stream specifies the url of the stream.
#     format is hls, mp3 or aac: search term to identify the required stream on http://www.radiofeeds.co.uk/
#                                search term should uniquely identify the required stream URL: first match will be returned.
#  description: text description of preset (list command).
PRESET=( "bbc1" "hls" "radio_one" "BBC Radio one" \
         "bbc2" "hls" "radio_two" "BBC Radio two" \
         "bbc3" "hls" "radio_three" "BBC Radio three" \
         "bbc4" "hls" "radio_four" "BBC Radio four" \
         "bbc6" "hls" "6music" "BBC Radio 6music" \
         "cfm" "mp3" "ClassicFMMP3" "ClassicFM" \
         "mpd" "mpd" "http:192.168.1.2:8090" "mpd server (mp3)" \
         "ice" "url" "http://192.168.1.2:8095/ice.ogg" "Alsa stream (flac)" \
       )

# BBC HLS stream bit rate: sbr_high - 320kb/s; sbr_med - 128kb/s; sbr_low - 96kb/s; sbr_vlow - 48kb/s
HLS_SBR="sbr_high"

# Radiofeeds url: as of February 2022 URL paths are:
#                 mp3.asp     -  mp3 streams
#                 aac.asp     -  aac streams
#                 other.asp   -  bbc hls streams
RADIO_FEEDS_URL="http://www.radiofeeds.co.uk"

# Call with $1: URL search term; $2: stream format
# Expects playlist format m3u or pls
get_url() {
   lynx -dump "$RADIO_FEEDS_URL/$2.asp" | \
      grep $1 | \
      awk '{print $2 }' | \
      wget --quiet --user-agent="" -i - -O - | \
      grep http | sed -e 's/File1=//' -e 's/\r//'
}

# BBC hls streams
# Call with $1: URL search term; $2: sbr_high - 320kb/s; sbr_med - 128kb/s; sbr_low - 96kb/s; sbr_vlow - 48kb/s
get_url_hls() {
   lynx -dump "$RADIO_FEEDS_URL/other.asp" | \
      grep $1 | grep $2 | \
      awk '{print $2 }' | \
      wget --quiet --user-agent="" -i - -O - | \
      grep http
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
   echo "Requires ffmpeg (ffplay), lynx (text web browser), wget and mpc (mpd streaming control)"
   echo "Usage:"
   echo "   $0 stop  - stops player"
   echo "   $0 list  - list presets"
   echo "   $0 status  - show status"
   echo "   $0 <preset>  - play <preset>"
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
   [ ! $PID -gt 0 ] && return 0

   kill $PID
   [ $? -gt 0 ] && return 2

   ((i=0))
   WAIT_STOP=$(cat "$RADIO_DIR/pid")
   while [ $WAIT_STOP -gt 0 ]; do
      sleep 1
      WAIT_STOP=$(cat "$RADIO_DIR/pid")
      ((i++))
      [ $i -gt 10 ] && return 2
   done

   return 0
}

start_player() {
   STOP_SIG=0
   trap 'STOP_SIG=1' SIGINT SIGTERM
   [ ! -x /usr/bin/ffplay ] && return 1
   [ ! -w "$RADIO_DIR/pid" ] && return 1
   
   /usr/bin/ffplay -autoexit -hide_banner -loglevel quiet -nodisp "$1" &
   FFPLAY_PID=$!
   echo $FFPLAY_PID > "$RADIO_DIR/pid"

   wait $FFPLAY_PID
   FFPLAY_EXIT_CODE=$?
   echo "-1" > "$RADIO_DIR/pid"
   if [ $FFPLAY_EXIT_CODE -gt 0 ]; then # ffplay received SIGTERM (123) or rplay recieved a trapped signal
      [ $STOP_SIG -gt 0 ] && kill $FFPLAY_PID
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
   if [ ! $PID -gt 0 ]; then
      echo "-1 Stopped"
      return -1
   fi
   PLAYING=$(ps -q $PID -o args= | awk '{ print $NF }')
   if [ -z "$PLAYING" ]; then
      echo "-2 Playing:Unknown"
      return -2
   fi
   echo "0 Playing:$PLAYING"
   return 0
}

mpd_player() {
   STOP_SIG=0
   trap 'STOP_SIG=1' SIGINT SIGTERM
   
   while [ $STOP_SIG -eq 0 ]; do
      MPC_PID=-1
      MPC_EXIT_CODE=-1
      RPLAY_MPD_STATUS=$(mpc status -h "$1")
      if [ $? -ne 0 ]; then
         echo "mpd server $1 not found."
         exit 1
      fi
      echo $RPLAY_MPD_STATUS | grep -e "paused" -e "playing" >/dev/null
      if [ $? -ne 0 ]; then   # Wait for playback to start
         echo "Waiting for mpd..."
         mpc idle -h "$1" > /dev/null &
         MPC_PID=$!
         echo $MPC_PID > "$RADIO_DIR/pid"
         wait $MPC_PID
         MPC_EXIT_CODE=$?
         echo "-1" > "$RADIO_DIR/pid"
      fi
      if [ $MPC_EXIT_CODE -gt 0 ]; then   # mpc received SIGTERM (143) or rplay recieved a trapped signal
         [ $STOP_SIG -gt 0 ] && kill $MPC_PID
         break 
      fi

      echo "Playing..."
      start_player "$2"
      [ $? -gt 0 ] && break
   done
   exit 0
}

[ ! -d "$RADIO_DIR" ] && setup

cd "$RADIO_DIR"

# Built-in commands
case "$1" in
   help) show_help; exit 0 ;;
   list) list_presets; exit 0 ;;
   stop) stop_player; exit 0 ;;
   status) show_status; exit 0 ;;
esac

STOP_SIG=0
trap 'STOP_SIG=1' SIGINT SIGTERM

URL=""
SRV=""
declare -i r=0 f=1 s=2 d=3 n=${#PRESET[@]}
while [ $r -lt $n ]; do
   if [ "$1" == "${PRESET[$r]}" ]; then
      case "${PRESET[$f]}" in
         hls) URL=$(get_url_hls "${PRESET[$s]}" "$HLS_SBR") ;;
         url) URL="${PRESET[$s]}" ;;
         mpd) SRV=$(echo "${PRESET[$s]}" | cut -d':' -f2);
              URL=$(echo "${PRESET[$s]}" | awk -F: '{ printf "%s://%s:%s\n", $1, $2, $3 }') ;;
         *) URL=$(get_url "${PRESET[$s]}" ${PRESET[$f]}) ;;
      esac
      break
   fi
   let r+=4 f+=4 s+=4 d+=4
done

if [ -z "$URL" ]; then
   show_help
   exit 0
fi

stop_player
if [ $? -ne 0 ]; then
   echo "Stop player failed!"
   exit 1
fi

if [ ! -z "$SRV" ]; then
   mpd_player "$SRV" "$URL" &
else
   echo "Playing $1: $URL"
   start_player "$URL" &
fi

exit 0
