#!/bin/bash
# ChangeLog:
#  28-08-2020  Add --user-agent="" to wget - classicFM server rejects requests from wget
#  19-12-2020  Change the pid control and wait for radio stop.
#  26-03-2020  Get rid of dlBBC and download urls directly from www.radiofeeds.co.uk
#  27-03-2021  Define radio stations in bash arrays for easy update of urls
USER=$(id -u -n)
RADIO_DIR="/tmp/radio-$USER"
# Check status interval (seconds)
STATUS_INTERVAL=2

# Radiofeed URLs
# The functions get_url() and get_url_hls() must return the
# address of the radio station feed based on the search term
# in $STREAM.
#
# Station presets: add an entry in each array at the corresponding index
# Preset name: no spaces allowed
PRESETS=( "bbc1" "bbc2" "bbc3" "bbc4" "bbc6" "cfm" "mhr" "orac" "zen" )
# Format of the stream to search for on radiofeeds:
#   hls for bbc hls streams, or playlist format for mp3 streams (m3u or pls).
# Format can be url - the http address of the stream will be used
FORMAT=( "hls" "hls" "hls" "hls" "hls" "m3u" "url" "url" "url" )
# Get url for the stream:
# FORMAT=hls, m3u or pls STREAM=search term:
#   radiofeeds other (hls) or mp3 (m3u / pls) will be searched for
#   a radio station url containing this term. For mp3, the specified playlist format
#   will be matched. First matching URL will be returned.
# FORMAT=url:
#   This should be the URL to play
STREAM=( "radio_one" "radio_two" "radio_three" "radio_four" "6music" "ClassicFMMP3" "http://mhpi:8090" "http://orac:8000/alsa.mp3" "http://zen:8000/alsa.mp3" )
# Description for the preset
DESCRIPTION=( "BBC Radio one" \
              "BBC Radio two" \
              "BBC Radio three" \
              "BBC Radio four" \
              "BBC Radio 6music" \
              "ClassicFM" \
              "mpd server on mhpi" \
              "Alsa stream on orac" \
              "Alsa stream on zen" \
            )

# BBC HLS stream bit rate: sbr_high - 320kb/s; sbr_med - 128kb/s; sbr_low - 96kb/s; sbr_vlow - 48kb/s
HLS_SBR="sbr_high"


# Call with radio_one|radio_two|radio_three|radio_fourfm|6music|ClassicFMMP3
# and playlist type m3u or pls
get_url() {
   lynx -dump "http://www.radiofeeds.co.uk/mp3.asp" | \
      grep $1 | grep $2 |
      awk '{print $2 }' | \
      wget --quiet --user-agent="" -i - -O - | \
      grep http | sed -e 's/File1=//' -e 's/\r//'
}

# Call with radio_one|radio_two|radio_three|radio_fourfm|6music
# and quality sbr_high - 320kb/s; sbr_med - 128kb/s; sbr_low - 96kb/s; sbr_vlow - 48kb/s
get_url_hls() {
   lynx -dump "http://www.radiofeeds.co.uk/other.asp" | \
      grep $1 | grep $2 | \
      awk '{print $2 }' | \
      wget --quiet --user-agent="" -i - -O - | \
      grep http
}

list_presets() {
   ((i=0))
   for STATION in ${PRESETS[@]}; do
      printf "%s\t %s\n" $STATION "${DESCRIPTION[$i]}"
      ((i++))
   done
}

show_help() {
   echo "Play online radio from http://www.radiofeeds.co.uk"
   echo "Requires ffmpeg (ffplay), lynx (text web browser) and wget"
   echo "Usage:"
   echo "   $0 stop  - stops player"
   echo "   $0 list  - list presets"
   echo "   $0 <preset>  - play <preset>"
   echo "Presets:"
   echo "<preset> description"
   list_presets
   echo ""
   exit 0
}

setup() {
   mkdir "$RADIO_DIR"
   echo "-1" > "$RADIO_DIR/pid"
   cd "$RADIO_DIR"
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
      sleep $STATUS_INTERVAL
      WAIT_STOP=$(cat "$RADIO_DIR/pid")
      ((i++))
      [ $i -gt 10 ] && return 2
   done

   return 0
}

start_player() {
   [ ! -x /usr/bin/ffplay ] && return 1
   [ ! -w "$RADIO_DIR/pid" ] && return 1
   ffplay -autoexit -hide_banner -loglevel quiet -nodisp "$1" &
   FFPLAY_PID=$!
   echo $FFPLAY_PID > "$RADIO_DIR/pid"

   fSTATUS=0
   while [ $fSTATUS -eq 0 ]; do
      sleep $STATUS_INTERVAL
      pgrep -u $USER ffplay | grep $FFPLAY_PID >/dev/null 2>&1
      fSTATUS=$?
   done
   echo "-1" > "$RADIO_DIR/pid"
}

[ ! -d "$RADIO_DIR" ] && setup || cd "$RADIO_DIR"

# Built-in commands
case "$1" in
   help) show_help ;;
   list) list_presets; exit 0 ;;
   stop) stop_player; exit 0 ;;
esac

((i=0))
for STATION in ${PRESETS[@]}; do
   if [ "$1" == "$STATION" ]; then
      case "${FORMAT[$i]}" in
         hls) URL=$(get_url_hls "${STREAM[$i]}" "$HLS_SBR") ;;
         url) URL="${STREAM[$i]}" ;;
         *) URL=$(get_url "${STREAM[$i]}" ${FORMAT[$i]}) ;;
      esac
      break
   fi
   ((i++))
done

[ -z "$URL" ] && show_help

stop_player

if [ $? -eq 0 ]; then
   echo "Playing $1: $URL"
   start_player "$URL" &
else
   echo "Stop player failed!"
   exit 1
fi
exit 0
