#!/usr/bin/env bash
# Stubbed DeepSeek Harness only (tests/fixtures/fake_dsh.py): command shape and sandbox grants,
# model/patch overlays, review consent, lane-result extraction from prose and fences,
# and the dsh wave (no router, its own PID marker). No network, no model call.
# Lane cases run twice: through the super-board-dsh-lane.sh shim and through
# super-board-lane.sh --backend dsh.
set -euo pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd)
if [ -z "${SB_LANE_ENTRY:-}" ]; then
  for entry in shim backend; do SB_LANE_ENTRY=$entry bash "$0" || { echo "FAIL: entry $entry" >&2; exit 1; }; done
  T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  RC=0; bash "$KIT/scripts/super-board-lane.sh" --backend gemini --config x --card '{}' --lane build >/dev/null 2>"$T/err" || RC=$?
  [ "$RC" -eq 64 ] && grep -q 'valid backends: codex, dsh' "$T/err" || { echo 'FAIL: the backend list must name dsh' >&2; cat "$T/err" >&2; exit 1; }
  grep -q '^exec .*super-board-lane.sh" --backend dsh "\$@"$' "$KIT/scripts/super-board-dsh-lane.sh" || { echo 'FAIL: dsh-lane must be a one-line shim' >&2; exit 1; }
  grep -q '^exec .*super-board-codex-wave.sh" --backend dsh "\$@"$' "$KIT/scripts/super-board-dsh-wave.sh" || { echo 'FAIL: dsh-wave must be a one-line shim' >&2; exit 1; }
  echo 'PASS: test-dsh-lane.sh (shim + --backend dsh; backend list)'
  exit 0
fi
case "$SB_LANE_ENTRY" in
  shim) LAUNCHER=("$KIT/scripts/super-board-dsh-lane.sh") ;;
  *) LAUNCHER=("$KIT/scripts/super-board-lane.sh" --backend dsh) ;;
esac
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
T=$(cd "$T" && pwd -P)  # dsh wants physical paths; macOS /var is a link
mkdir -p "$T/bin" "$T/repo/sub" "$T/cache"
git init -q "$T/repo"
python3 "$KIT/tests/fixtures/install_worker_skills.py" "$T/repo"
export SUPER_BOARD_SKILLS_HOME="$T/home"; mkdir -p "$SUPER_BOARD_SKILLS_HOME"
unset SUPER_BOARD_DSH_PATCH
cat > "$T/bin/gh" <<'PYGH'
#!/usr/bin/env python3
import json,sys
args=sys.argv[1:]
if args[:2]==['issue','view']:
    print(json.dumps({'labels':[]} if args[args.index('--json')+1] == 'labels' else {'number':int(args[2]),'title':'fixture','body':''}))
else:
    sys.exit('unexpected gh fixture call: '+str(args))
PYGH
cp "$KIT/tests/fixtures/fake_dsh.py" "$T/bin/dsh"
chmod +x "$T/bin/gh" "$T/bin/dsh"
export SB_DSH_TEST_LOG="$T/calls.jsonl"
export PATH="$T/bin:$PATH"
cd "$T/repo/sub"   # dsh must still start at the repository root
echo '{"verify_commands":["git diff --check"]}' > "$T/config.json"
CARD='{"number":1,"status":"Ready","title":"example"}'
lane() { bash "${LAUNCHER[@]}" --config "$T/config.json" --card "$CARD" --lane "$@" 2>"$T/stderr"; }
wave() { bash "$KIT/scripts/super-board-dsh-wave.sh" --config "$T/config.json" --cards "$CARDS" "$@" 2>"$T/stderr"; }
fail() { echo "FAIL: $*" >&2; cat "$T/stderr" >&2; exit 1; }
last() { tail -1 "$SB_DSH_TEST_LOG"; }

# Review needs the owner's explicit --dsh; fallback needs usage_fallback "dsh".
RC=0; lane review >"$T/out" || RC=$?
[ "$RC" -eq 78 ] && [ ! -e "$SB_DSH_TEST_LOG" ] || fail 'fallback review must refuse before dsh'
RC=0; lane build >"$T/out" || RC=$?
[ "$RC" -eq 78 ] && [ ! -e "$SB_DSH_TEST_LOG" ] || fail 'build without --dsh or usage_fallback "dsh" must refuse'
lane review --dsh >"$T/out"
jq -e '.status == "advanced" and .column == "Done" and .prUrl == null' "$T/out" >/dev/null || fail 'explicit review, result pulled out of prose and a ```json fence'
grep -q -- '--expect-head' "$SB_DSH_TEST_LOG" || fail 'review must pin reviewed head to merge gate'

# Command shape: headless, workspace-write, never ask, the git dir granted, task on stdin.
python3 - "$(last)" "$T/repo" <<'PY'
import json, sys
call = json.loads(sys.argv[1]); args = call['args']; root = sys.argv[2]
assert args == ['headless', '--permission-mode', 'workspace-write', '--approval-policy', 'never',
                '--add-dir', root + '/.git', '-'], args
