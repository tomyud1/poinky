#!/bin/bash
# tools/e2e/sheet.sh <rundir> [first] [last] [step] [cols]: a contact sheet of a run's screenshots (sheet-<first>-<last>.jpg).
d=$1; a=${2:-1}; b=${3:-999}; s=${4:-3}; c=${5:-4}
files=(); for ((i=a;i<=b;i+=s)); do f=$(printf "%s/shots/%03d.jpg" "$d" $i); [ -f "$f" ] && files+=("$f"); done
montage "${files[@]}" -tile ${c}x -geometry 855x553+4+4 -label '%t' "$d/sheet-$a-$b.jpg" && echo "$d/sheet-$a-$b.jpg"
