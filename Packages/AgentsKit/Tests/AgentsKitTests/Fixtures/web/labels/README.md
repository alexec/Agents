# labels/

- `policy.json`: `SessionLabelPolicy.split(typed:)` and `accepted(_:existing:)`
  (`Model/SessionLabel.swift`): at most five labels of 24 characters.
- `query.json`: `SessionLabelQuery` (`Model/SessionLabelQuery.swift`), the search field's
  `label:` filter and text match.
- `kind.json`: `SessionLabel.kind(of:)`, what a label names (an issue, a pull request,
  finished work or nothing), which colours its chip (#2958).
