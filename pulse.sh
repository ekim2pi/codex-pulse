#!/usr/bin/env bash
# ============================================================================
# codex-pulse —— 定时给 Codex 发"心跳"，踩出/接续 ChatGPT Plus 的 5h 额度窗口
#
# 设计要点：
#   * 由 cron 到点拉起（`./pulse.sh install`），无常驻进程、无轮询；
#   * 心跳走 `codex exec --ephemeral`，不落盘、不出现在会话列表（用户无感）；
#   * 到点前先零消耗读本地 rollout 的 rate_limits，5h 额度已打满就跳过；
#   * 发心跳前显式注入代理并做一次 8 秒网络预检（cron 里没有 WSL autoProxy 的变量）；
#   * 错过的时间点不补发、失败不重试，全程只写日志。
#
# 用法：
#   ./pulse.sh preview              只打印将要写入 crontab 的日程块，不做任何修改
#   ./pulse.sh install              把日程写入用户 crontab（保留你原有条目）
#   ./pulse.sh uninstall            移除 crontab 里的托管块
#   ./pulse.sh status               查看托管块、当前额度快照、最近事件
#   ./pulse.sh fire --at HH:MM      由 cron 调用（含准点判定、去重、额度预检）
#   ./pulse.sh now [--dry-run] [--assume-limited] [--force]   手动立刻发一次
#   ./pulse.sh selftest             跑本地自测（不消耗额度）
# ============================================================================

set -uo pipefail

# ------------------------------- 配置 ---------------------------------------
# 每天发心跳的时间点（本地时区）。相邻两点相隔 5 小时多一点（5h02m），
# 这样每次心跳都刚好落在上一个窗口过期之后，顺手把新窗口开起来。
TIMES=("05:58" "11:00" "16:02" "21:04")

PULSE_MODEL="${PULSE_MODEL:-gpt-5.6-luna}"    # 心跳用的模型（最小开销档位）
PULSE_REASONING="${PULSE_REASONING:-low}" # 推理档位（可选 low/medium/high/xhigh/max）
PULSE_PROMPT="${PULSE_PROMPT:-只回复 OK，不要调用任何工具。}"
PULSE_TIMEOUT="${PULSE_TIMEOUT:-180}"         # 单次心跳超时（秒）
PULSE_GRACE="${PULSE_GRACE:-120}"             # 准点窗口（秒），超时记为 missed 跳过
PULSE_WORKDIR="${PULSE_WORKDIR:-/tmp}"        # 心跳运行目录，避免碰到你的仓库
# 代理：WSL 的 autoProxy 只注入交互式会话，cron 环境里一个代理变量都没有，
# 所以这里要显式配置。想改回"沿用当前环境"就写 PULSE_PROXY= 。
PULSE_PROXY="${PULSE_PROXY-http://127.0.0.1:7890}"
PULSE_NO_PROXY="${PULSE_NO_PROXY:-localhost,127.0.0.1,::1}"
# 网络预检：发心跳前先探一次网，不通就记 net_unreachable 跳过，不傻等 180 秒
PULSE_NET_PROBE="${PULSE_NET_PROBE:-1}"
PULSE_NET_PROBE_URL="${PULSE_NET_PROBE_URL:-https://chatgpt.com/}"
PULSE_NET_PROBE_TIMEOUT="${PULSE_NET_PROBE_TIMEOUT:-8}"
PULSE_NET_PROBE_RETRY="${PULSE_NET_PROBE_RETRY:-1}"   # 预检失败后再试几次（每次间隔 3s）
CODEX_BIN="${CODEX_BIN:-}"                    # 留空 = 自动探测（PATH / nvm）
LOG_DIR="${LOG_DIR:-}"                        # 留空 = <脚本目录>/logs
SESSIONS_DIR="${SESSIONS_DIR:-}"              # 留空 = $HOME/.codex/sessions
TAIL_BYTES="${TAIL_BYTES:-262144}"            # 读 rollout 尾部的字节数
KEEP_RUNS="${KEEP_RUNS:-50}"                  # logs/runs/ 保留份数
PULSE_SERVICE_LOG_MAX="${PULSE_SERVICE_LOG_MAX:-2097152}"  # service.log 轮转阈值
PULSE_SERVICE_LOG_KEEP="${PULSE_SERVICE_LOG_KEEP:-3}"      # service.log 保留份数
# ----------------------------------------------------------------------------

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
: "${LOG_DIR:=$SCRIPT_DIR/logs}"
: "${SESSIONS_DIR:=$HOME/.codex/sessions}"
LOCK_FILE="${LOCK_FILE:-/tmp/codex-pulse-$(id -u).lock}"
STATE_FILE="$LOG_DIR/.state"
PULSE_JSONL="$LOG_DIR/pulse.jsonl"
RUNS_DIR="$LOG_DIR/runs"
SERVICE_LOG="$LOG_DIR/service.log"
CRON_LOG="$LOG_DIR/cron.log"

