#!/bin/zsh
# Speaker test: you read the "DU" lines into the mic, the Mac speaks Anna's and Eddy's lines through the speakers
# (= Mac-Ton, like the other side of a call). Start a recording in MeetingNotes first (⌃⌥ Leertaste), then run:
#   zsh tests/dialog.sh
# Expected transcript: your lines as "Johan", the others as two different speakers (Sprecher 1 / Sprecher 2).
# Compare the words with: python3 tests/compare.py tests/texte/05-dialog.txt ~/Meetings/<file>.md
set -eu
lines=("${(@f)$(grep -v '^#' "${0:A:h}/texte/05-dialog.txt" | grep .)}")
for l in $lines; do
  who=${l%%:*} text=${l#*: }
  case $who in
    DU)   print -P "\n%BDU:%b $text"; read -s -k '?   (vorlesen, dann Taste drücken) ';;
    ANNA) print "\nAnna: $text"; say -v Anna "$text";;
    EDDY) print "\nEddy: $text"; say -v "Eddy (German (Germany))" "$text";;
  esac
  sleep 0.6
done
print "\nFertig. Aufnahme stoppen (⌃⌥ Leertaste)."