assert call['cwd'] == root, call['cwd']
prompt = call['prompt']
assert 'Read .agents/skills/super-review/SKILL.md and .agents/skills/super-board/references/run.md' in prompt
assert '--host dsh' in prompt and 'as a DeepSeek Harness lane worker' in prompt
assert 'do not launch Claude or other sub-agents' in prompt and 'subagent_fork' in prompt
assert 'timeoutMs' in prompt and 'sandbox: file access denied' in prompt
assert 'danger-full-access' not in ' '.join(args)
PY

# Model: <provider>/<model> becomes a per-run agent-default-model overlay; flag beats config.
lane build --dsh=ollama/deepseek-v4-pro >"$T/out"
python3 - "$(last)" <<'PY'
import json, sys
call = json.loads(sys.argv[1]); args = call['args']
assert args[:3] == ['headless', '--patch', args[2]] and args[2].endswith('model.patch.yml'), args
text = call['patches'][args[2]]
assert 'id: agent-default-model' in text and 'provider: "ollama"' in text and 'model: "deepseek-v4-pro"' in text, text
PY
echo '{"dsh":{"model":"ollama/config-model"},"verify_commands":["git diff --check"]}' > "$T/config.json"
lane qa --dsh >"$T/out"
last | jq -e '.patches | to_entries[0].value | contains("model: \"config-model\"")' >/dev/null || fail 'dsh.model must reach the overlay'
lane qa --dsh=ollama/flag-model >"$T/out"
last | jq -e '.patches | to_entries[0].value | contains("model: \"flag-model\"")' >/dev/null || fail 'flag must beat config'
: > "$SB_DSH_TEST_LOG"
for bad in --dsh=deepseek-v4-pro --dsh=/x --dsh=ollama/; do
  RC=0; lane build "$bad" >"$T/out" || RC=$?
  [ "$RC" -eq 64 ] && grep -q '<provider>/<model>' "$T/stderr" || fail "model $bad without a provider must refuse (rc=$RC)"
done
RC=0; lane build --dsh= >"$T/out" || RC=$?
[ "$RC" -eq 64 ] || fail 'empty explicit model must refuse'
[ ! -s "$SB_DSH_TEST_LOG" ] || fail 'a refused model never starts dsh'

# The user's patch (provider setup) comes first, then the model pin; env beats config.
mkdir -p "$T/repo/.claude/super-board"
printf -- '- id: agent-default-model\n  config:\n    provider: ollama\n    model: deepseek-v4-pro\n' > "$T/repo/.claude/super-board/dsh.patch.yml"
printf -- '[]\n' > "$T/env.patch.yml"
echo '{"dsh":{"patch":".claude/super-board/dsh.patch.yml","add_dirs":["'"$T"'/cache"]},"usage_fallback":"dsh","verify_commands":["git diff --check"]}' > "$T/config.json"
lane build >"$T/out"
last | jq -e --arg p "$T/repo/.claude/super-board/dsh.patch.yml" --arg c "$T/cache" \
  '.args == ["headless", "--patch", $p, "--permission-mode", "workspace-write", "--approval-policy", "never", "--add-dir", ($p | sub("/.claude/super-board/dsh.patch.yml$"; "/.git")), "--add-dir", $c, "-"]' >/dev/null \
  || fail "relative dsh.patch resolves from the repo root; add_dirs follow the git dir: $(last | jq -c .args)"
SUPER_BOARD_DSH_PATCH="$T/env.patch.yml" lane build --dsh=ollama/pinned >"$T/out"
last | jq -e --arg e "$T/env.patch.yml" '.args[1:4] == ["--patch", $e, "--patch"] and (.args[4] | endswith("model.patch.yml"))' >/dev/null \
  || fail "SUPER_BOARD_DSH_PATCH beats dsh.patch and comes before the model pin: $(last | jq -c .args)"
RC=0; SUPER_BOARD_DSH_PATCH="$T/missing.yml" lane build >"$T/out" || RC=$?
[ "$RC" -eq 64 ] && grep -q 'patch file not found' "$T/stderr" || fail 'a missing patch file must refuse'
echo '{"dsh":{"add_dirs":["'"$T"'/nope"]},"usage_fallback":"dsh","verify_commands":["git diff --check"]}' > "$T/config.json"
RC=0; lane build >"$T/out" || RC=$?
[ "$RC" -eq 64 ] && grep -q 'add_dirs' "$T/stderr" || fail 'a missing add_dirs entry must refuse'

