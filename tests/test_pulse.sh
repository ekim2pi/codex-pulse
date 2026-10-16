#!/usr/bin/env bash
# codex-pulse 自测：全部用假 codex / 假 crontab 驱动，不消耗额度、不动你的 crontab。
# 运行： ./pulse.sh selftest   或   bash tests/test_pulse.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PULSE="$ROOT/pulse.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 让自测与宿主环境的代理设置解耦（用例里自己控制）
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
expect_contains() { # <name> <haystack> <needle>
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 （在 [$2] 里找不到 [$3]）"; fi
}
expect_empty() {
  if [[ -z "$2" ]]; then ok "$1"; else bad "$1 （本应为空，实际 [$2]）"; fi
}

# ------------------------------- 夹具 ---------------------------------------
BIN="$TMP/bin"; mkdir -p "$BIN"
SESS="$TMP/sessions"; mkdir -p "$SESS/2026/01/01"
MARK="$TMP/codex-ran"

cat >"$BIN/codex" <<EOF
#!/usr/bin/env bash
touch "$MARK"
[[ -n "\${FAKE_CODEX_SLEEP:-}" ]] && sleep "\$FAKE_CODEX_SLEEP"
echo '{"type":"token_count","payload":{"rate_limits":{"primary":{"used_percent":12.0,"window_minutes":300,"resets_at":9999999999}}}}'
exit "\${FAKE_CODEX_EXIT:-0}"
EOF
chmod +x "$BIN/codex"

cat >"$BIN/crontab" <<'EOF'
#!/usr/bin/env bash
STORE="${FAKE_CRONTAB_STORE:?FAKE_CRONTAB_STORE 未设置}"
if [[ "${1:-}" == "-l" ]]; then
  if [[ -f "$STORE" ]]; then cat "$STORE"; else
    echo "no crontab for fake" >&2; exit 1
  fi
  exit 0
fi
cp "$1" "$STORE"
EOF
chmod +x "$BIN/crontab"

# 会把自身环境里的代理变量 dump 出来的假 codex
cat >"$BIN/codex-env" <<'EOF'
#!/usr/bin/env bash
env | grep -iE '^(http_proxy|https_proxy|all_proxy|no_proxy)=' | sort >"${FAKE_ENV_OUT:?FAKE_ENV_OUT 未设置}"
echo '{"type":"token_count","payload":{"rate_limits":{"primary":{"used_percent":12.0,"window_minutes":300,"resets_at":9999999999}}}}'
exit 0
EOF
chmod +x "$BIN/codex-env"

# write_rollout <file> <used_percent> <resets_at>
write_rollout() {
  printf '{"timestamp":"2026-01-01T00:00:00Z","type":"token_count","payload":{"rate_limits":{"primary":{"used_percent":%s,"window_minutes":300,"resets_at":%s},"secondary":{"used_percent":5.0,"window_minutes":10080,"resets_at":%s}}}}\n' \
    "$2" "$3" "$3" >"$1"
}

RL_FILE="$SESS/2026/01/01/rollout-2026-01-01T00-00-00-test.jsonl"
FUTURE=$(( $(date +%s) + 3600 ))
PAST=$(( $(date +%s) - 3600 ))

# run <logdir> <args...>，可额外用 env 覆盖 PULSE_TIMEOUT 等
run() {
  local logdir="$1"; shift
  PATH="$BIN:$PATH" LOG_DIR="$logdir" SESSIONS_DIR="$SESS" CODEX_BIN="$BIN/codex" \
    LOCK_FILE="$TMP/lock" PULSE_NET_PROBE="${PULSE_NET_PROBE:-0}" "$PULSE" "$@"
}

events() { grep -o '"event":"[a-z_]*"' "$1/pulse.jsonl" 2>/dev/null | sed 's/.*:"//; s/"$//' | tr '\n' ' '; }

# 从 pulse.sh 里读出配置的日程条数（这样你改 TIMES 后自测仍然有效）
expected_times() {
  sed -n 's/^TIMES=(\(.*\))$/\1/p' "$PULSE" | head -1 | tr ' ' '\n' | tr -d '"' | grep -c '^[0-9]'
}

