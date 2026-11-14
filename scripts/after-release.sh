#!/usr/bin/env bash
# after-release.sh — 社区插件发版后的 CDN 刷新与校验
#
# 背景：magpie 的 @magpie-community/* 包不是从 npm 装的，而是按默认分支从
# cdn.jsdelivr.net 逐个文件拉取、本地 npm pack。jsDelivr 边缘缓存 s-maxage=12h，
# 每个文件各吃各的缓存，于是可能出现「package.json 已是 0.2.2、index.mjs 还是 0.2.1」
# 的混装包。本脚本把「发版后 purge + 校验」固化成一条命令。
#
# 用法：
#   scripts/after-release.sh <package-dir>            # 例：scripts/after-release.sh astudio
#   scripts/after-release.sh astudio --no-purge       # 只校验，不刷新
#   scripts/after-release.sh astudio --wait 300       # 校验最长等待秒数（默认 120）
#   scripts/after-release.sh astudio --raw-mirror https://ghfast.top/   # README 类的 GitHub 镜像前缀（默认即此；设空串禁用）
#
# 退出码：0 = CDN 与本地逐文件一致；1 = 仍有差异（CDN 未刷新完，稍后重跑）；
#         2 = 用法/环境错误。

set -uo pipefail

REPO_SLUG="magpie-community/plugins"
BRANCH="main"
CDN="https://cdn.jsdelivr.net/gh/${REPO_SLUG}@${BRANCH}"
PURGE_HOST="https://purge.jsdelivr.net/gh/${REPO_SLUG}@${BRANCH}"
# README 等文件在 jsDelivr 上会 301 到 raw.githubusercontent.com，国内直连不通；
# 默认用 GitHub 镜像前缀取，可用 --raw-mirror 改或设为空串禁用。
RAW_MIRROR="${RAW_MIRROR:-https://ghfast.top/}"

PKG=""
DO_PURGE=1
WAIT_SECS=120

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --no-purge) DO_PURGE=0; shift ;;
    --raw-mirror) RAW_MIRROR="${2:-}"; shift 2 ;;
    --wait) WAIT_SECS="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    -*) echo "未知参数: $1" >&2; usage ;;
    *) PKG="$1"; shift ;;
  esac
done

[ -n "$PKG" ] || usage
[ -d "packages/$PKG" ] || { echo "找不到目录 packages/$PKG（请在仓库根执行）" >&2; exit 2; }
command -v git >/dev/null || { echo "需要 git" >&2; exit 2; }
command -v curl >/dev/null || { echo "需要 curl" >&2; exit 2; }

sha() { sha256sum "$@" 2>/dev/null | cut -d' ' -f1; }
# 必须比 HEAD 里的 blob，不能比工作区文件：Windows 上 core.autocrlf=true 会把
# 检出的文件转成 CRLF，哈希与仓库/CDN 内容必然不同（实测会假报 7 个文件全不一致）。
sha_head() { git show "HEAD:$1" 2>/dev/null | sha256sum | cut -d' ' -f1; }

# jsDelivr 对 README.md 这类文档文件不做改写，直接 301 到 raw.githubusercontent.com；
# 国内直连 raw 不通（实测 TLS 失败），所以遇到 raw 重定向就改走 GitHub 镜像前缀。
# 取内容写入 $TMP_BODY，回显最终 HTTP 状态码。
fetch_one() {
  local path="$1" url="${CDN}/$1" loc code
  code=$(curl -s -m 30 -o "$TMP_BODY" -w '%{http_code}' "$url" 2>/dev/null)
  case "$code" in
    301|302|307|308)
      loc=$(curl -sI -m 20 "$url" 2>/dev/null | tr -d '\r' | grep -i '^location:' | head -1 | sed 's/^[Ll]ocation: *//')
      case "$loc" in
        https://raw.githubusercontent.com/*)
          if [ -n "$RAW_MIRROR" ]; then
            code=$(curl -s -m 30 -o "$TMP_BODY" -w '%{http_code}' "${RAW_MIRROR}${loc}" 2>/dev/null)
          else
            code="redirect-raw"
          fi ;;
        http*)
          code=$(curl -sL -m 30 -o "$TMP_BODY" -w '%{http_code}' "$loc" 2>/dev/null) ;;
      esac ;;
  esac
  printf '%s' "$code"
}

mapfile -t FILES < <(git ls-files "packages/$PKG")
[ "${#FILES[@]}" -gt 0 ] || { echo "packages/$PKG 下没有 git 跟踪的文件" >&2; exit 2; }

echo "包目录: packages/$PKG —— ${#FILES[@]} 个文件"

if [ "$DO_PURGE" -eq 1 ]; then
  echo "== 刷新 jsDelivr 缓存 =="
  for f in "${FILES[@]}"; do
    printf '  purge %s ... ' "$f"
    if curl -sf -m 30 "${PURGE_HOST}/${f}" >/dev/null; then
      echo ok
    else
      echo "失败（继续，稍后校验会暴露）"
    fi
  done
fi

echo "== 逐文件比对 本地 vs CDN@${BRANCH} =="
TMP_BODY="$(mktemp)"
trap 'rm -f "$TMP_BODY"' EXIT
deadline=$(( $(date +%s) + WAIT_SECS ))
attempt=0
while :; do
  attempt=$((attempt + 1))
  mismatch=0
  missing=0
  for f in "${FILES[@]}"; do
    local_sum=$(sha_head "$f")
    code=$(fetch_one "$f")
    if [ "$code" != "200" ] || [ ! -s "$TMP_BODY" ]; then
      echo "  [取不到] $f  http=${code:-none} bytes=$(wc -c < "$TMP_BODY" 2>/dev/null || echo 0)"
      missing=$((missing + 1)); mismatch=$((mismatch + 1)); continue
    fi
    remote_sum=$(sha256sum "$TMP_BODY" | cut -d' ' -f1)
    if [ "$local_sum" != "$remote_sum" ]; then
      echo "  [不一致] $f  本地=${local_sum:0:16} CDN=${remote_sum:0:16}"
      mismatch=$((mismatch + 1))
    fi
  done

  if [ "$mismatch" -eq 0 ]; then
    echo "全部一致（第 ${attempt} 轮）"
    exit 0
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "仍有 ${mismatch} 个文件与本地不一致（含取不到 ${missing} 个），CDN 可能还没刷新完；稍后重跑本脚本。"
    exit 1
  fi
  echo "  第 ${attempt} 轮：${mismatch} 个待同步，10 秒后重试…"
  sleep 10
done