# Lane results: the last JSON object wins, nested objects are not mistaken for it, a bare
# object passes through, no object or a schema miss fails, and a nonzero exit never trusts JSON.
echo '{"verify_commands":["git diff --check"]}' > "$T/config.json"
GOOD='{"status":"advanced","column":"QA","detail":"d","prUrl":"https://github.com/o/r/pull/2","branch":"sb/1","priorFindings":{"fixed":1,"notFixed":0,"noLongerApplies":0}}'
SB_DSH_TEST_ANSWER="$GOOD" lane build --dsh >"$T/out" || fail 'a bare JSON answer passes'
[ "$(cat "$T/out")" = "$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])))' "$GOOD")" ] || fail 'a bare answer prints unchanged'
SB_DSH_TEST_ANSWER=$'First try: {"status":"failed","column":"Ready","detail":"x","prUrl":null,"branch":null,"priorFindings":null}\nFixed it.\n```\n'"$GOOD"$'\n```' lane build --dsh >"$T/out" || fail 'the last of two answers wins'
jq -e '.status == "advanced" and .priorFindings.fixed == 1' "$T/out" >/dev/null || fail 'last object, nested priorFindings kept whole'
while IFS= read -r BAD; do
  RC=0; SB_DSH_TEST_ANSWER="$BAD" lane build --dsh >"$T/out" || RC=$?
  [ "$RC" -eq 1 ] && jq -e '.status == "failed" and .column == "Ready"' "$T/out" >/dev/null || fail "bad answer must fail: $BAD"
done <<'BAD'
I could not finish the card.
```json {"status": "advanced", } ```
{"status":"done","column":"QA","detail":"d","prUrl":null,"branch":null,"priorFindings":null}
{"status":"advanced","column":"QA","detail":"d","prUrl":null,"priorFindings":null}
BAD
RC=0; SB_DSH_TEST_EXIT=1 lane build --dsh >"$T/out" || RC=$?
[ "$RC" -eq 1 ] && jq -e '.status == "failed" and (.detail | contains("dsh headless exited 1"))' "$T/out" >/dev/null || fail 'nonzero dsh never trusts success JSON'
RC=0; SB_DSH_TEST_STATUS=halted SB_DSH_TEST_DETAIL='verification-readiness: checks missing' lane build --dsh >"$T/out" || RC=$?
[ "$RC" -eq 9 ] || fail 'a structured readiness halt keeps exit 9'

# Wave: --dsh is required, there is no router, lanes run --backend dsh, the marker is dsh-wave.pid.
cd "$T/repo"
CARDS='[{"number":1,"status":"Ready"},{"number":2,"status":"Ready","labels":["qa"]},{"number":3,"status":"Review"}]'
echo '{"max_workers":1,"verify_commands":["git diff --check"]}' > "$T/config.json"
RC=0; wave >"$T/out" || RC=$?
[ "$RC" -eq 2 ] && grep -q 'exactly one explicit --dsh' "$T/stderr" || fail 'a dsh wave needs --dsh'
RC=0; wave --dsh --codex >"$T/out" || RC=$?
[ "$RC" -eq 2 ] || fail 'a dsh wave refuses --codex'
: > "$SB_DSH_TEST_LOG"
wave --dsh=ollama/deepseek-v4-pro --tier high --output "$T/wave.json" >"$T/out"
cmp "$T/out" "$T/wave.json" || fail 'file and stdout wave result differ'
jq -e '.halted == false and .cards[0].lanesRun == "build:advanced → qa:advanced → review:advanced" and .cards[1].lanesRun == "qa:advanced → review:advanced" and .cards[2].column == "Done"' "$T/out" >/dev/null || fail 'dsh wave routing/summary'
python3 - "$SB_DSH_TEST_LOG" <<'PY'
import json, pathlib, sys
calls = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
assert len(calls) == 6 and all(call['lane'] in ('build', 'qa', 'review') for call in calls), calls
assert all(call['active'] == 1 for call in calls)
assert all('model: "deepseek-v4-pro"' in list(call['patches'].values())[0] for call in calls)
PY
[ ! -e .claude/super-board/dsh-wave.pid ] && [ ! -e .claude/super-board/codex-wave.pid ] && [ -z "$(ls -A .claude/super-board/inflight)" ] || fail 'completed dsh wave leaves no PID/worker locks'
echo 123 > .claude/super-board/dsh-wave.pid
RC=0; wave --dsh >"$T/out" || RC=$?
[ "$RC" -eq 2 ] && grep -q 'DeepSeek Harness wave PID marker exists' "$T/stderr" || fail 'a live dsh marker blocks a second wave'
rm .claude/super-board/dsh-wave.pid
: > "$SB_DSH_TEST_LOG"
RC=0; SB_DSH_TEST_STATUS=halted wave --dsh >"$T/out" || RC=$?
[ "$RC" -eq 79 ] && [ "$(wc -l < "$SB_DSH_TEST_LOG" | tr -d ' ')" -eq 1 ] && jq -e '.halted' "$T/out" >/dev/null || fail 'halt stops all new dsh lane dispatch'
cd "$T"; mkdir bare; git init -q bare; cd bare
RC=0; wave --dsh >"$T/out" || RC=$?
[ "$RC" -eq 10 ] && jq -e '.halted and (.cards[0].detail | startswith("skills-readiness: missing"))' "$T/out" >/dev/null || fail "no .agents/skills halts the dsh wave on skills, got $RC"
echo "PASS: test-dsh-lane.sh [$SB_LANE_ENTRY] (command/sandbox/model/patch/review/extraction/wave)"