# ------------------------------- 用例 ---------------------------------------
echo "== 心跳路径 =="

L1="$TMP/log1"; rm -f "$MARK"; write_rollout "$RL_FILE" 12.0 "$FUTURE"
run "$L1" now
[[ -f "$MARK" ]] && ok "额度充足时执行了心跳" || bad "额度充足时应该执行心跳"
expect_contains "记录 pulse_ok" "$(events "$L1")" "pulse_ok"
expect_contains "记录到了额度快照" "$(cat "$L1/pulse.jsonl")" '"used_percent_before":12.0'

L2="$TMP/log2"; rm -f "$MARK"; write_rollout "$RL_FILE" 100.0 "$FUTURE"
run "$L2" now
expect_contains "5h 额度打满 -> skip_limited" "$(events "$L2")" "skip_limited"
[[ -f "$MARK" ]] && bad "跳过时不应调用 codex" || ok "跳过时没有调用 codex"
expect_contains "记录了重置时刻" "$(cat "$L2/pulse.jsonl")" '"resets_at_local"'

L3="$TMP/log3"; rm -f "$MARK"
run "$L3" now --dry-run
expect_contains "dry-run 记录 dry_run" "$(events "$L3")" "dry_run"
[[ -f "$MARK" ]] && bad "dry-run 不应调用 codex" || ok "dry-run 没有调用 codex"

L4="$TMP/log4"; rm -f "$MARK"
run "$L4" now --assume-limited >/dev/null 2>&1
expect_contains "--assume-limited -> skip_limited" "$(events "$L4")" "skip_limited"
[[ -f "$MARK" ]] && bad "--assume-limited 不应调用 codex" || ok "--assume-limited 没有调用 codex"

L5="$TMP/log5"; rm -f "$MARK"
run "$L5" fire --at "$(date -d '-10 minutes' +%H:%M)" >/dev/null 2>&1
expect_contains "晚了 10 分钟 -> missed" "$(events "$L5")" "missed"
[[ -f "$MARK" ]] && bad "missed 不应调用 codex" || ok "missed 没有调用 codex"

write_rollout "$RL_FILE" 12.0 "$FUTURE"
L6="$TMP/log6"; rm -f "$MARK"
run "$L6" fire --at "$(date +%H:%M)"
expect_contains "准点（cron 语义）-> pulse_ok" "$(events "$L6")" "pulse_ok"
run "$L6" fire --at "$(date +%H:%M)" >/dev/null 2>&1
expect_contains "同一时间点重复触发 -> skipped_duplicate" "$(events "$L6")" "skipped_duplicate"

L7="$TMP/log7"
PATH="$BIN:$PATH" LOG_DIR="$L7" SESSIONS_DIR="$SESS" CODEX_BIN="$BIN/codex" LOCK_FILE="$TMP/lock" \
  PULSE_TIMEOUT=1 FAKE_CODEX_SLEEP=5 "$PULSE" now >/dev/null 2>&1
expect_contains "超时 -> timeout" "$(events "$L7")" "timeout"

L8="$TMP/log8"; rm -f "$MARK"
run "$L8" now --bogus-arg >/dev/null 2>&1
rc=$?
[[ $rc -ne 0 ]] && ok "未知参数返回非 0" || bad "未知参数应返回非 0"

# 真实 CLI 命中额度上限时的输出形态（退出码 1，报错在 stdout 的 JSON 里）
cat >"$BIN/codex-limit" <<'EOF'
#!/usr/bin/env bash
echo '{"type":"error","message":"You'"'"'ve hit your usage limit. Upgrade to Pro or try again at 1:21 AM."}'
exit 1
EOF
chmod +x "$BIN/codex-limit"
L8b="$TMP/log8b"
PATH="$BIN:$PATH" LOG_DIR="$L8b" SESSIONS_DIR="$SESS" CODEX_BIN="$BIN/codex-limit" LOCK_FILE="$TMP/lock" \
  "$PULSE" now --force >/dev/null 2>&1
