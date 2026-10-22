#!/usr/bin/env bash
# Tests for the gh-pr-threads extension. Runs the real script against a stub gh
# on PATH (tests/bin/gh) with fixture responses in tests/fixtures/.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ext="$here/../gh-pr-threads"
stub_bin="$here/bin"
fixture="$here/fixtures/list.json"

pass=0
fail=0

t() { # t <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1"
    echo "  expected: $2"
    echo "  actual:   $3"
  fi
}

# run <expected-exit> <args...>; captures stdout in RUN_OUT, exit in RUN_EXIT,
# the stub's argv log for the last invocation in RUN_LOG
run() {
  local expected_exit="$1"
  shift
  STUB_LOG="$(mktemp)"
  STUB_LIST_FIXTURE="$fixture"
  export STUB_LOG STUB_LIST_FIXTURE
  RUN_EXIT=0
  RUN_OUT="$(PATH="$stub_bin:$PATH" "$ext" "$@" 2>/dev/null)" || RUN_EXIT=$?
  RUN_LOG="$STUB_LOG"
  unset STUB_LOG STUB_LIST_FIXTURE
  t "exit code for: gh pr-threads $*" "$expected_exit" "$RUN_EXIT"
}

# assert the last stub invocation's argv contains an exact element
log_contains() { # log_contains <needle>
  tail -1 "$RUN_LOG" | jq -e --arg n "$1" 'any(.[]; . == $n)' >/dev/null
}

check_log() { # check_log <name> <needle>
  if log_contains "$2"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1: argv does not contain '$2'"
    tail -1 "$RUN_LOG" | jq . >&2
  fi
}

# assert the last stub invocation's argv does NOT contain an exact element
log_not_contains() { # log_not_contains <name> <needle>
  if tail -1 "$RUN_LOG" | jq -e --arg n "$2" 'any(.[]; . == $n)' >/dev/null; then
    fail=$((fail + 1))
    echo "FAIL: $1: argv unexpectedly contains '$2'"
    tail -1 "$RUN_LOG" | jq . >&2
  else
    pass=$((pass + 1))
  fi
}

jqq() { jq -r "$2" <<<"$1"; } # jqq <json> <filter>

# ---- list -------------------------------------------------------------------

run 0 list o r 7
out="$RUN_OUT"
t "list: prUrl" "https://github.com/o/r/pull/7" "$(jqq "$out" .prUrl)"
t "list: unresolvedCount" "2" "$(jqq "$out" .unresolvedCount)"
t "list: unresolved thread count" "2" "$(jqq "$out" '.threads | length')"
t "list: thread id" "PRRT_thread1" "$(jqq "$out" '.threads[0].id')"
t "list: comment databaseId" "111" "$(jqq "$out" '.threads[0].comments[0].databaseId')"
t "list: human not bot" "false" "$(jqq "$out" '.threads[0].comments[0].authorIsBot')"
t "list: bot flagged" "true" "$(jqq "$out" '.threads[0].comments[1].authorIsBot')"
t "list: null author -> ghost" "ghost" "$(jqq "$out" '.threads[1].comments[0].author')"
t "list: outdated kept" "true" "$(jqq "$out" '.threads[1].isOutdated')"
t "list: resolved filtered" "PRRT_thread1,PRRT_thread3" "$(jqq "$out" '[.threads[].id] | join(",")')"

run 0 list o r 7 --all
t "list --all: includes resolved" "3" "$(jqq "$RUN_OUT" '.threads | length')"

run 1 list o r 7 --bogus
t "list: unknown flag fails" "1" "$RUN_EXIT"

STUB_GRAPHQL_ERRORS=1 run 1 list o r 999
t "list: graphql error propagates" "1" "$RUN_EXIT"

STUB_FAIL=1 run 1 list o r 7
t "list: gh failure propagates" "1" "$RUN_EXIT"

run 0 list owner-name repo-name 123
check_log "list: -F flag used" "-F"
check_log "list: owner typed arg" "owner=owner-name"
check_log "list: repo typed arg" "repo=repo-name"
check_log "list: pr typed arg" "pr=123"

# ---- reply ------------------------------------------------------------------

