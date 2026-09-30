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

# ---- general ----------------------------------------------------------------

run 1 bogus-cmd
t "unknown command fails" "1" "$RUN_EXIT"

run 1
t "no command fails" "1" "$RUN_EXIT"

echo
echo "pass: $pass  fail: $fail"
[ "$fail" -eq 0 ]
