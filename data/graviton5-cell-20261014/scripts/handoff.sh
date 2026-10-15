L=$(ls -t /mnt/data/bench/suite-4k-*/log | head -1)
until grep -q "C UNPIN exit" $L; do sleep 20; done
sleep 5; tmux kill-session -t suite; sleep 3; pkill -f "main.py --benchmark agent"; sleep 10
echo "$(date -u +%T) handoff: UNPIN ladder done; PIN-N0 ladder restarted with shortened levels" >> $L
PHASES=C C_ARMS=PIN-N0 LEVELS="44 88 176 352 704 1056 1408" bash ~/rlp-build/g5-suite.sh