expect_contains "CLI 报 usage limit -> limited" "$(events "$L8b")" "limited"
expect_contains "记录重置提示" "$(cat "$L8b/pulse.jsonl")" '"reset_hint":"1:21 AM"'

echo "== cron 环境（env -i + 最小 PATH）=="

L12="$TMP/log12"; rm -f "$MARK"; write_rollout "$RL_FILE" 12.0 "$FUTURE"
env -i HOME="$HOME" PATH="$BIN:/usr/bin:/bin" LOG_DIR="$L12" SESSIONS_DIR="$SESS" \
  CODEX_BIN="$BIN/codex" LOCK_FILE="$TMP/lock" "$PULSE" fire --at "$(date +%H:%M)" >/dev/null 2>&1
expect_contains "最小环境下 fire 正常执行" "$(events "$L12")" "pulse_ok"

echo "== 代理注入（cron 里本来没有任何代理变量）=="

# 配置了 PULSE_PROXY：子进程必须拿到四个变量
env -i HOME="$HOME" PATH="$BIN:/usr/bin:/bin" FAKE_ENV_OUT="$TMP/env13.txt" \
  LOG_DIR="$TMP/log13" SESSIONS_DIR="$SESS" CODEX_BIN="$BIN/codex-env" LOCK_FILE="$TMP/lock" \
  PULSE_PROXY="http://127.0.0.1:7890" PULSE_NET_PROBE=0 "$PULSE" now >/dev/null 2>&1
env13="$(cat "$TMP/env13.txt" 2>/dev/null)"
expect_contains "子进程拿到 https_proxy" "$env13" "https_proxy=http://127.0.0.1:7890"
expect_contains "子进程拿到 HTTPS_PROXY" "$env13" "HTTPS_PROXY=http://127.0.0.1:7890"
expect_contains "子进程拿到 no_proxy" "$env13" "no_proxy=localhost,127.0.0.1,::1"

# PULSE_PROXY 置空且环境里也没有代理：子进程不应该凭空多出代理变量
env -i HOME="$HOME" PATH="$BIN:/usr/bin:/bin" FAKE_ENV_OUT="$TMP/env14.txt" \
  LOG_DIR="$TMP/log14" SESSIONS_DIR="$SESS" CODEX_BIN="$BIN/codex-env" LOCK_FILE="$TMP/lock" \
  PULSE_PROXY= PULSE_NET_PROBE=0 "$PULSE" now >/dev/null 2>&1
expect_empty "PULSE_PROXY 置空时不注入代理" "$(cat "$TMP/env14.txt" 2>/dev/null)"

# PULSE_PROXY 置空但环境有代理：沿用环境里的代理（交互式跑的时候有用）
env -i HOME="$HOME" PATH="$BIN:/usr/bin:/bin" FAKE_ENV_OUT="$TMP/env15.txt" \
  LOG_DIR="$TMP/log15" SESSIONS_DIR="$SESS" CODEX_BIN="$BIN/codex-env" LOCK_FILE="$TMP/lock" \
  http_proxy="http://127.0.0.1:8888" PULSE_PROXY= PULSE_NET_PROBE=0 "$PULSE" now >/dev/null 2>&1
expect_contains "沿用环境里的代理" "$(cat "$TMP/env15.txt" 2>/dev/null)" "https_proxy=http://127.0.0.1:8888"

echo "== 网络预检 =="

