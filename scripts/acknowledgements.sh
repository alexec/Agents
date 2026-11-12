#!/bin/zsh
# Writes the licence notices for the code colouring (041) into both apps' resources:
# tree-sitter, swift-tree-sitter, and every vendored grammar, each in its own words; and
# on the Mac, the notice for Paper v2's faces (#4975).
# MIT and BSD both ask for their notice to travel with the software.
#
#   scripts/acknowledgements.sh      (after scripts/vendor-grammars.sh)
set -euo pipefail
root=${0:A:h:h}
cache=${GRAMMAR_CACHE:-/tmp/041-spike/grammars}
checkouts=$root/Packages/CodeText/.build/checkouts

out=$(mktemp)
fonts=$(mktemp)
# Paper v2's faces (#4975), on the Mac only until the Remote draws in them (#4992).
{
  print "## Atkinson Hyperlegible Next and Atkinson Hyperlegible Mono\n"
  print "The app's text and code faces, from the Braille Institute, used under the SIL Open"
  print "Font License 1.1.\n"
  print '```'
  cat $root/design/fonts/OFL.txt
  print '```\n'
} > $fonts
{
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
  # The icons (#4976): Lucide's symbols in Shared/UI/Icons.xcassets, made from its SVGs
  print "## Lucide ($(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["lucide"]["version"])' $root/design/icons.json))\n"
  print "The icons are Lucide's, drawn at a 1.5 stroke (scripts/design.sh icons).\n"
  print '```'
  cat $root/design/icons/LICENSE
  print '```\n'
} > $out
{
  print "# Acknowledgements\n"
  print "The app's text is set in Atkinson Hyperlegible Next and Mono, and its code is coloured"
  print "with tree-sitter and the grammars below, each used under its licence, which follows in"
  print "full.\n"
  cat $fonts $out
} > $root/App/Resources/Acknowledgements.md
{
  print "# Acknowledgements\n"
  print "Code in this app is coloured with tree-sitter and the grammars below, used under"
  print "their licences, which follow in full.\n"
  cat $out
} > $root/Remote/Resources/Acknowledgements.md
rm $out $fonts
print "wrote $(grep -c '^## ' $root/App/Resources/Acknowledgements.md) notices"
