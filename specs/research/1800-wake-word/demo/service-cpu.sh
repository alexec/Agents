#!/bin/zsh
# The CPU the speech service uses while a paced wake-demo run listens. The recogniser runs
# in Speech.framework's localspeechrecognition XPC service, which starts with the run and
# may exit with it, so it is sampled every 2 s while the run goes on.
#   service-cpu.sh PHRASE FILE [wake-demo detect flags...]
set -u
zmodload zsh/datetime
here=${0:A:h}
cputime() {
  ps -Ao time=,comm= | awk '/localspeechrecognition$/ {
    n = split($1, p, ":"); s = 0; for (i = 1; i <= n; i++) s = s * 60 + p[i]; print s; exit }'
}
"$here/.build/out/Products/Release/wake-demo" detect "$1" "$2" --realtime "${@:3}" > /dev/null &
run=$!
first="" last="" t0="" t1=""
while kill -0 $run 2>/dev/null; do
  sleep 2
  now=$(cputime)
  [[ -z $now ]] && continue
  [[ -z $first ]] && { first=$now; t0=$EPOCHREALTIME; }
  last=$now; t1=$EPOCHREALTIME
done
if [[ -z $first || $t1 == $t0 ]]; then echo "speech service: not seen"; exit 0; fi
printf 'speech service: %.2f s CPU in %.0f s, %.2f%% of one core\n' $(( last - first )) $(( t1 - t0 )) $(( 100.0 * (last - first) / (t1 - t0) ))