run 0 reply o r 7 --in-reply-to 111 --body "Fixed. Added a guard."
out="$RUN_OUT"
t "reply: comment id" "9001" "$(jqq "$out" '.commentId')"
t "reply: url present" "https://github.com/o/r/pull/1#discussioncomment-9001" "$(jqq "$out" '.url')"
t "reply: one gh call (no resolve)" "1" "$(wc -l <"$RUN_LOG")"
check_log "reply: in_reply_to forwarded" "in_reply_to=111"

run 0 reply o r 7 --in-reply-to PRRC_c1 --body-file - <<<"converted body"
t "reply PRRC_: lookup + post = 2 gh calls" "2" "$(wc -l <"$RUN_LOG")"
check_log "reply PRRC_: converted to 4242" "in_reply_to=4242"
check_log "reply: stdin body forwarded" "body=converted body"

run 0 reply o r 7 --in-reply-to 111 --body "done" --resolve-thread PRRT_thread1
t "reply --resolve-thread: post + resolve = 2 gh calls" "2" "$(wc -l <"$RUN_LOG")"
t "reply --resolve-thread: resolve json emitted" "true" "$(jqq "$RUN_OUT" '.isResolved' | tail -1)"

run 1 reply o r 7 --in-reply-to 111 --body-file /nonexistent/file
t "reply: missing body file fails" "1" "$RUN_EXIT"

run 1 reply o r 7 --in-reply-to 111
t "reply: no body fails" "1" "$RUN_EXIT"

run 1 reply o r 7 --in-reply-to 111 --body x --body-file -
t "reply: body and body-file conflict" "1" "$RUN_EXIT"

run 1 reply o r 7 --body x
t "reply: missing --in-reply-to fails" "1" "$RUN_EXIT"

run 1 reply o r 7 --in-reply-to notanid --body x
t "reply: bad comment id fails" "1" "$RUN_EXIT"

STUB_POST_FAIL=1 run 1 reply o r 7 --in-reply-to 111 --body x
t "reply: post failure propagates" "1" "$RUN_EXIT"

# ---- resolve ----------------------------------------------------------------

run 0 resolve PRRT_thread1
t "resolve: isResolved true" "true" "$(jqq "$RUN_OUT" '.isResolved')"
t "resolve: threadId echoed" "PRRT_thread1" "$(jqq "$RUN_OUT" '.threadId')"
check_log "resolve: threadId forwarded" "threadId=PRRT_thread1"

run 1 resolve 12345
t "resolve: non-PRRT id rejected" "1" "$RUN_EXIT"

run 1 resolve
t "resolve: missing arg fails" "1" "$RUN_EXIT"

# ---- submit-review ----------------------------------------------------------

run 0 submit-review o r 9479 --event COMMENT --body "Looks good overall"
out="$RUN_OUT"
t "submit-review: review id" "5001" "$(jqq "$out" '.reviewId')"
t "submit-review: state COMMENTED" "COMMENTED" "$(jqq "$out" '.state')"
t "submit-review: url" "https://github.com/o/r/pull/1#pullrequestreview-5001" "$(jqq "$out" '.url')"
t "submit-review: submittedAt" "2026-10-22T12:00:00Z" "$(jqq "$out" '.submittedAt')"
check_log "submit-review: endpoint" "repos/o/r/pulls/9479/reviews"
check_log "submit-review: event forwarded" "event=COMMENT"
check_log "submit-review: body forwarded" "body=Looks good overall"

run 0 submit-review o r 7 --event approve --body x
t "submit-review: lowercase event normalized" "APPROVED" "$(jqq "$RUN_OUT" '.state')"
check_log "submit-review: normalized event forwarded" "event=APPROVE"

run 0 submit-review o r 7 --event APPROVE
t "submit-review: approve without body" "APPROVED" "$(jqq "$RUN_OUT" '.state')"
check_log "submit-review: approve event present" "event=APPROVE"
# no element of any argv may start with body= (not just the literal body=x)
if tail -1 "$RUN_LOG" | jq -e 'any(.[]; startswith("body="))' >/dev/null; then
  fail=$((fail + 1))
  echo "FAIL: submit-review approve: argv unexpectedly contains a body= element"
  tail -1 "$RUN_LOG" | jq . >&2
else
  pass=$((pass + 1))
fi