BLOCK_BEGIN="# >>> codex-pulse >>> (managed by pulse.sh; 不要手改这个块)"
BLOCK_END="# <<< codex-pulse <<<"
CRON_TAG="codex-pulse"

# rollout 里 5h 窗口（primary）的额度字段；版本不同可能有空格，正则放宽一点
RL_RE='"primary"[ ]*:[ ]*\{[ ]*"used_percent"[ ]*:[ ]*[0-9.]+[ ]*,[ ]*"window_minutes"[ ]*:[ ]*300[ ]*,[ ]*"resets_at"[ ]*:[ ]*[0-9]+'

# ------------------------------- 工具 ---------------------------------------
die() { printf 'pulse: %s\n' "$*" >&2; exit 1; }

# 给终端/cron.log 留一行线索（成功发心跳时不输出，保持安静）
note() { printf 'pulse: %s\n' "$*" >&2; }

usage() {
  sed -n '2,20p' "$SCRIPT_PATH" | sed 's/^# \{0,1\}//'
}

ts_iso() { date '+%Y-%m-%dT%H:%M:%S%:z'; }

json_escape() {
  printf '%s' "${1:-}" | tr '\n\r\t' '   ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

ensure_dirs() { mkdir -p "$LOG_DIR" "$RUNS_DIR" 2>/dev/null || true; }

detect_codex() {
  local p
  if [[ -n "$CODEX_BIN" && -x "$CODEX_BIN" ]]; then printf '%s\n' "$CODEX_BIN"; return 0; fi
  if p="$(command -v codex 2>/dev/null)" && [[ -n "$p" && -x "$p" ]]; then printf '%s\n' "$p"; return 0; fi
  for p in "$HOME"/.nvm/versions/node/*/bin/codex; do
    if [[ -x "$p" ]]; then printf '%s\n' "$p"; return 0; fi
  done
  return 1
}

# ------------------------------- 代理 / 网络 --------------------------------
mask_proxy() { sed -E 's#//[^@/]*@#//***@#' <<<"${1:-}"; }

# 生效的代理：配置优先；配置为空时沿用当前环境已有的代理变量
effective_proxy() {
  if [[ -n "$PULSE_PROXY" ]]; then printf '%s' "$PULSE_PROXY"; return 0; fi
  printf '%s' "${https_proxy:-${HTTPS_PROXY:-${http_proxy:-${HTTP_PROXY:-}}}}"
}

apply_proxy_env() {
  local p="$1"
  [[ -n "$p" ]] || return 0
  export http_proxy="$p" https_proxy="$p" HTTP_PROXY="$p" HTTPS_PROXY="$p"
  export no_proxy="${no_proxy:-$PULSE_NO_PROXY}" NO_PROXY="${NO_PROXY:-$PULSE_NO_PROXY}"
}

# 返回 0 = 通（或预检关闭 / 没装 curl）；1 = 不通（原因写在 NET_PROBE_ERR 里）
NET_PROBE_ERR=""
net_probe_ok() {
  [[ "$PULSE_NET_PROBE" == "1" ]] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  local attempt=0 tries=$(( PULSE_NET_PROBE_RETRY + 1 ))
  local code="" rc=0 err=""
  NET_PROBE_ERR=""
  while (( attempt < tries )); do
    attempt=$(( attempt + 1 ))
    err="$(mktemp)"
    code="$(curl -sS -m "$PULSE_NET_PROBE_TIMEOUT" -o /dev/null -w '%{http_code}' \
        "$PULSE_NET_PROBE_URL" 2>"$err")" || rc=$?
    if [[ -n "$code" && "$code" != "000" ]]; then
      rm -f "$err"
      return 0
    fi
    NET_PROBE_ERR="$(head -c 200 "$err" 2>/dev/null | tr '\n\r' '  ')"
    [[ -n "$NET_PROBE_ERR" ]] || NET_PROBE_ERR="curl exit=$rc http_code=${code:-none}"
    rm -f "$err"
    (( attempt < tries )) && sleep 3
  done
  return 1
}

# ---------------------------- 额度快照（零消耗） -----------------------------
# 输出 "<used_percent> <resets_at>"；读不到则返回 1（调用方降级为"不做预检"）
telemetry_snapshot() {
  local f line pct reset
  local -a files=()
  [[ -d "$SESSIONS_DIR" ]] || return 1
  mapfile -t files < <(find "$SESSIONS_DIR" -type f -name 'rollout-*.jsonl' \
      -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -5 | cut -d' ' -f2-)
  [[ ${#files[@]} -gt 0 ]] || return 1
  for f in "${files[@]}"; do
    line="$(tail -c "$TAIL_BYTES" "$f" 2>/dev/null | grep -oE "$RL_RE" | tail -1 || true)"
    [[ -n "$line" ]] || continue
    pct="$(sed -E 's/.*"used_percent"[ ]*:[ ]*([0-9.]+).*/\1/' <<<"$line")"
    reset="$(sed -E 's/.*"resets_at"[ ]*:[ ]*([0-9]+).*/\1/' <<<"$line")"
    printf '%s %s\n' "$pct" "$reset"
    return 0
  done
  return 1
}

# ------------------------------- 日志 ---------------------------------------
rotate_service_log() {
  [[ -f "$SERVICE_LOG" ]] || return 0
  local size i
  size="$(stat -c %s "$SERVICE_LOG" 2>/dev/null || echo 0)"
  (( size > PULSE_SERVICE_LOG_MAX )) || return 0
  for (( i = PULSE_SERVICE_LOG_KEEP - 1; i >= 1; i-- )); do
    [[ -f "$SERVICE_LOG.$i" ]] && mv -f "$SERVICE_LOG.$i" "$SERVICE_LOG.$((i + 1))"
  done
  mv -f "$SERVICE_LOG" "$SERVICE_LOG.1"
}

# log_event <result> <slot> <json_tail>
log_event() {
  local result="$1" slot="$2" tail="${3:-}"
  ensure_dirs
  printf '{"ts":"%s","event":"%s","slot":"%s"%s}\n' "$(ts_iso)" "$result" "$slot" "$tail" >>"$PULSE_JSONL"
  rotate_service_log
  printf '%s  %-16s slot=%-7s %s\n' "$(ts_iso)" "$result" "$slot" "$tail" >>"$SERVICE_LOG"
}

prune_runs() {
  [[ -d "$RUNS_DIR" ]] || return 0
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] && rm -f "$RUNS_DIR/$f"
  done < <(ls -1t "$RUNS_DIR" 2>/dev/null | tail -n "+$((KEEP_RUNS + 1))")
}

