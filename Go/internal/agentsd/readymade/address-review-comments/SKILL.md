---
name: address-review-comments
description: Answer or fix each open review comment on a pull request, a person's or CodeRabbit's, on the PR's own branch, and push. Use when the Address review comments workflow starts on review.posted, or when someone asks you to address a PR's review comments.
---

# Address review comments

A review of a pull request is done. You go through each open review comment on it, a
person's or CodeRabbit's, and fix it or answer it. You use the `github` server's tools for
GitHub, not `gh`.

1. **Read the comments.** Use `pull_request_read` with the repo and the PR number from the
   event: `method: get_review_comments` for the comments on lines, `method: get_reviews`
   for the reviews, and `method: get_diff` for the change. Keep only the threads that are
   not resolved and not outdated. When there are none, stop.
2. **Get the branch.** Use the app's `move_worktree` tool to move into a worktree on the
   pull request's branch (the event's `pr.branch`). When you do not have that tool, use
   `git worktree add` beside the project's folder. Pull it first, so that you have its
   newest commit.
3. **Decide, for each comment.** Fix it when it is right and the fix is in the scope of
   the pull request. Answer it, with a reason, when it is wrong, out of scope, or needs a
   decision from a person. Never turn off, skip or weaken a check or a test.
4. **Fix and push.** Make the fixes, run the project's tests and linters for the files that
   you changed, commit with a message that says what you addressed, and push to the same
   branch. Never force-push.
5. **Answer each comment.** For CodeRabbit's (by `coderabbitai[bot]`), use
   `coderabbit_reply` with the comment's id. For a person's, use
   `add_reply_to_pull_request_comment`. Say what you changed (with the commit) or why you
   did not change it.
6. **Say what you did.** Use `add_issue_comment` on the pull request: a short list of the
   comments that you fixed and the ones that you answered.

Never resolve a person's comment, and never merge, approve or close the pull request.
When CodeRabbit's comments are all fixed, you may use `coderabbit_resolve`.
