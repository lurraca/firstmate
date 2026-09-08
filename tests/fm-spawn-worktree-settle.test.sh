#!/usr/bin/env bash
# Behavioral regression coverage for fm-spawn.sh treehouse-get delivery,
# directory-identity detection, settling, and bounded failure.
#
# On some tmux/WSL setups a brand-new window's pane_current_path transiently
# reports a stale, unrelated-but-real path on the very first poll, before the
# pane actually settles into the worktree treehouse get moved it to. That stale
# path still passes the loop's "differs from the project" check and
# validate_spawn_worktree's "is a real, distinct worktree" check (it IS a real
# git checkout, just the wrong one), so a naive single-read loop silently
# records the wrong worktree= in state/<id>.meta. This test simulates that
# transient-then-settled pane_current_path sequence with a fake tmux and
# asserts the recorded worktree resolves to the real, settled worktree, never
# the stale first read.
#
# The same loop has a second transient to survive: `treehouse get` reports the
# REPOSITORY's primary checkout as its own cwd while it is still preparing a
# slot. From a linked spawning home that path is not the project, so a poll
# comparing only against the project adopted it and the isolation guard then
# refused the launch. The cases below cover both the transient and the pane
# that never leaves the primary at all.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)

# make_settle_fakebin <dir> builds a controllable tmux public-interface fake.
# It can return a transient stale cwd, a supplied path sequence, or a path that
# changes only after a configured delivery count.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ -n "${FM_FAKE_PANE_SEQUENCE_FILE:-}" ]; then
      line=$(sed -n "${n}p" "$FM_FAKE_PANE_SEQUENCE_FILE")
      [ -n "$line" ] || line=$(tail -1 "$FM_FAKE_PANE_SEQUENCE_FILE")
      printf '%s\n' "$line"
    elif [ -n "${FM_FAKE_PATH_AFTER_SEND_COUNT:-}" ]; then
      sends=0
      [ -f "${FM_FAKE_SEND_COUNTFILE:-}" ] && sends=$(cat "$FM_FAKE_SEND_COUNTFILE")
      if [ "$sends" -ge "$FM_FAKE_PATH_AFTER_SEND_COUNT" ]; then
        printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
      else
        printf '%s\n' "${FM_FAKE_PROJECT_PATH:-}"
      fi
    elif [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    case "$*" in
      *"treehouse get"*)
        n=0
        [ -f "${FM_FAKE_SEND_COUNTFILE:-}" ] && n=$(cat "$FM_FAKE_SEND_COUNTFILE")
        n=$((n + 1))
        [ -z "${FM_FAKE_SEND_COUNTFILE:-}" ] || printf '%s\n' "$n" > "$FM_FAKE_SEND_COUNTFILE"
        [ -z "${FM_FAKE_SEND_LOG:-}" ] || printf '%s\n' "${4:-}" >> "$FM_FAKE_SEND_LOG"
        ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_settle_case <name> <id> <stale_reads> builds a home, a primary project
# with a real worktree (the eventual settled path), and a separate real git
# repo standing in for the stale path (a real checkout of something else
# entirely, distinct from both the project and the worktree - mirroring the
# live incident where the stale read was another real firstmate home).
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_init_commit "$stale"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise settled-worktree detection for $id.

## Firstmate spec
Record only the pane's stable worktree.
EOF
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

read_settle_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# A single stale first read (the exact incident) must not be accepted: the
# loop should keep polling until two consecutive reads agree, landing on the
# real settled worktree instead.
test_single_stale_first_read_is_not_accepted() {
  local rec id out status
  id=settle-single-stale-z1
  rec=$(make_settle_case settle-single "$id" 1)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  pass "a single transient stale pane_current_path read is not accepted as the worktree"
}

# A pane that reports the real worktree from the very first read costs exactly
# one confirming read - not a whole extra polling cycle on top of it. Counting
# the pane reads measures the loop itself; wall-clock time would fold in every
# other cost of a spawn (fetch, trust registration) and drift with the machine.
test_already_settled_pane_costs_one_confirm_read() {
  local rec id out status reads
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  reads=$(cat "$COUNTFILE")
  [ "$reads" -eq 2 ] || fail "already-settled pane took $reads reads to confirm - expected the first read plus one confirmation"
  pass "an already-settled pane confirms on the next read, not a whole extra cycle"
}