# ------------------------------- 日程状态 -----------------------------------
# HH:MM -> 今天的 epoch；若比现在晚 60s 以上，视为"昨天的那个时刻"
slot_epoch() {
  local t="$1" e n
  e="$(date -d "$(date +%F) $t" +%s 2>/dev/null)" || return 1
  n="$(date +%s)"
  if (( e > n + 60 )); then e=$((e - 86400)); fi
  printf '%s' "$e"
}

prune_state() {
  [[ -f "$STATE_FILE" ]] || return 0
  tail -n 500 "$STATE_FILE" >"$STATE_FILE.tmp" 2>/dev/null && mv -f "$STATE_FILE.tmp" "$STATE_FILE"
}

acquire_lock() {
  exec 9>"$LOCK_FILE" 2>/dev/null || return 1
  flock -n 9 || return 1
  return 0
}

# ------------------------------- 心跳 ---------------------------------------
# run_pulse <slot> <enforce:0|1> <dry:0|1> <assume_limited:0|1> <force:0|1>
run_pulse() {
  local slot="$1" enforce="$2" dry="$3" assume_limited="$4" force="$5"
  ensure_dirs
  local now diff key se
  now="$(date +%s)"

  if [[ "$enforce" == "1" ]]; then
    se="$(slot_epoch "$slot")" || { log_event "error" "$slot" ',"error":"时间点格式无法解析"'; return 1; }
    diff=$((now - se))
    if (( diff > PULSE_GRACE )); then
      log_event "missed" "$slot" ",\"late_s\":$diff"
      note "跳过 $slot：迟到 ${diff}s，超出准点窗口 ${PULSE_GRACE}s"
      return 0
    fi
    key="$(date -d "@$se" +%F) $slot"
    if [[ -f "$STATE_FILE" ]] && grep -qxF "$key" "$STATE_FILE" 2>/dev/null; then
      log_event "skipped_duplicate" "$slot" ",\"late_s\":$diff"
      note "跳过 $slot：这个时间点今天已经发过了"
      return 0
    fi
  fi

  # 额度预检：只有"读到了 5h 窗口 100% 且重置时刻还没到"才跳过
  local snap pct_before="" reset_before="" snap_err=""
  snap="$(telemetry_snapshot)" || snap_err="1"
  if [[ -n "$snap" ]]; then pct_before="${snap%% *}"; reset_before="${snap##* }"; fi

  local limited=0
  if [[ "$force" == "1" ]]; then
    limited=0
  elif [[ "$assume_limited" == "1" ]]; then
    limited=1
  elif [[ -n "$snap" ]] && awk -v p="$pct_before" -v r="$reset_before" -v n="$now" \
        'BEGIN { exit !(p + 0 >= 99.9 && r + 0 > n) }'; then
    limited=1
  fi

  # 代理 + 网络预检（cron 环境里没有 WSL autoProxy 注入的变量，必须自己补）
  local proxy="" proxy_show="(未设置)" net_ok=1
  proxy="$(effective_proxy)"
  apply_proxy_env "$proxy"
  [[ -n "$proxy" ]] && proxy_show="$(mask_proxy "$proxy")"
  net_probe_ok || net_ok=0

  # 组装心跳命令
  local bin=""; bin="$(detect_codex)" || bin=""
  local -a cmd=()
  if [[ -n "$bin" ]]; then
    cmd=("$bin" exec --ephemeral --skip-git-repo-check -s read-only
         -C "$PULSE_WORKDIR" -m "$PULSE_MODEL"
         -c "model_reasoning_effort=\"$PULSE_REASONING\"" --json "$PULSE_PROMPT")
  fi

  if [[ "$dry" == "1" ]]; then
    local verdict="会发送心跳"
    if (( limited )); then verdict="会跳过（5h 额度已满）"
    elif (( ! net_ok )); then verdict="会跳过（网络预检不通）"
    fi
    printf '[dry-run] slot=%s enforce=%s 预检: used_percent=%s resets_at=%s%s\n' \
      "$slot" "$enforce" "${pct_before:-未知}" "${reset_before:-未知}" \
      "${snap_err:+ (快照不可读，跳过预检)}" >&2
    local net_show="通过"
    if [[ "$PULSE_NET_PROBE" != "1" ]]; then net_show="已关闭"
    elif (( ! net_ok )); then net_show="不通（$PULSE_NET_PROBE_URL）"
    fi
    printf '[dry-run] 代理=%s 网络预检=%s\n' "$proxy_show" "$net_show" >&2
    printf '[dry-run] %s\n' "$verdict" >&2
    if (( ! limited && net_ok )); then
      if [[ -n "$bin" ]]; then
        printf '[dry-run] 将执行: ' >&2; printf '%q ' "${cmd[@]}" >&2; printf '\n' >&2
      else
        printf '[dry-run] 未找到 codex 可执行文件\n' >&2
      fi
    fi
    log_event "dry_run" "$slot" \
      ",\"would_skip\":$([[ $limited == 1 ]] && echo true || echo false)"\
",\"net_ok\":$([[ $net_ok == 1 ]] && echo true || echo false)"\
",\"proxy\":\"$(json_escape "$proxy_show")\""\
",\"used_percent\":${pct_before:-null},\"resets_at\":${reset_before:-null}"
    return 0
  fi

  if (( limited )); then
    local reset_h="null" reset_txt="未知"
    if [[ -n "$reset_before" ]]; then
      reset_txt="$(date -d "@$reset_before" '+%F %H:%M' 2>/dev/null || echo unknown)"
      reset_h="\"$(date -d "@$reset_before" '+%F %H:%M:%S' 2>/dev/null || echo unknown)\""
    fi
    log_event "skip_limited" "$slot" \
      ",\"used_percent\":${pct_before:-null},\"resets_at\":${reset_before:-null},\"resets_at_local\":$reset_h"
    note "跳过 $slot：5h 额度已满（已用 ${pct_before:-?}%，窗口重置于 $reset_txt）"
    return 0
  fi

  if (( ! net_ok )); then
    log_event "net_unreachable" "$slot" \
      ",\"probe\":\"$(json_escape "$PULSE_NET_PROBE_URL")\",\"proxy\":\"$(json_escape "$proxy_show")\""\
",\"probe_error\":\"$(json_escape "$NET_PROBE_ERR")\""
    note "跳过 $slot：网络预检不通（$PULSE_NET_PROBE_URL，代理 $proxy_show）→ $NET_PROBE_ERR"
    return 0
  fi

  if [[ -z "$bin" ]]; then
    log_event "error" "$slot" ',"error":"找不到 codex 可执行文件"'
    printf 'pulse: 找不到 codex 可执行文件\n' >&2
    return 1
  fi

  if ! acquire_lock; then
    log_event "skipped_locked" "$slot" ',"error":"另一个心跳正在运行"'
    note "跳过 $slot：另一个心跳正在运行"
    return 0
  fi

  if [[ "$enforce" == "1" ]]; then
    printf '%s\n' "$key" >>"$STATE_FILE"
    prune_state
  fi

  local run_file="$RUNS_DIR/$(date '+%Y%m%dT%H%M%S').jsonl"
  local err_file result exit_code=0 t0 t1
  err_file="$(mktemp)"
  t0="$(date +%s)"
  if timeout "$PULSE_TIMEOUT" "${cmd[@]}" </dev/null >"$run_file" 2>"$err_file"; then
    result="pulse_ok"
  else
    exit_code=$?
    if (( exit_code == 124 )); then
      result="timeout"
    elif grep -qiE 'usage limit|rate limit|too many requests|额度' "$err_file" "$run_file" 2>/dev/null; then
      result="limited"
    else
      result="error"
    fi
  fi
  t1="$(date +%s)"

  local pct_after=""
  pct_after="$(grep -oE "$RL_RE" "$run_file" 2>/dev/null | tail -1 \
      | sed -E 's/.*"used_percent"[ ]*:[ ]*([0-9.]+).*/\1/' || true)"
  if [[ -z "$pct_after" ]]; then
    local s2; s2="$(telemetry_snapshot)" && pct_after="${s2%% *}" || true
  fi

  local err_txt=""
  if [[ "$result" != "pulse_ok" ]]; then
    err_txt="$(head -c 400 "$err_file" 2>/dev/null | tr '\n\r' '  ')"
  fi
  # 额度打满时，从报错里摘出"try again at ..."的时间，方便日志回看
  local extra=""
  if [[ "$result" == "limited" ]]; then
    local hint=""
    hint="$( { head -c 4000 "$err_file"; head -c 4000 "$run_file"; } 2>/dev/null \
      | grep -oE 'try again at [^."]*' | head -1 | sed 's/^try again at //' || true)"
    if [[ -n "$hint" ]]; then
      extra=",\"reset_hint\":\"$(json_escape "$hint")\""
      err_txt="hit usage limit (try again at $hint)"
    else
      err_txt="${err_txt:-hit usage limit}"
    fi
  fi

  log_event "$result" "$slot" \
    ",\"duration_s\":$((t1 - t0)),\"exit_code\":$exit_code,\"model\":\"$(json_escape "$PULSE_MODEL")\""\
