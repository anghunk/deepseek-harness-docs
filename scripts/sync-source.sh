#!/bin/bash
# ============================================================
# dsh 上游源码同步 + 文档增量更新脚本（含 push 与邮件通知）
#
# 流程：
#   1. 确保源码仓库已 clone（首次）或 fetch + pull
#   2. 与上次分析 SHA 对比，无新提交 → 发"无更新"邮件并退出
#   3. 有更新：生成增量变更摘要（提交列表 + diff，超限截断）
#   4. dsh headless 分析变更，增量更新 docs 相关章节并 commit
#   5. push 到 GitHub 文档仓库（失败不阻塞邮件，如实报告）
#   6. 发送分析报告邮件（分析时间 / 是否有更新 / 分析内容 /
#      文档变更 / 是否提交推送 / commit）
#   7. 记录本次分析的 SHA 与时间
#
# 由 launchd（com.dsh.docs-sync）每天 00:00 触发，也可手动执行：
#   bash scripts/sync-source.sh [--dry-run]
# ============================================================
set -uo pipefail

# ---------- 配置 ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_REPO="https://github.com/deepseek-ai/deepseek-harness.git"
SOURCE_DIR="/Users/abc/code/demo/dsh-source"
DOCS_DIR="/Users/abc/code/demo/dsh/docs"
STATE_DIR="${HOME}/.dsh-sync"
STATE_FILE="${STATE_DIR}/state.json"
LOG_FILE="${STATE_DIR}/sync.log"
SUMMARY_DIR="${STATE_DIR}/summaries"
CRED_FILE="${HOME}/.dsh/.credentials.yaml"
MAIL_TEMPLATE="${SCRIPT_DIR}/mail-template.html"
MAIL_TO="anghunk@foxmail.com"      # 收件人（通知邮箱）
MAX_COMMITS=40            # 最多列入邮件的提交数
MAX_DIFF_BYTES=300000     # diff 摘要超过 300KB 截断
DRY_RUN="${1:-}"

mkdir -p "${STATE_DIR}" "${SUMMARY_DIR}"
log() { echo "[$(date '+%F %T')] $*" >> "${LOG_FILE}"; }
info() { log "$*"; echo "$*"; }
die()  { log "错误: $*"; echo "错误: $*" >&2; exit 1; }

# ---------- 邮件工具 ----------
# render_mail <模板> <输出> <变量目录>：目录下每个文件名为 {{KEY}}，内容为值（自动 HTML 转义）
render_mail() {
  python3 - "$1" "$2" "$3" <<'PYEOF'
import sys, pathlib, html
tpl = open(sys.argv[1], encoding='utf-8').read()
data = {}
for p in pathlib.Path(sys.argv[3]).iterdir():
    data[p.name] = p.read_text(encoding='utf-8')
for k, v in data.items():
    tpl = tpl.replace('{{%s}}' % k, html.escape(v).replace('\n', '<br/>'))
open(sys.argv[2], 'w', encoding='utf-8').write(tpl)
PYEOF
}

# send_mail <主题> <body 文件绝对路径>；失败只记日志，不阻断主流程
send_mail() {
  local subject="$1" body="$2" rc
  ( cd "${STATE_DIR}" \
    && agently-cli message +send --to "${MAIL_TO}" --subject "${subject}" \
         --body-file "$(basename "${body}")" --body-format html --confirmed ) \
    >> "${LOG_FILE}" 2>&1
  rc=$?
  if [ "${rc}" -eq 0 ]; then
    info "邮件已发送：${subject}"
  else
    info "邮件发送失败（exit ${rc}）：${subject}，详见 ${LOG_FILE}"
  fi
}

# send_simple_mail <主题> <HTML 正文片段>：用于无更新/失败等简报
send_simple_mail() {
  local subject="$1" content="$2" body
  body="${STATE_DIR}/mail-$(date '+%Y%m%d-%H%M%S').html"
  cat > "${body}" <<EOF
<!DOCTYPE html><html lang="zh-CN"><body style="margin:0;padding:0;background:#f5f6f8;font-family:-apple-system,'PingFang SC','Microsoft YaHei',sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f5f6f8;padding:24px 0;"><tr><td align="center">
<table role="presentation" width="600" cellpadding="0" cellspacing="0" style="background:#ffffff;border-radius:8px;overflow:hidden;border:1px solid #e3e6eb;">
<tr><td style="background:#4d6bfe;padding:20px 28px;">
<div style="color:#ffffff;font-size:18px;font-weight:600;">🔔 DSH 文档同步 · 每日报告</div>
<div style="color:#c9d4ff;font-size:12px;margin-top:4px;">DeepSeek Harness 上游源码 → 解析文档自动同步</div>
</td></tr>
<tr><td style="padding:24px 28px;font-size:13px;color:#333847;line-height:1.9;">${content}</td></tr>
<tr><td style="background:#f8f9fc;padding:14px 28px;border-top:1px solid #eef0f5;">
<div style="font-size:12px;color:#8a90a0;">本邮件由定时任务（com.dsh.docs-sync，每日 00:00）自动生成</div>
</td></tr>
</table></td></tr></table></body></html>
EOF
  send_mail "${subject}" "${body}"
}

