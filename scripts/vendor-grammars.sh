#!/bin/zsh
# Vendors tree-sitter grammars into Packages/CodeText (041, research R2).
#
#   scripts/vendor-grammars.sh all          every grammar in the table
#   scripts/vendor-grammars.sh swift json   just these
#
# Each grammar's generated C sources go to Packages/CodeText/Grammars/TS_<name>/, with a
# one-line public header declaring its entry point. Its highlight query goes to
# Packages/CodeText/Sources/CodeText/Queries/<name>.scm. A query that inherits another
# grammar's (C++ takes C's; TypeScript and TSX take JavaScript's) is written as the
# concatenation, in the order the grammar's own tree-sitter.json gives, so every language
# has exactly one query file.
#
# Vendored rather than depended on: the published grammar packages do not link as they
# stand (tree-sitter-python's manifest drops its scanner; TypeScript's scanner includes a
# file outside its target), and twenty manifests are twenty things to go wrong.
#
# Clones are cached in $GRAMMAR_CACHE (default /tmp/041-spike/grammars), named
# src-<owner>_<repo>-<pin>, so a re-run fetches only what is missing.

set -euo pipefail

root=${0:A:h:h}
pkg=$root/Packages/CodeText
cache=${GRAMMAR_CACHE:-/tmp/041-spike/grammars}
mkdir -p $cache

# name | repo | pin (tag or commit) | grammar subdirectory | query files, in order.
# A query written other:path is taken from that other grammar's clone.
table=(
  "swift|alex-pinkus/tree-sitter-swift|0.7.3-with-generated-files|.|queries/highlights.scm"
  "c|tree-sitter/tree-sitter-c|v0.24.1|.|queries/highlights.scm"
  "cpp|tree-sitter/tree-sitter-cpp|v0.23.4|.|c:queries/highlights.scm,queries/highlights.scm"
  "python|tree-sitter/tree-sitter-python|v0.25.0|.|queries/highlights.scm"
  "javascript|tree-sitter/tree-sitter-javascript|v0.23.1|.|queries/highlights-jsx.scm,queries/highlights.scm"
  "typescript|tree-sitter/tree-sitter-typescript|v0.23.2|typescript|queries/highlights.scm,javascript:queries/highlights.scm"
  "tsx|tree-sitter/tree-sitter-typescript|v0.23.2|tsx|queries/highlights.scm,javascript:queries/highlights-jsx.scm,javascript:queries/highlights.scm"
  "json|tree-sitter/tree-sitter-json|v0.24.8|.|queries/highlights.scm"
  "go|tree-sitter/tree-sitter-go|v0.25.0|.|queries/highlights.scm"
  "rust|tree-sitter/tree-sitter-rust|v0.24.2|.|queries/highlights.scm"
  "java|tree-sitter/tree-sitter-java|v0.23.5|.|queries/highlights.scm"
  "ruby|tree-sitter/tree-sitter-ruby|v0.23.1|.|queries/highlights.scm"
  "bash|tree-sitter/tree-sitter-bash|v0.25.1|.|queries/highlights.scm"
  "yaml|tree-sitter-grammars/tree-sitter-yaml|v0.7.2|.|queries/highlights.scm"
  "toml|tree-sitter-grammars/tree-sitter-toml|v0.7.0|.|queries/highlights.scm"
  "html|tree-sitter/tree-sitter-html|v0.23.2|.|queries/highlights.scm"
  "css|tree-sitter/tree-sitter-css|v0.23.2|.|queries/highlights.scm"
  "markdown|tree-sitter-grammars/tree-sitter-markdown|v0.5.1|tree-sitter-markdown|tree-sitter-markdown/queries/highlights.scm"
  "dockerfile|camdencheek/tree-sitter-dockerfile|v0.2.0|.|queries/highlights.scm"
  "make|alemuller/tree-sitter-make|a4b9187|.|queries/highlights.scm"
)

row() { for r in $table; do [[ ${r%%|*} == $1 ]] && { print -r -- $r; return }; done; return 1 }

# The clone for a grammar, fetched at its pin if it is not cached.
clone() {
  local f=("${(@s:|:)$(row $1)}")
  local repo=$f[2] pin=$f[3]
  local dir=$cache/src-${repo//\//_}-$pin
  # The spike cached make at its branch name; the pin is the same commit.
  [[ $1 == make && ! -d $dir && -d $cache/src-${repo//\//_}-main ]] && dir=$cache/src-${repo//\//_}-main
  if [[ ! -d $dir ]]; then
    if [[ $pin == v* || $pin == *.* ]]; then
      git clone -q --depth 1 --branch $pin https://github.com/$repo $dir
    else
      git clone -q https://github.com/$repo $dir && git -C $dir checkout -q $pin
    fi
  fi
  print -r -- $dir
}

vendor() {
  local name=$1
  local f=("${(@s:|:)$(row $name)}")
  local sub=$f[4] queries=$f[5]
  local dir=$(clone $name)
  local src=$dir/$sub/src
  local out=$pkg/Grammars/TS_$name

  grep -q "tree_sitter_$name(void)" $src/parser.c || { print -u2 "$name: no tree_sitter_$name in parser.c"; exit 1 }

  rm -rf $out && mkdir -p $out/include
  # Everything the parser and scanner include; the package compiles only parser.c and
  # scanner.c, so files a scanner #includes (yaml's schema.*.c) come along untouched.
  for item in $src/*(N); do
    case ${item:t} in grammar.json|node-types.json|parser_*.c) ;; *) cp -R $item $out/ ;; esac
  done
  if [[ -f $out/scanner.c ]] && grep -q '"../../common/scanner.h"' $out/scanner.c; then
    cp $dir/common/scanner.h $out/common_scanner.h
    sed -i '' 's#"../../common/scanner.h"#"common_scanner.h"#' $out/scanner.c
  fi
  cat > $out/include/ts_$name.h <<EOF
// Vendored by scripts/vendor-grammars.sh. Do not edit; re-run the script.
#ifndef TS_${(U)name}_H
#define TS_${(U)name}_H
typedef struct TSLanguage TSLanguage;
const TSLanguage *tree_sitter_$name(void);
#endif
EOF

  local qout=$pkg/Sources/CodeText/Queries/$name.scm
  mkdir -p ${qout:h}
  print -r -- "; Vendored by scripts/vendor-grammars.sh from ${f[2]} ${f[3]}. Do not edit." > $qout
  for q in ${(s:,:)queries}; do
    local qdir=$dir qpath=$q
    if [[ $q == *:* ]]; then qdir=$(clone ${q%%:*}); qpath=${q#*:}; fi
    print -r -- "" >> $qout
    print -r -- "; ---- ${qdir:t}/$qpath" >> $qout
    cat $qdir/$qpath >> $qout
  done
  print "$name: $(du -sk $out | cut -f1) KB of sources, query $(wc -l < $qout | tr -d ' ') lines"
}

names=("$@")
[[ ${names[1]:-} == all ]] && names=(${table%%|*})
(( ${#names} )) || { print -u2 "usage: $0 all | <name>..."; exit 2 }
for n in $names; do row $n >/dev/null || { print -u2 "unknown grammar: $n"; exit 2 }; vendor $n; done