# make_primary_case <name> <id> <stale_reads> builds the linked-home shape: the
# spawning project is itself a LINKED worktree of the repository, and the path
# the pane transiently reports is that repository's PRIMARY checkout. `treehouse
# get` reports the repository it is preparing a slot from as its own cwd while
# it is still fetching and checking out, so the pane reads the primary for the
# first seconds. The primary is not the spawning project, so a poll that only
# compares against the project accepts it as the worktree, and the isolation
# guard then refuses the launch even though treehouse went on to enter a real
# slot. The settled path is a second linked worktree of the same repository.
make_primary_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home primary proj wt fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  primary="$case_dir/primary"
  proj="$case_dir/mate"
  wt="$case_dir/slot"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$primary" "$proj" "mate-$name"
  git -C "$primary" worktree add --quiet -b "slot-$name" "$wt"
  fm_test_spawn_brief "$home" "$id" "Exercise primary-checkout transient detection for $id."
  printf '%s\n' "$case_dir|$home|$proj|$wt|$primary|$fakebin|$countfile|$stale_reads"
}

# The exact incident: the pane reports the repository primary for the first
# reads, then settles into the slot treehouse actually created. The primary must
# never be adopted as the worktree, so the spawn lands on the settled slot.
test_transient_primary_checkout_is_not_accepted() {
  local rec id out status
  id=settle-primary-transient-z3
  rec=$(make_primary_case settle-primary-transient "$id" 3)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane leaves the primary checkout"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the repository primary checkout as the worktree"
  pass "a transient primary-checkout pane read is not accepted as the worktree"
}

# A pane that never leaves the primary checkout must still fail at the deadline
# rather than waiting forever or recording the primary.
test_primary_checkout_that_never_settles_fails_at_the_deadline() {
  local rec id out status
  id=settle-primary-stuck-z4
  rec=$(make_primary_case settle-primary-stuck "$id" 100000)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a pane that never left the primary checkout"$'\n'"$out"
  assert_contains "$out" "did not enter an isolated worktree" \
    "spawn did not explain that the pane never reached an isolated worktree"
  assert_contains "$out" "$STALE_DIR" \
    "the refusal did not name the path the pane kept reporting"
  assert_contains "$out" "repository's primary checkout" \
    "the refusal did not say why that path was rejected"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "a pane stuck on the primary checkout fails loudly at the deadline"
}

run_startup_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PROJECT_PATH="$PROJ_DIR" FM_FAKE_PANE_PATH="$WT_DIR" \
    FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

