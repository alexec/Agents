#!/bin/zsh
# Every run of the #1800 report, into results.txt: each phrase's 24 tries (fast, then the
# near misses), then the paced runs that give the wake lag and the speech service's CPU.
set -u
cd ${0:A:h}/clips
w=../.build/out/Products/Release/wake-demo
alike="hey loose,hey lubes,hello lubes,hey lubbs,hey lupes,hey loop"
{
  for p in hey-loops okay-agents hey-agents; do
    phrase=$(python3 -c "import json;print(json.load(open('truth-$p.json'))['phrase'])")
    echo "== $phrase"
    $w detect "$phrase" stream-$p.wav --realtime --truth truth-$p.json | grep -v '^wake in'
    echo "-- near misses: $($w detect "$phrase" negatives.wav | tail -1)"
  done
  echo "== Hey Loops, with sound-alikes: $alike"
  $w detect "Hey Loops" stream-hey-loops.wav --realtime --also "$alike" --truth truth-hey-loops.json | grep -v '^wake in'
  echo "-- near misses: $($w detect "Hey Loops" negatives.wav --also "$alike" | tail -1)"
  echo "== the speech service while listening"
  echo "speech, detector on:  $(../service-cpu.sh "Hey Agents" stream-hey-agents.wav)"
  echo "quiet, detector on:   $(../service-cpu.sh "Hey Agents" quiet.wav)"
  echo "quiet, detector off:  $(../service-cpu.sh "Hey Agents" quiet.wav --no-detector)"
} > ../results.txt 2>&1
