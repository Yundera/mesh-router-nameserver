#!/bin/sh
# usage: diff.sh <serverA> <serverB> < corpus  — compares rcode + answer (name type data, TTL dropped)
apk add -q bind-tools >/dev/null 2>&1
q() { dig @"$1" "$2" "$3" +norec +time=2 +tries=1 | awk '/status:/{s=$6} /^;; ANSWER SECTION/{a=1;next} a&&/^$/{a=0} a{print tolower($1),$4,$5}END{}' | sort | tr '\n' ' '; dig @"$1" "$2" "$3" +norec +time=2 +tries=1 | grep -o 'status: [A-Z]*' ; }
same=0; diff=0
while read n t; do
  [ -z "$n" ] && continue
  ra=$(q "$1" "$n" "$t"); rb=$(q "$2" "$n" "$t")
  if [ "$ra" = "$rb" ]; then same=$((same+1)); echo "SAME  $n $t :: $ra"; else diff=$((diff+1)); echo "DIFF  $n $t"; echo "   $1: $ra"; echo "   $2: $rb"; fi
done
echo "same=$same diff=$diff"