info "===== 开始同步 ====="

# ---------- 1. 确保源码仓库 ----------
if [ ! -d "${SOURCE_DIR}/.git" ]; then
  info "首次运行：clone 源码仓库到 ${SOURCE_DIR} ..."
  git clone --filter=blob:none "${SOURCE_REPO}" "${SOURCE_DIR}" >> "${LOG_FILE}" 2>&1 \
    || die "clone 失败，请检查网络"
else
  info "fetch 上游更新 ..."
  git -C "${SOURCE_DIR}" fetch origin >> "${LOG_FILE}" 2>&1 \
    || die "fetch 失败，请检查网络"
fi

CURRENT_SHA=$(git -C "${SOURCE_DIR}" rev-parse FETCH_HEAD 2>/dev/null || git -C "${SOURCE_DIR}" rev-parse HEAD)
CURRENT_DATE=$(git -C "${SOURCE_DIR}" log -1 --format=%cd --date=short "${CURRENT_SHA}" 2>/dev/null)

# ---------- 2. 增量检测 ----------
LAST_SHA=""
if [ -f "${STATE_FILE}" ]; then
  LAST_SHA=$(python3 -c "import json;print(json.load(open('${STATE_FILE}')).get('last_sha',''))" 2>/dev/null || echo "")
fi

# 无更新：发"无更新"简报后退出（首次运行同样只建基线）
if [ -n "${LAST_SHA}" ] && [ "${LAST_SHA}" = "${CURRENT_SHA}" ]; then
  info "无更新（HEAD 仍为 ${CURRENT_SHA}，${CURRENT_DATE}），跳过分析"
  if [ "${DRY_RUN}" != "--dry-run" ]; then
    send_simple_mail "[DSH 文档同步] $(date '+%m-%d') 无上游更新" \
"<b>分析时间：</b>$(date '+%F %T')<br/>
<b>上游是否有更新：</b>❌ 无更新<br/>
<b>本次是否产生新分析：</b>否（上游 HEAD 无变化，已跳过）<br/><br/>
文档无变更，无需处理。"
  fi
  exit 0
fi

if [ -z "${LAST_SHA}" ]; then
  info "首次运行：建立基线 ${CURRENT_SHA}（${CURRENT_DATE}），跳过分析"
  python3 - "${STATE_FILE}" "${CURRENT_SHA}" <<'PYEOF' >> "${LOG_FILE}" 2>&1
import json, sys, datetime
state_file, sha = sys.argv[1], sys.argv[2]
try:
    state = json.load(open(state_file))
except Exception:
    state = {}
state["last_sha"] = sha
state["last_sync_at"] = datetime.datetime.now().isoformat(timespec="seconds")
json.dump(state, open(state_file, "w"), indent=2, ensure_ascii=False)
print(f"状态已更新: last_sha={sha}")
PYEOF
  if [ "${DRY_RUN}" != "--dry-run" ]; then
    send_simple_mail "[DSH 文档同步] $(date '+%m-%d') 首次运行（已建立基线）" \
"<b>分析时间：</b>$(date '+%F %T')<br/>
<b>上游是否有更新：</b>—（首次运行）<br/>
<b>本次是否产生新分析：</b>否（已建立分析基线 ${CURRENT_SHA:0:12}，之后每日增量检测）<br/><br/>
文档无变更，无需处理。"
  fi
  exit 0
fi

info "检测到更新：上次 ${LAST_SHA} → 本次 ${CURRENT_SHA}（${CURRENT_DATE}）"

# pull 到工作区（dry-run 也拉，保证后续手动分析可用）
git -C "${SOURCE_DIR}" pull --ff-only >> "${LOG_FILE}" 2>&1 || die "pull 失败"

# ---------- 3. 生成增量变更摘要 ----------
STAMP=$(date '+%Y%m%d-%H%M%S')
SUMMARY_FILE="${SUMMARY_DIR}/changes-${STAMP}.md"
RANGE_LABEL="${LAST_SHA:0:12}..${CURRENT_SHA:0:12}"