test_swallowed_first_delivery_is_retried_safely() {
  local rec id out status send_count send_log command_count command_file allocation_count
  id=settle-swallowed-first-z3
  rec=$(make_settle_case settle-swallowed-first "$id" 0)
  read_settle_record "$rec"
  send_count="$CASE_DIR/treehouse-send-count"
  send_log="$CASE_DIR/treehouse-send.log"

  out=$(FM_TREEHOUSE_GET_SEND_ATTEMPTS=2 FM_TREEHOUSE_GET_RETRY_WAIT_SECS=0 \
    FM_FAKE_PATH_AFTER_SEND_COUNT=2 FM_FAKE_SEND_COUNTFILE="$send_count" \
    FM_FAKE_SEND_LOG="$send_log" run_startup_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should recover when the first treehouse-get delivery is swallowed"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "retry success did not record the isolated worktree"
  [ "$(cat "$send_count")" = 2 ] || fail "expected exactly two bounded treehouse-get deliveries"
  command_count=$(sort -u "$send_log" | wc -l | tr -d ' ')
  [ "$command_count" = 1 ] || fail "treehouse-get retries did not reuse one idempotent delivery command"
  assert_grep 'FM_TREEHOUSE_GET_TOKEN' "$send_log" \
    "retried delivery was not guarded against duplicate allocation"

  # Execute the delivered public command in a shell lineage that replays the
  # same queued command from inside treehouse. The exported token must reach
  # that child shell and keep the fake allocation count at one.
  command_file="$CASE_DIR/delivered-command.sh"
  allocation_count="$CASE_DIR/allocation-count"
  head -1 "$send_log" > "$command_file"
  cat > "$FAKEBIN_DIR/treehouse" <<'SH'
#!/usr/bin/env bash
n=0
[ -f "$FM_FAKE_ALLOCATION_COUNT" ] && n=$(cat "$FM_FAKE_ALLOCATION_COUNT")
printf '%s\n' "$((n + 1))" > "$FM_FAKE_ALLOCATION_COUNT"
bash "$FM_FAKE_DUPLICATE_COMMAND_FILE"
SH
  chmod +x "$FAKEBIN_DIR/treehouse"
  FM_FAKE_ALLOCATION_COUNT="$allocation_count" \
    FM_FAKE_DUPLICATE_COMMAND_FILE="$command_file" \
    PATH="$FAKEBIN_DIR:$PATH" bash "$command_file"
  [ "$(cat "$allocation_count")" = 1 ] || fail "queued retry started a duplicate treehouse allocation"
  pass "a swallowed first delivery is retried with one idempotent treehouse allocation token"
}

test_delivery_timeout_is_bounded() {
  local rec id out status send_count fake_sleep
  id=settle-bounded-timeout-z4
  rec=$(make_settle_case settle-bounded-timeout "$id" 0)
  read_settle_record "$rec"
  send_count="$CASE_DIR/treehouse-send-count"
  fake_sleep="$FAKEBIN_DIR/sleep"
  cat > "$fake_sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake_sleep"

  set +e
  out=$(FM_TREEHOUSE_GET_SEND_ATTEMPTS=2 FM_TREEHOUSE_GET_RETRY_WAIT_SECS=0 \
    FM_FAKE_PATH_AFTER_SEND_COUNT=999 FM_FAKE_SEND_COUNTFILE="$send_count" \
    run_startup_spawn "$id")
  status=$?
  set -e
  expect_code 1 "$status" "spawn should fail when no delivery enters a worktree"
  assert_contains "$out" "treehouse get did not enter an isolated worktree within 60s" \
    "bounded failure did not explain the startup timeout"
  [ "$(cat "$send_count")" = 2 ] || fail "timeout exceeded its configured delivery-attempt bound"
  assert_absent "$HOME_DIR/state/$id.meta" "timeout must not publish task metadata"
  pass "treehouse-get retries stop at the configured attempt bound and retain the startup timeout"
}

test_case_spelling_obeys_directory_identity() {
  local case_dir home project case_alias expected_wt separate_wt fakebin countfile sequence id out status
  case_dir="$TMP_ROOT/case-directory-identity"
  home="$case_dir/home"
  project="$case_dir/CaseProject"
  case_alias="$case_dir/caseproject"
  separate_wt="$case_dir/isolated-worktree"
  id=settle-case-identity-z5
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise directory-identity selection for $id.

## Firstmate spec
Record only the directory selected by filesystem identity.
EOF
  touch "$home/state/.last-watcher-beat"

  mkdir -p "$project"
  if [ -d "$case_alias" ]; then
    rm -rf "$project"
    fm_git_worktree "$project" "$separate_wt" case-insensitive-wt
    expected_wt=$separate_wt
    sequence="$case_dir/pane-sequence"
    printf '%s\n%s\n%s\n%s\n' "$case_alias" "$case_alias" "$separate_wt" "$separate_wt" > "$sequence"
  else
    rm -rf "$project"
    fm_git_worktree "$project" "$case_alias" case-sensitive-wt
    expected_wt=$case_alias
    sequence="$case_dir/pane-sequence"
    printf '%s\n%s\n' "$case_alias" "$case_alias" > "$sequence"
  fi

  fakebin=$(make_settle_fakebin "$case_dir/fake")
  countfile="$case_dir/pane-call-count"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_SEQUENCE_FILE="$sequence" FM_FAKE_PANE_COUNTFILE="$countfile" \
    PATH="$fakebin:$PATH" "$SPAWN" "$id" "$project" --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "spawn should apply the filesystem's actual case behavior"
  assert_grep "worktree=$expected_wt" "$home/state/$id.meta" \
    "spawn did not record the directory selected by filesystem identity"
  if [ "$expected_wt" = "$separate_wt" ]; then
    assert_no_grep "worktree=$case_alias" "$home/state/$id.meta" \
      "case alias of the primary was mistaken for an isolated worktree"
    pass "case-insensitive spelling aliases remain the primary directory until a real worktree appears"
  else
    pass "case-sensitive paths that differ only by case remain distinct worktree directories"
  fi
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_read
test_transient_primary_checkout_is_not_accepted
test_primary_checkout_that_never_settles_fails_at_the_deadline
test_swallowed_first_delivery_is_retried_safely
test_delivery_timeout_is_bounded
test_case_spelling_obeys_directory_identity

echo "# all fm-spawn-worktree-settle tests passed"
