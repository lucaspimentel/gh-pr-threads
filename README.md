# gh-pr-threads

A [gh CLI extension](https://cli.github.com/manual/gh_extension) for PR review
threads: list them, reply to them, resolve them, and submit reviews, without
hand-writing GraphQL in shell one-liners.

Wraps the `gh api` calls the
[address-pr-comments](https://github.com/lucaspimentel/pi-extensions) skill
needs (including the pull request reviews POST) so they can be allow-listed
narrowly by permission systems (e.g. pi's `pi-tool-permissions`) instead of
allowing raw `gh api`, and so the steps are repeatable and testable.

## Install

```sh
gh extension install lucaspimentel/gh-pr-threads
```

Requires `gh` and `jq` on PATH.

## Usage

### `list`

```sh
gh pr-threads list <owner> <repo> <pr> [--all]
```

Fetches all review threads and prints JSON:

```json
{
  "prUrl": "https://github.com/o/r/pull/7",
  "unresolvedCount": 2,
  "threads": [
    {
      "id": "PRRT_...",              // GraphQL node id, for `resolve`
      "isResolved": false,
      "isOutdated": false,           // outdated threads are kept, not filtered
      "path": "src/a.cs",
      "line": 42,
      "startLine": 40,
      "comments": [
        {
          "id": "PRRC_...",          // GraphQL node id
          "databaseId": 111,         // numeric id, for --in-reply-to
          "author": "alice",
          "authorIsBot": false,      // true when author.__typename == "Bot"
          "body": "Consider null check here",
          "createdAt": "2026-09-30T10:00:00Z",
          "url": "https://github.com/o/r/pull/7#discussioncomment-111"
        }
      ]
    }
  ]
}
```

By default resolved threads are filtered out; `--all` includes them. The
numeric `databaseId` of every comment is fetched in the same query, so callers
never need the separate PRRC node-id lookup.

### `reply`

```sh
gh pr-threads reply <owner> <repo> <pr> --in-reply-to <comment-id> \
  (--body <text> | --body-file <path | ->) [--resolve-thread <thread-id>]
```

Posts a reply to a review comment. `--in-reply-to` accepts the numeric
`databaseId` from `list` or a `PRRC_...` GraphQL node id (converted via a
lookup). `--body-file -` reads the reply from stdin. `--resolve-thread` also
resolves the thread (`PRRT_...` id) in the same invocation.

Prints one JSON object for the posted comment, then one for the resolution if
requested:

```json
{"commentId":9001,"nodeId":"PRRC_new1","url":"https://github.com/o/r/pull/7#discussioncomment-9001"}
{"threadId":"PRRT_thread1","isResolved":true}
```

### `resolve`

```sh
gh pr-threads resolve <thread-id>
```

Resolves a review thread by its `PRRT_...` GraphQL node id and prints
`{"threadId":"...","isResolved":true}`.

### `submit-review`

```sh
gh pr-threads submit-review <owner> <repo> <pr> --event COMMENT|APPROVE|REQUEST_CHANGES \
  [--body <text> | --body-file <path | ->]
```

Creates and submits a *new* pull request review; it does not submit an
existing pending review by id. `--event` is required: without it GitHub would
leave a pending draft review, so the command refuses to guess. `--body` is
required for `COMMENT` and `REQUEST_CHANGES` and optional for `APPROVE`; an
explicitly empty body (`--body ""` or an empty `--body-file`) is always
rejected. When no body is given (valid only for `APPROVE`), no `body` field
is sent at all. `--body-file -` reads the body from stdin.

Line comments (the `comments` array) and `commit_id` are deliberately not
supported to keep the surface minimal.

Prints one JSON object for the submitted review:

```json
{"reviewId":5001,"state":"APPROVED","url":"https://github.com/o/r/pull/1#pullrequestreview-5001","submittedAt":"2026-10-22T12:00:00Z"}
```

## Permissions (pi-tool-permissions)

`list` is read-only and safe to allow silently; `reply`, `resolve`, and
`submit-review` are writes and should stay on the ask path. `submit-review`
can APPROVE a pull request, the most powerful write in the set, which is why
it stays on the ask path:

```json
{
  "allow": ["Bash(gh pr-threads list *)"],
  "ask":   ["Bash(gh pr-threads reply *)", "Bash(gh pr-threads resolve *)",
            "Bash(gh pr-threads submit-review *)"]
}
```

## Development

```sh
tests/run.sh      # runs the suite against a stub gh; no network
shellcheck gh-pr-threads tests/bin/gh tests/run.sh
```
