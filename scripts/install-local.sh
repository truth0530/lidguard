#!/bin/bash
# Commit the current work and replace the installed copies on this Mac with
# the dist/ build. Old copies go to dist/old-installs/ (Terminal may not be
# allowed to write to ~/.Trash). Push and release are separate.
# Usage: bash scripts/install-local.sh ["commit message"]
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

APP="dist/잠자기방지.app"
TARGETS=(
  "$HOME/Applications/잠자기방지.app"
  "$HOME/Desktop/_바탕_정리_2026-08-11/04_도구앱/잠자기방지.app"
)
step() { echo "== $*"; }
die() { echo "중단: $*" >&2; exit 1; }
version_of() { /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$1" 2>/dev/null; }

step "앱 실행 여부 확인"
if pgrep -x -U "$(id -u)" lidguard >/dev/null 2>&1; then
  die "잠자기 방지 앱이 켜져 있습니다. 종료한 뒤 다시 실행해 주세요"
fi

step "빌드 결과 확인"
[ -d "$APP" ] || die "$APP 가 없습니다. bash scripts/build.sh 를 먼저 실행해 주세요"
BUILT="$(version_of "$APP/Contents/Info.plist")"
SOURCE="$(version_of Info.plist)"
[ -n "$BUILT" ] || die "빌드 버전을 읽지 못했습니다"
[ "$BUILT" = "$SOURCE" ] || die "빌드($BUILT)와 Info.plist($SOURCE) 버전이 다릅니다. bash scripts/build.sh 로 다시 빌드해 주세요"
codesign --verify --deep --strict "$APP" || die "빌드 서명 확인 실패"
echo "빌드 버전 $BUILT"

step "커밋"
git add -A Sources tests README.md Info.plist scripts || die "git add 실패"
if git diff --cached --quiet; then
  echo "커밋할 변경 없음 (이미 커밋됨)"
else
  git commit -q -m "${1:-chore: 로컬 설치 ($BUILT)}" || die "커밋 실패"
fi
git log --oneline -1

step "설치"
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP="dist/old-installs/$TS"
for D in "${TARGETS[@]}"; do
  if [ -d "$D" ]; then
    OLD="$(version_of "$D/Contents/Info.plist")"
    mkdir -p "$BACKUP" || die "백업 폴더를 만들지 못했습니다"
    mv "$D" "$BACKUP/잠자기방지 ${OLD:-?} ($(basename "$(dirname "$D")")).app" \
      || die "기존 앱을 옮기지 못했습니다: $D (터미널에 바탕화면 접근 권한이 필요할 수 있습니다)"
  fi
  mkdir -p "$(dirname "$D")" || die "폴더를 만들지 못했습니다: $(dirname "$D")"
  ditto "$APP" "$D" || die "복사 실패: $D"
  xattr -cr "$D" 2>/dev/null
  codesign --verify --deep --strict "$D" || die "설치본 서명 확인 실패: $D"
  echo "설치 완료: v$(version_of "$D/Contents/Info.plist")  $D"
done
[ -d "$BACKUP" ] && echo "이전 앱 보관: $PWD/$BACKUP (확인 후 지워도 됩니다)"
echo "== 완료: push와 릴리스는 아직 하지 않았습니다"