if command -v curl >/dev/null 2>&1; then
  L16="$TMP/log16"; rm -f "$MARK"; write_rollout "$RL_FILE" 12.0 "$FUTURE"
  env -i HOME="$HOME" PATH="$BIN:/usr/bin:/bin" LOG_DIR="$L16" SESSIONS_DIR="$SESS" \
    CODEX_BIN="$BIN/codex" LOCK_FILE="$TMP/lock" PULSE_PROXY="http://127.0.0.1:9" \
    PULSE_NET_PROBE=1 PULSE_NET_PROBE_URL="https://127.0.0.1:9/" PULSE_NET_PROBE_TIMEOUT=3 \
    PULSE_NET_PROBE_RETRY=0 \
    "$PULSE" now >/dev/null 2>&1
  expect_contains "预检不通 -> net_unreachable" "$(events "$L16")" "net_unreachable"
  expect_contains "预检失败原因被记下来" "$(cat "$L16/pulse.jsonl")" '"probe_error"'
  [[ -f "$MARK" ]] && bad "预检不通时不应调用 codex" || ok "预检不通时没有调用 codex"
else
  ok "没有 curl，跳过网络预检用例"
fi

echo "== 额度快照解析 =="

L9="$TMP/log9"
write_rollout "$RL_FILE" 100.0 "$FUTURE"
run "$L9" status >"$TMP/status.txt" 2>&1
expect_contains "status 读到 used_percent" "$(cat "$TMP/status.txt")" "used_percent = 100.0%"

write_rollout "$RL_FILE" 42.5 "$FUTURE"
run "$L9" status >"$TMP/status2.txt" 2>&1
expect_contains "status 跟随最新快照" "$(cat "$TMP/status2.txt")" "used_percent = 42.5%"

echo "== 日志轮转 =="

L10="$TMP/log10"; mkdir -p "$L10"
head -c 4096 /dev/zero | tr '\0' 'x' >"$L10/service.log"
PATH="$BIN:$PATH" LOG_DIR="$L10" SESSIONS_DIR="$SESS" CODEX_BIN="$BIN/codex" LOCK_FILE="$TMP/lock" \
  PULSE_SERVICE_LOG_MAX=1024 "$PULSE" now --dry-run >/dev/null 2>&1
[[ -f "$L10/service.log.1" ]] && ok "service.log 超阈值被轮转" || bad "service.log 应被轮转"

echo "== crontab 托管块 =="

export FAKE_CRONTAB_STORE="$TMP/crontab.txt"
printf '5 5 * * * echo hello\n' >"$FAKE_CRONTAB_STORE"
run "$TMP/log11" install >/dev/null 2>&1
store="$(cat "$FAKE_CRONTAB_STORE")"
expect_contains "保留原有条目" "$store" "5 5 * * * echo hello"
expect_contains "写入托管块起始标记" "$store" "# >>> codex-pulse >>>"
n_fire=$(grep -c 'fire --at' "$FAKE_CRONTAB_STORE")
n_want="$(expected_times)"
[[ "$n_fire" == "$n_want" ]] && ok "日程条数与配置一致（$n_fire 条）" \
  || bad "日程条数应为 $n_want，实际 $n_fire"
expect_contains "cron 行带绝对路径" "$store" "$PULSE fire --at"
expect_contains "cron 行带 HOME/PATH" "$store" "HOME=$HOME PATH="

run "$TMP/log11" install >/dev/null 2>&1
n_fire2=$(grep -c 'fire --at' "$FAKE_CRONTAB_STORE")
[[ "$n_fire2" == "$n_fire" ]] && ok "install 幂等（仍为 $n_fire2 条）" || bad "install 不幂等：$n_fire -> $n_fire2"
n_begin=$(grep -c '^# >>> codex-pulse' "$FAKE_CRONTAB_STORE")
[[ "$n_begin" == "1" ]] && ok "托管块只有一份" || bad "托管块重复（$n_begin 份）"

run "$TMP/log11" uninstall >/dev/null 2>&1
store2="$(cat "$FAKE_CRONTAB_STORE")"
expect_contains "卸载后保留原有条目" "$store2" "5 5 * * * echo hello"
n_tag=$(grep -c 'codex-pulse' "$FAKE_CRONTAB_STORE" || true)
[[ "$n_tag" == "0" ]] && ok "卸载后托管块消失" || bad "卸载后仍残留 $n_tag 行托管内容"
unset FAKE_CRONTAB_STORE

echo "== 汇总 =="
printf '通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
[[ "$FAIL" == "0" ]]