",\"used_percent_before\":${pct_before:-null},\"used_percent_after\":${pct_after:-null}"\
",\"error\":\"$(json_escape "$err_txt")\"$extra"

  rm -f "$err_file"
  prune_runs

  if [[ "$result" == "pulse_ok" ]]; then return 0; fi
  return 1
}

# ------------------------------- 子命令 -------------------------------------
cmd_fire() {
  local at="" dry=0 assume_limited=0 force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --at) at="${2:-}"; shift 2 || true;;
      --at=*) at="${1#--at=}"; shift;;
      --dry-run) dry=1; shift;;
      --assume-limited) assume_limited=1; shift;;
      --force) force=1; shift;;
      *) die "fire: 无法识别的参数 $1";;
    esac
  done
  [[ -n "$at" ]] || die "fire: 需要 --at HH:MM"
  [[ "$at" =~ ^[0-9]{1,2}:[0-9]{2}$ ]] || die "fire: 时间点格式应为 HH:MM（收到 '$at'）"
  run_pulse "$at" 1 "$dry" "$assume_limited" "$force"
}

cmd_now() {
  local dry=0 assume_limited=0 force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry=1; shift;;
      --assume-limited) assume_limited=1; shift;;
      --force) force=1; shift;;
      *) die "now: 无法识别的参数 $1";;
    esac
  done
  run_pulse "manual" 0 "$dry" "$assume_limited" "$force"
}

