#!/bin/zsh
# Writes the licence notices for the code colouring (041) into both apps' resources:
# tree-sitter, swift-tree-sitter, and every vendored grammar, each in its own words.
# MIT and BSD both ask for their notice to travel with the software.
#
#   scripts/acknowledgements.sh      (after scripts/vendor-grammars.sh)
set -euo pipefail
root=${0:A:h:h}
cache=${GRAMMAR_CACHE:-/tmp/041-spike/grammars}
checkouts=$root/Packages/CodeText/.build/checkouts

out=$(mktemp)
{
  print "# Acknowledgements\n"
  print "Code in this app is coloured with tree-sitter and the grammars below, used under"
  print "their licences, which follow in full.\n"
  for dir in $checkouts/tree-sitter $checkouts/swift-tree-sitter; do
    print "## ${dir:t}\n"
    print '```'
    cat $dir/LICENSE
    print '```\n'
  done
  for grammar in $root/Packages/CodeText/Grammars/TS_*(/); do
    name=${grammar:t}; name=${name#TS_}
    # The clone this grammar was vendored from, by the name in the query header.
    src=$(sed -n '1s/.*from \([^ ]*\) \([^ ]*\)\. Do not edit\./\1 \2/p' \
          $root/Packages/CodeText/Sources/CodeText/Queries/$name.scm)
    repo=${src%% *}; pin=${src##* }
    dir=$cache/src-${repo//\//_}-$pin
    [[ -d $dir ]] || dir=$cache/src-${repo//\//_}-main
    license=$(ls $dir/LICENSE* 2>/dev/null | head -1)
    [[ -n $license ]] || { print -u2 "no licence found for $name in $dir"; exit 1 }
    print "## tree-sitter-$name ($repo $pin)\n"
    print '```'
    cat $license
    print '```\n'
  done
} > $out
cp $out $root/App/Resources/Acknowledgements.md
cp $out $root/Remote/Resources/Acknowledgements.md
rm $out
print "wrote $(grep -c '^## ' $root/App/Resources/Acknowledgements.md) notices"
