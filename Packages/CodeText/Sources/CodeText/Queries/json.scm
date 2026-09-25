; Vendored by scripts/vendor-grammars.sh from tree-sitter/tree-sitter-json v0.24.8. Do not edit.

; ---- src-tree-sitter_tree-sitter-json-v0.24.8/queries/highlights.scm
(pair
  key: (_) @string.special.key)

(string) @string

(number) @number

[
  (null)
  (true)
  (false)
] @constant.builtin

(escape_sequence) @escape

(comment) @comment