# cron 条目里用的 PATH：把 codex 所在目录（nvm bin）带上
cron_path() {
  local bin="" dir=""
  bin="$(detect_codex)" && dir="$(dirname "$bin")" || dir=""
  if [[ -n "$dir" ]]; then printf '%s:/usr/local/bin:/usr/bin:/bin' "$dir"
  else printf '/usr/local/bin:/usr/bin:/bin'; fi
}

cron_block() {
  local t hh mm path home
  path="$(cron_path)"; home="$HOME"
  printf '%s\n' "$BLOCK_BEGIN"
  for t in "${TIMES[@]}"; do
    [[ "$t" =~ ^[0-9]{1,2}:[0-9]{2}$ ]] || continue
    hh="${t%%:*}"; mm="${t##*:}"
    printf '%s %s * * * HOME=%s PATH=%s %s fire --at %s >> %s 2>&1\n' \
      "$((10#$mm))" "$((10#$hh))" "$home" "$path" "$SCRIPT_PATH" "$t" "$CRON_LOG"
  done
  printf '%s\n' "$BLOCK_END"
}

crontab_strip_block() {
  awk -v b="$BLOCK_BEGIN" -v e="$BLOCK_END" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    skip != 1 { print }
  '
}

cmd_preview() { cron_block; }

