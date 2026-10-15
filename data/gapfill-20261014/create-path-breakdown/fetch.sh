while read tag a b; do
  echo "### $tag"
  sudo journalctl -u rlp-runner --since "@$a" --until "@$b" -o cat --no-pager | grep -E 'msg="boot-phases create"|msg=boot-phases|msg=running-emit'
done
