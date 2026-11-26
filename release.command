#!/bin/zsh
set -eu

cd "${0:A:h}"
case "${1:-}" in
  '') publish=false ;;
  --publish) publish=true ;;
  -h|--help)
    print '用法：./release.command [--publish]'
    print '默认在 dist/ 生成 DMG；--publish 同时发布到 GitHub Releases。'
    exit 0
    ;;
  *) print -u2 '用法：./release.command [--publish]'; exit 2 ;;
esac
if (( $# > 1 )); then
  print -u2 '用法：./release.command [--publish]'
  exit 2
fi

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  print -u2 "无效的版本号：$version"
  exit 1
fi
tag="v$version"
asset_name="LaunchOS-$version-arm64.dmg"
output="$PWD/dist/$asset_name"

if [[ "$publish" == true ]]; then
  # 只有影响安装包的文件需要和发布提交一致。
  if ! git diff --quiet HEAD -- main.swift build.command Resources LICENSE; then
    print -u2 '请先提交应用源码、资源或构建脚本的改动，再执行发布。'
    exit 1
  fi
  commit=$(git rev-parse HEAD)
fi

./build.command
stage=$(mktemp -d "${TMPDIR:-/tmp}/launchos-release.XXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/volume" dist
ditto --norsrc LaunchOS.app "$stage/volume/LaunchOS.app"
codesign --verify --strict "$stage/volume/LaunchOS.app"
ln -s /Applications "$stage/volume/Applications"
cp LICENSE "$stage/volume/LICENSE.txt"
hdiutil makehybrid -hfs -hfs-volume-name LaunchOS -o "$stage/volume.dmg" "$stage/volume"
hdiutil convert "$stage/volume.dmg" -format UDZO -o "$stage/release.dmg"
hdiutil verify "$stage/release.dmg"
mv -f "$stage/release.dmg" "$output"
print "已生成：$output"

if [[ "$publish" == false ]]; then
  exit 0
fi

if ! command -v gh >/dev/null; then
  print -u2 '发布到 GitHub 需要 GitHub CLI（gh）。已生成的 DMG 可以手动上传。'
  exit 1
fi
if ! login=$(gh api user --jq .login); then
  print -u2 '无法验证 GitHub 登录。请检查网络或在本机终端运行 gh auth status。'
  exit 1
fi
origin=$(git remote get-url origin)
repo=$(gh repo view "$origin" --json nameWithOwner --jq .nameWithOwner)
print "发布账号：$login，仓库：$repo"

if ! gh api "repos/$repo/commits/$commit" --silent; then
  print -u2 "GitHub 无法读取提交 $commit。请确认已推送源码，并且当前账号有权限访问仓库。"
  exit 1
fi

tag_commit=$(gh api "repos/$repo/commits/$tag" --jq .sha 2>/dev/null) || tag_commit=''
if [[ -n "$tag_commit" && "$tag_commit" != "$commit" ]]; then
  print -u2 "$tag 已指向另一个提交。请使用该标签对应的源码构建，或升级版本号。"
  exit 1
fi

if draft=$(gh release view "$tag" --repo "$repo" --json isDraft --jq .isDraft 2>/dev/null); then
  if [[ "$draft" == false && -z "$tag_commit" ]]; then
    print -u2 "无法验证 $tag 对应的源码提交。"
    exit 1
  fi
  assets=$(gh release view "$tag" --repo "$repo" --json assets --jq '.assets[].name')
  if print -r -- "$assets" | grep -Fxq "$asset_name"; then
    print "Release 已有 $asset_name，保留现有附件。"
  else
    gh release upload "$tag" "$output" --repo "$repo"
  fi
  if [[ "$draft" == true ]]; then
    gh release edit "$tag" --repo "$repo" --target "$commit" --draft=false
  fi
else
  gh release create "$tag" "$output" \
    --repo "$repo" --target "$commit" --title "LaunchOS $version" \
    --notes "适用于 Apple 芯片 Mac，要求 macOS 26 或更新版本。打开 DMG，将 LaunchOS.app 拖到「应用程序」。本构建使用临时签名，未进行 Apple 公证。"
fi
gh release view "$tag" --repo "$repo" --json url --jq .url