run 0 submit-review o r 7 --event REQUEST_CHANGES --body-file - <<<"please fix"
t "submit-review: request changes state" "CHANGES_REQUESTED" "$(jqq "$RUN_OUT" '.state')"
check_log "submit-review: request changes event forwarded" "event=REQUEST_CHANGES"
check_log "submit-review: stdin body forwarded" "body=please fix"

tmp_body="$(mktemp)"
printf 'lgtm after the null check' >"$tmp_body"
tmp_empty="$(mktemp)"

run 0 submit-review o r 7 --event COMMENT --body-file "$tmp_body"
t "submit-review: file body state" "COMMENTED" "$(jqq "$RUN_OUT" '.state')"
check_log "submit-review: file body forwarded" "body=lgtm after the null check"

run 0 submit-review o r 7 --event=COMMENT --body=eq-form-body
t "submit-review: equals form state" "COMMENTED" "$(jqq "$RUN_OUT" '.state')"
check_log "submit-review: equals form event" "event=COMMENT"
check_log "submit-review: equals form body" "body=eq-form-body"

run 0 submit-review o r 7 --event=APPROVE --body-file="$tmp_body"
t "submit-review: equals body-file form" "APPROVED" "$(jqq "$RUN_OUT" '.state')"
check_log "submit-review: equals body-file forwarded" "body=lgtm after the null check"

# validation failures: must fail before any gh invocation (stub log stays empty)
fail_before_call() { # fail_before_call <name> <args...>
  local name="$1"
  shift
  run 1 "$@"
  t "submit-review $name: no gh call made" "0" "$(wc -l <"$RUN_LOG")"
}

fail_before_call "missing event" submit-review o r 7 --body x
fail_before_call "trailing event" submit-review o r 7 --event
fail_before_call "trailing body" submit-review o r 7 --event COMMENT --body
fail_before_call "trailing body-file" submit-review o r 7 --event COMMENT --body-file
fail_before_call "unknown arg" submit-review o r 7 --event COMMENT --body x --bogus
fail_before_call "invalid event PENDING" submit-review o r 7 --event PENDING
fail_before_call "invalid event NOPE" submit-review o r 7 --event NOPE
fail_before_call "comment without body" submit-review o r 7 --event COMMENT
fail_before_call "request changes without body" submit-review o r 7 --event REQUEST_CHANGES
fail_before_call "empty body comment" submit-review o r 7 --event COMMENT --body ""
fail_before_call "empty body approve" submit-review o r 7 --event APPROVE --body ""
fail_before_call "empty body file" submit-review o r 7 --event COMMENT --body-file "$tmp_empty"
fail_before_call "empty stdin body" submit-review o r 7 --event COMMENT --body-file - < /dev/null
fail_before_call "body and body-file conflict" submit-review o r 7 --event COMMENT --body "" --body-file "$tmp_body"
fail_before_call "body and body-file both set" submit-review o r 7 --event COMMENT --body x --body-file "$tmp_body"
fail_before_call "missing body file" submit-review o r 7 --event COMMENT --body-file /nonexistent/file
fail_before_call "body file is a directory" submit-review o r 7 --event COMMENT --body-file "$here"
fail_before_call "wrong positional count" submit-review o r

# stub-level API failure propagates with the diagnostic in the message
# one invocation asserts both the exit code and the composed stderr diagnostic
review_err="$(PATH="$stub_bin:$PATH" STUB_LOG="$(mktemp)" STUB_LIST_FIXTURE="$fixture" STUB_REVIEW_FAIL=1 "$ext" submit-review o r 7 --event COMMENT --body x 2>&1 >/dev/null)"
review_exit=$?
t "exit code for: gh pr-threads submit-review o r 7 --event COMMENT --body x (stub failure)" "1" "$review_exit"
case "$review_err" in
  *"submitting review failed: stub gh: simulated review submission failure"*)
    pass=$((pass + 1)) ;;
  *)
    fail=$((fail + 1))
    echo "FAIL: submit-review: stub failure message not surfaced"
    echo "  actual stderr: $review_err" ;;
esac
unset STUB_REVIEW_FAIL

rm -f "$tmp_body" "$tmp_empty"

# ---- general ----------------------------------------------------------------

run 1 bogus-cmd
t "unknown command fails" "1" "$RUN_EXIT"

run 1
t "no command fails" "1" "$RUN_EXIT"

echo
echo "pass: $pass  fail: $fail"
[ "$fail" -eq 0 ]
