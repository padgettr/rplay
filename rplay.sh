#!/bin/bash
# Play internet radio stations
#
# (c) Dr. Rodney Padgett (2016)
# See LICENCE file

show_help() {
   echo "Usage:"
   echo "   $0 <preset>"
   echo "   Where preset is:"
   echo "      bbc1 - bbc6"
   echo "      mhr"
   echo "      cfm (classicFM)"
   echo "      stop (stops player)"
   echo ""
   exit 0
}

setup() {
   mkdir /tmp/radio
   cd /tmp/radio
   /usr/local/bin/dlBBC
   # ClassicFM
   lynx -dump "http://www.radiofeeds.co.uk/mp3.asp" | awk '$2 ~ /ClassicFMMP3/ {print $2 }' | wget -i -
}

stop_player() {
   [ ! -f /tmp/radio/pid ] && return 1
   kill $(cat /tmp/radio/pid)
   rm /tmp/radio/pid
   return 0
}

start_player() {
   [ ! -x /usr/bin/ffplay ] && return 1
   ffplay  -hide_banner -loglevel quiet -nodisp "$1" &
   echo $! > /tmp/radio/pid
   return 0
}

[ ! -d /tmp/radio ] && setup || cd /tmp/radio

case "$1" in
   bbc1) URL=$(cat bbc_radio_one.m3u8 | grep http) ;;
   bbc2) URL=$(cat bbc_radio_two.m3u8 | grep http) ;;
   bbc3) URL=$(cat bbc_radio_three.m3u8 | grep http) ;;
   bbc4) URL=$(cat bbc_radio_fourfm.m3u8 | grep http) ;;
   bbc6) URL=$(cat bbc_6music.m3u8 | grep http) ;;
   cfm) URL=$(cat ClassicFMMP3.m3u | sed 's/\r//');;
   mhr) URL="http://192.168.1.2:8090/mpd.mp3" ;;
   stop) stop_player ;;
   *) show_help ;;
esac

[ -z "$URL" ] && exit 0

stop_player
start_player "$URL"

exit $?
