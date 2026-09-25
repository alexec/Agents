# Vendored grammars

Each folder here is tree-sitter's generated C for one language. It was copied by
`scripts/vendor-grammars.sh` at the pin below and must not be edited by hand; to change
one, change its pin in the script and run it again. The highlight query for each is in
`Sources/CodeText/Queries/<name>.scm`, built by the same script.

Sizes are compiled `-Os` for arm64, measured in the 041 spike (research R1).

| Grammar | Repo | Pin | Licence | KB | Covers |
|---|---|---|---|---|---|
| swift | alex-pinkus/tree-sitter-swift | 0.7.3-with-generated-files | MIT, © 2021 alex-pinkus | 3,667 | .swift |
| python | tree-sitter/tree-sitter-python | v0.25.0 | MIT, © 2016 Max Brunsfeld | 440 | .py .pyi, `#!…python` |
| javascript | tree-sitter/tree-sitter-javascript | v0.23.1 | MIT, © 2014 Max Brunsfeld | 345 | .js .mjs .cjs .jsx |
| typescript | tree-sitter/tree-sitter-typescript | v0.23.2 | MIT, © 2017 Max Brunsfeld | 1,373 | .ts .mts .cts |
| tsx | tree-sitter/tree-sitter-typescript | v0.23.2 | MIT, © 2017 Max Brunsfeld | 1,404 | .tsx |
| json | tree-sitter/tree-sitter-json | v0.24.8 | MIT, © 2014 Max Brunsfeld | 4 | .json .jsonc |
| markdown | tree-sitter-grammars/tree-sitter-markdown (block grammar) | v0.5.1 | MIT, © 2021 Matthias Deiml | 373 | .md in diffs |

The runtime these run on:

| Package | Pin | Licence |
|---|---|---|
| tree-sitter/swift-tree-sitter | from 0.25.0 | BSD 3-Clause |
| tree-sitter/tree-sitter (its C runtime, pulled in by the above) | as resolved | MIT |

**Still to vendor (041 T025)**: c, cpp, go, rust, java, ruby, bash, yaml, toml, html, css,
dockerfile, make. Their rows are already in the script's table.

**Left out on purpose** (research R1, R2): SQL (10.8 MB), Objective-C (5.2 MB) and Kotlin
(4.0 MB) cost more app size than the other twenty together. `.m` files are coloured as C;
`.sql`, `.kt` and `.kts` are shown plain.
