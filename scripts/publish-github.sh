#!/bin/bash
# Explicit --public is required because this creates a public source repository.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUBLIC=false
RELEASE=false
for argument in "$@"; do
  case "$argument" in
    --public) PUBLIC=true ;;
    --release) RELEASE=true ;;
    *) echo "Usage: bash scripts/publish-github.sh --public [--release]" >&2; exit 2 ;;
  esac
done
if [[ "$PUBLIC" != true ]]; then
  echo '请传入 --public，明确将这个工程上传到公开 GitHub 仓库。' >&2; exit 2
fi
command -v gh >/dev/null || { echo '需要先安装 GitHub CLI：brew install gh' >&2; exit 2; }
# Use the authenticated endpoint itself. An anonymous curl probe can return
# 403 (rate limiting or gateway policy) even when authenticated gh works.
auth_error=$(mktemp "${TMPDIR:-/tmp}/shanghai-github-auth.XXXXXX")
trap 'rm -f "$auth_error"' EXIT
if owner=$(gh api --hostname github.com user --jq .login 2>"$auth_error"); then
  :
elif grep -Eq 'HTTP 401|gh auth login|not logged' "$auth_error"; then
  cat "$auth_error" >&2
  gh auth login --hostname github.com --git-protocol https --web
  owner=$(gh api --hostname github.com user --jq .login)
else
  cat "$auth_error" >&2
  echo 'GitHub 账户检查失败，尚未更改远端仓库。403 可能是权限、限流或网关拒绝，不能据此判断为断网。' >&2
  echo '可单独执行：gh api --hostname github.com user --jq .login' >&2
  exit 2
fi
[[ "$owner" =~ ^[A-Za-z0-9-]+$ ]]
REPO="$owner/ShanghaiTemperature"
VERSION=0.3.1
cd "$ROOT"
python3 scripts/validate_project.py
if [[ ! -d .git ]]; then git init -b main; fi
if [[ "$(git branch --show-current)" != main ]]; then
  echo '当前分支不是 main，为避免修改已有分支，已停止。' >&2; exit 2
fi
if git remote get-url origin >/dev/null 2>&1; then
  remote=$(git remote get-url origin)
  if [[ "$remote" != "https://github.com/$REPO.git" && "$remote" != "git@github.com:$REPO.git" ]]; then
    echo 'origin 与目标仓库不一致，已停止，未更改远端。' >&2; exit 2
  fi
else
  if gh repo view "$REPO" >/dev/null 2>&1; then
    echo "同名仓库 $REPO 已存在。请核对仓库归属后设置 origin；脚本不会覆盖已有工程。" >&2; exit 2
  fi
  gh repo create "$REPO" --public --description '固定上海市的 macOS 气温曲线桌面小组件，GitHub Actions 自动构建。'
  git remote add origin "https://github.com/$REPO.git"
fi
gh auth setup-git --hostname github.com
git add -- .github .gitignore App Shared Widgets Tests scripts Package.swift README.md ShanghaiTemperature.xcodeproj
if ! git diff --cached --quiet; then
  git -c user.name="$owner" -c user.email="$owner@users.noreply.github.com" \
    commit -m '新增江浙沪体感地图、历史比较与体感来源开关'
fi
if [[ "$RELEASE" == true ]]; then
  tag="v$VERSION"
  if git rev-parse "$tag" >/dev/null 2>&1; then
    [[ "$(git rev-parse "${tag}^{commit}")" == "$(git rev-parse HEAD)" ]] || {
      echo '版本标签已指向其他提交，已停止；不会强制覆盖。' >&2; exit 2;
    }
  else
    git tag "$tag"
  fi
  git push --atomic -u origin main "$tag"
else
  git push -u origin main
fi
echo "源码：https://github.com/$REPO"
echo "构建：https://github.com/$REPO/actions"
echo "发布：https://github.com/$REPO/releases"
echo '线上测试、编译全部通过后才会生成安装包。标签构建将发布预览版 Release。'