{
  echo "# 上游变更摘要 ${CURRENT_SHA}（${CURRENT_DATE}）"
  echo
  echo "分析范围：${LAST_SHA} → ${CURRENT_SHA}"
  echo
  echo "## 提交列表"
  git -C "${SOURCE_DIR}" log --oneline --no-decorate "${LAST_SHA}..${CURRENT_SHA}" | head -"${MAX_COMMITS}"
  echo
  echo "## 变更统计"
  git -C "${SOURCE_DIR}" diff --stat "${LAST_SHA}".."${CURRENT_SHA}" | tail -30
  echo
  echo "## 变更 diff（可能截断）"
  git -C "${SOURCE_DIR}" diff "${LAST_SHA}".."${CURRENT_SHA}"
} > "${SUMMARY_FILE}" 2>> "${LOG_FILE}"

SIZE=$(wc -c < "${SUMMARY_FILE}")
if [ "${SIZE}" -gt "${MAX_DIFF_BYTES}" ]; then
  head -c "${MAX_DIFF_BYTES}" "${SUMMARY_FILE}" > "${SUMMARY_FILE}.trim"
  mv "${SUMMARY_FILE}.trim" "${SUMMARY_FILE}"
  echo -e "\n\n> ⚠️ diff 超过 ${MAX_DIFF_BYTES} 字节已截断，必要时直接查阅源码仓库" >> "${SUMMARY_FILE}"
  info "diff 摘要已截断（${SIZE} 字节 → ${MAX_DIFF_BYTES}）"
fi
info "增量摘要已生成：${SUMMARY_FILE}（$(wc -l < "${SUMMARY_FILE}") 行）"

# ---------- 4. dry-run 结束 ----------
if [ "${DRY_RUN}" = "--dry-run" ]; then
  info "[dry-run] 跳过 headless 分析与文档更新"
  exit 0
fi

# ---------- 5. dsh headless 分析并更新文档 ----------
[ -f "${CRED_FILE}" ] || die "凭据文件不存在: ${CRED_FILE}"
export OPENCODE_GO_API_KEY=$(
  grep -E '^[[:space:]]*OPENCODE_GO_API_KEY:' "${CRED_FILE}" | head -1 \
  | sed -E 's/^[[:space:]]*OPENCODE_GO_API_KEY:[[:space:]]*//' | tr -d '"'"'"' '
)
[ -n "${OPENCODE_GO_API_KEY:-}" ] || die "凭据文件中未找到 OPENCODE_GO_API_KEY"

PROMPT="你是 DeepSeek Harness 源码解析文档（VitePress 书籍）的维护 agent。

上游源码仓库 ${SOURCE_DIR} 刚更新。增量变更摘要（提交列表 + diff，可能截断）位于：
${SUMMARY_FILE}

文档项目位于 ${DOCS_DIR}（当前工作目录）。书籍章节按目录组织：part1-architecture/（ch1-3 全景与架构）、part2-cordis/（ch4-7 Cordis 框架）、part3-core/（ch8-16 核心子系统）、part4-web/（ch17）、part5-plugins/（ch18-21 插件开发）、appendix/（附录）、preface.md、index.md。

任务（增量更新，切勿全量重写）：
1. 阅读变更摘要，必要时查阅 ${SOURCE_DIR} 源码，判断影响哪些章节（架构、Cordis、核心子系统、Web 客户端、插件开发技巧、附录）。
2. 只修改受影响的章节文件：补充新机制/新文件，修正与新版不符的过时描述（如路径、API、行为变化）。不重写整章，不动无关内容；无对应章节影响的变更不强行改文档。
3. 在 ${DOCS_DIR}/changelog/ 创建或追加变更记录：文件 ${DOCS_DIR}/changelog/${CURRENT_DATE}.md，第一行标题用日期（# ${CURRENT_DATE}），随后列出本次上游提交（范围 ${RANGE_LABEL}）与对文档的改动摘要；若该日期文件已存在则在其基础上追加本次内容。
4. 同步更新 ${DOCS_DIR}/changelog/index.md 索引：若其中已有 ${CURRENT_DATE} 小节则更新该小节条目摘要；否则在索引中新增「## ${CURRENT_DATE}」小节与「- [${CURRENT_DATE}](${CURRENT_DATE}.md)：一句话摘要」条目（两行均独占一行），插入位置保持日期倒序（最新在最上方，紧跟首段介绍之后）。不要改动其他日期的条目与说明文字。
5. 在 ${DOCS_DIR} 中 git add 并 commit（message 含日期与提交范围，如 \"docs: 同步上游 ${CURRENT_DATE}（${RANGE_LABEL}）\"）。不要 push。
6. 输出总结：改动了哪些文件（含 changelog 记录与索引）、对应上游哪些提交、哪些变更未影响文档及原因。"

