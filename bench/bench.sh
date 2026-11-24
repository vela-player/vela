#!/bin/bash
# vela benchmark: time to window, CPU and memory while playing a movie from the 1-hour mark.
# usage: bench.sh <player> <movie> [runs]
#   players: vela, mpv-default, mpv-hwdec, iina, vlc
# CPU = cumulative CPU time of the player plus Apple's video decoder service
# (VTDecoderXPCService), averaged over a 20 s window after 10 s of warm-up.
set -u
player=$1; movie=$2; runs=${3:-3}
here=$(cd "$(dirname "$0")" && pwd)
VELA="$here/../.build/release/vela"

cputime() {  # total CPU seconds of matching processes
  ps -axo time=,comm= | awk -v pat="$1" 'index($0, pat) {
      n = split($1, p, /[:.]/); s = 0
      if (n == 4) s = p[1]*3600 + p[2]*60 + p[3] + p[4]/100
      else if (n == 3) s = p[1]*60 + p[2] + p[3]/100
      t += s } END { printf "%.2f", t }'
}

now() { python3 -c 'import time;print(f"{time.time():.4f}")'; }

for run in $(seq 1 "$runs"); do
  for name in vela mpv IINA VLC; do pgrep -x "$name" >/dev/null && { echo "abort: $name already running"; exit 1; }; done
  launch=$(now)
  case $player in
    vela)        owner=vela; pname=vela
                 "$VELA" --mute=yes --start=3600 "$movie" 2>/dev/null & ;;
    mpv-default) owner=mpv; pname=mpv
                 mpv --mute=yes --start=3600 --force-window=immediate "$movie" >/dev/null 2>&1 & ;;
    mpv-hwdec)   owner=mpv; pname=mpv
                 mpv --mute=yes --start=3600 --hwdec=videotoolbox --force-window=immediate "$movie" >/dev/null 2>&1 & ;;
    iina)        owner=iina; pname=IINA
                 /Applications/IINA.app/Contents/MacOS/iina-cli --mpv-mute=yes --mpv-start=3600 "$movie" >/dev/null 2>&1 & ;;
    vlc)         owner=vlc; pname=VLC
                 /Applications/VLC.app/Contents/MacOS/VLC --start-time=3600 --gain=0 "$movie" >/dev/null 2>&1 & ;;
  esac
  window=$("$here/winwait" "$owner" "$launch" 20)
  sleep 10
  pid=$(pgrep -nx "$pname"); [ -z "$pid" ] && pid=$(pgrep -n "$pname")
  c0=$(cputime "$pname"); d0=$(cputime VTDecoderXPCService); t0=$(now)
  sleep 20
  t1=$(now)
  c1=$(cputime "$pname"); d1=$(cputime VTDecoderXPCService)
  mem=$(footprint "$pid" 2>/dev/null | awk '/phys_footprint:/{print $2" "$3}')
  cpu=$(python3 -c "print(f'{(($c1-$c0)+($d1-$d0))/($t1-$t0)*100:.1f}')")
  app=$(python3 -c "print(f'{($c1-$c0)/($t1-$t0)*100:.1f}')")
  echo "$player run=$run window_s=$window cpu_total=$cpu% (app=$app%) footprint=$mem"
  kill "$pid" 2>/dev/null; sleep 2; kill -9 "$pid" 2>/dev/null; sleep 1
done
