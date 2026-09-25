; Vendored by scripts/vendor-grammars.sh from tree-sitter/tree-sitter-html v0.23.2. Do not edit.

; ---- src-tree-sitter_tree-sitter-html-v0.23.2/queries/highlights.scm
(tag_name) @tag
(erroneous_end_tag_name) @tag.error
(doctype) @constant
(attribute_name) @attribute
(attribute_value) @string
(comment) @comment

[
  "<"
  ">"
  "</"
  "/>"
] @punctuation.bracket