info "启动 dsh headless 分析（提交范围 ${RANGE_LABEL}）..."
ANALYSIS_FILE="${STATE_DIR}/analysis-${STAMP}.txt"
cd "${DOCS_DIR}" || die "无法进入文档目录 ${DOCS_DIR}"
if ! dsh --profile headless "${PROMPT}" > "${ANALYSIS_FILE}" 2>&1; then
  cat "${ANALYSIS_FILE}" >> "${LOG_FILE}"
  send_simple_mail "[DSH 文档同步] ${CURRENT_DATE} 上游分析失败" \
"<b>分析时间：</b>$(date '+%F %T')<br/>
<b>上游是否有更新：</b>✅ 有更新（${RANGE_LABEL}）<br/>
<b>本次是否产生新分析：</b>❌ 分析失败（headless 退出码非 0）<br/><br/>
文档未修改，状态未推进，下次运行将重试。详见日志：<span style=\"font-family:Menlo,monospace;\">${LOG_FILE}</span>"
  die "headless 分析失败，详见 ${LOG_FILE}"
fi
cat "${ANALYSIS_FILE}" >> "${LOG_FILE}"
info "headless 分析完成"

# ---------- 6. push 到 GitHub 文档仓库（失败不阻塞邮件） ----------
DOC_COMMIT=$(git -C "${DOCS_DIR}" log -1 --format=%H)
COMMIT_SHORT=$(git -C "${DOCS_DIR}" log -1 --format=%h)
COMMIT_MSG=$(git -C "${DOCS_DIR}" log -1 --format=%s)
COMMITTED="✅ 已提交"
PUSHED="❌ 推送失败（详见日志）"
if git -C "${DOCS_DIR}" push origin main >> "${LOG_FILE}" 2>&1; then
  PUSHED="✅ 已推送"
  info "已 push 到 GitHub：${COMMIT_SHORT}（origin/main）"
else
  info "push 失败（本地已提交 ${COMMIT_SHORT}，未推送）"
fi

# ---------- 7. 渲染并发送分析报告邮件 ----------
COMMITS_LIST=$(git -C "${SOURCE_DIR}" log --oneline --no-decorate "${LAST_SHA}..${CURRENT_SHA}" | head -"${MAX_COMMITS}")
COMMIT_COUNT=$(git -C "${SOURCE_DIR}" rev-list --count "${LAST_SHA}..${CURRENT_SHA}" 2>/dev/null || echo "?")
DOC_CHANGES=$(git -C "${DOCS_DIR}" show --stat --format="" "${DOC_COMMIT}" \
  | grep -E '^\s+[^ ]+(\s+\|)' | sed 's/^[[:space:]]*//' | head -20)

MAILVARS_DIR="${STATE_DIR}/mailvars-${STAMP}"
mkdir -p "${MAILVARS_DIR}"
putvar() { printf '%s' "$2" > "${MAILVARS_DIR}/$1"; }
putvar SYNC_TIME     "$(date '+%F %T')"
putvar HAS_UPDATE    "✅ 有更新"
putvar HAS_ANALYSIS  "✅ 是（增量分析）"
putvar RANGE         "${RANGE_LABEL}（${COMMIT_COUNT} 个提交）"
putvar COMMITS_LIST  "${COMMITS_LIST}"
putvar ANALYSIS_SUMMARY "$(head -60 "${ANALYSIS_FILE}")"
putvar DOC_CHANGES   "${DOC_CHANGES}"
putvar COMMITTED     "${COMMITTED}"
putvar PUSHED        "${PUSHED}"
putvar COMMIT_SHA    "${COMMIT_SHORT}"
putvar COMMIT_MSG    "${COMMIT_MSG}"

MAIL_BODY="${STATE_DIR}/mail-report-${STAMP}.html"
render_mail "${MAIL_TEMPLATE}" "${MAIL_BODY}" "${MAILVARS_DIR}"
send_mail "[DSH 文档同步] ${CURRENT_DATE} 上游更新分析（已提交 ${COMMIT_SHORT}）" "${MAIL_BODY}"

# ---------- 8. 记录状态 ----------
python3 - "${STATE_FILE}" "${CURRENT_SHA}" <<'PYEOF' >> "${LOG_FILE}" 2>&1
import json, sys, datetime
state_file, sha = sys.argv[1], sys.argv[2]
try:
    state = json.load(open(state_file))
except Exception:
    state = {}
state["last_sha"] = sha
state["last_sync_at"] = datetime.datetime.now().isoformat(timespec="seconds")
json.dump(state, open(state_file, "w"), indent=2, ensure_ascii=False)
print(f"状态已更新: last_sha={sha}")
PYEOF

info "===== 同步完成（${CURRENT_SHA}，${CURRENT_DATE}）====="