cmd_install() {
  local tmp
  tmp="$(mktemp)"
  { crontab -l 2>/dev/null || true; } | crontab_strip_block >"$tmp"
  # 去掉可能出现的尾部空行噪音
  cron_block >>"$tmp"
  if ! crontab "$tmp"; then
    rm -f "$tmp"
    die "写入 crontab 失败（请在本机自己的 shell 里执行，不要通过受限沙箱）"
  fi
  rm -f "$tmp"
  ensure_dirs
  printf '已写入 crontab 托管块：\n'
  crontab -l 2>/dev/null | sed -n "/^# >>> codex-pulse/,/^# <<< codex-pulse/p"
  printf '\n日志：%s\n' "$PULSE_JSONL"
}

cmd_uninstall() {
  local tmp
  tmp="$(mktemp)"
  { crontab -l 2>/dev/null || true; } | crontab_strip_block >"$tmp"
  if ! crontab "$tmp"; then
    rm -f "$tmp"
    die "修改 crontab 失败"
  fi
  rm -f "$tmp"
  printf '已从 crontab 移除 codex-pulse 托管块。\n'
}

cmd_status() {
  ensure_dirs
  printf '== crontab 托管块 ==\n'
  local block
  block="$(crontab -l 2>/dev/null | sed -n "/^# >>> codex-pulse/,/^# <<< codex-pulse/p" || true)"
  if [[ -n "$block" ]]; then printf '%s\n' "$block"
  else printf '(未安装，执行 ./pulse.sh install 写入)\n'; fi

  printf '\n== 当前 5h 额度快照 ==\n'
  local snap pct reset
  snap="$(telemetry_snapshot)" || snap=""
  if [[ -n "$snap" ]]; then
    pct="${snap%% *}"; reset="${snap##* }"
    printf 'used_percent = %s%%\n' "$pct"
    printf '窗口重置     = %s\n' "$(date -d "@$reset" '+%F %H:%M:%S' 2>/dev/null || echo "$reset")"
  else
    printf '(读不到本地 rollout 的 rate_limits，心跳会跳过预检直接发)\n'
  fi

  printf '\n== 日程 ==\n%s\n' "${TIMES[*]}"
  printf 'codex: %s\n' "$(detect_codex || echo '未找到')"
  printf '模型:  %s (effort=%s)\n' "$PULSE_MODEL" "$PULSE_REASONING"

  printf '\n== 最近事件 ==\n'
  if [[ -f "$PULSE_JSONL" ]]; then tail -n 5 "$PULSE_JSONL"; else printf '(暂无)\n'; fi
}

cmd_selftest() {
  bash "$SCRIPT_DIR/tests/test_pulse.sh"
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    preview) cmd_preview "$@";;
    install) cmd_install "$@";;
    uninstall) cmd_uninstall "$@";;
    status) cmd_status "$@";;
    fire) cmd_fire "$@";;
    now) cmd_now "$@";;
    selftest) cmd_selftest "$@";;
    "" | -h | --help | help) usage;;
    *) die "未知命令 '$cmd'（试试 --help）";;
  esac
}

main "$@"
