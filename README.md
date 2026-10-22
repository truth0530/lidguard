# 잠자기 방지 (lidguard) 1.6.0

뚜껑 닫힘/열림 유지 시간을 따로 두고, 시간이 끝나면 실제로 잠자기로 돌아갑니다.

## 동작

- **뚜껑을 닫아도 켜 두기**: 시작 즉시 `pmset disablesleep 1`. 뚜껑이 아직 열려 있어도 켭니다. Apple Silicon은 뚜껑을 닫는 순간 `Clamshell Sleep`이라, 닫힌 뒤에 켜면 이미 늦습니다. 끝나면 덮개가 닫혀 있으면 `sleepnow`. 관리자 권한이 필요해 같은 실행 파일의 감시 모드(`lidguard --watchdog`)가 root로 따로 돌며 시간을 지킵니다.
- **뚜껑이 열렸을 때만 켜 두기**: 앱 안에서 `PreventUserIdleSystemSleep` 요청(`caffeinate -i`와 같은 효과)을 잡습니다. 별도 프로그램이나 관리자 암호가 필요 없고, 앱이 꺼지면 macOS가 즉시 풀어 줍니다. 뚜껑을 닫으면 평소처럼 잠들고, 다시 열면 남은 시간 동안 이어집니다. **끔**이면 화면·시스템 잠자기를 막지 않습니다.
- 닫힘 유지가 켜져 있는 동안은 화면 자동꺼짐도 막힙니다. 창을 닫거나 종료하면 워치독이 `disablesleep`을 되돌립니다.
- 앱을 강제 종료하거나 앱이 죽어도, 워치독이 앱이 사라진 것을 보고 약 1분 안에 잠자기를 되돌립니다.
- macOS 과열 상태가 `serious` 이상이면 남은 시간과 관계없이 바로 해제합니다.
- 해제되면 창에 이유와 시각이 남습니다: 직접 해제, 시간 종료, 과열.

## 설치와 업데이트

[Releases](https://github.com/truth0530/lidguard/releases/latest)에서 `lidguard-macOS-arm64.zip`을 받아 압축을 풀고 `잠자기방지.app`을 응용 프로그램 폴더로 옮깁니다. 처음 열 때 확인되지 않은 개발자 경고가 뜨면 Finder에서 앱을 우클릭해 열기를 누릅니다.

1.5.0부터 앱이 하루에 한 번 GitHub Releases를 확인하고, 새 버전이 있으면 업데이트할지 묻습니다. 메뉴의 `업데이트 확인…`으로 바로 확인할 수도 있습니다.

- 잠자기 방지가 켜져 있는 동안에는 업데이트하지 않고, 해제된 뒤에 묻습니다.
- 내려받은 압축 파일의 SHA-256이 릴리스의 `.sha256` 파일과 맞고, 번들 ID와 버전이 같고, `codesign --verify`를 통과해야 설치합니다.
- 기존 앱은 교체가 끝날 때까지 백업해 두고, 복사에 실패하면 되돌립니다.
- 다운로드 폴더에서 바로 실행 중이면(App Translocation) 응용 프로그램 폴더로 옮기라고 안내합니다.

## 1.1.0에서 남은 결함

1. 워치독을 `osascript`+`nohup`으로 띄워, 관리자 스크립트가 끝나면 워치독이 같이 죽었다. 1시간 설정이 `disablesleep 1`만 남긴 채 끝나지 않았다.
2. GUI `NSTimer`가 마감을 처리하려다 덮개 닫힌 동안 암호 창을 띄우거나, 세대 번호만 올리고 워치독을 꺼 `disablesleep`이 남았다.
3. 닫힘 모드가 덮개를 연 뒤에도 `disablesleep`을 유지해 화면이 꺼지지 않았다.

## 1.2.0

- 워치독은 python double-fork로 분리해 `osascript`와 수명을 끊는다.
- 마감·덮개 상태 전환은 워치독만 처리한다. GUI 타이머는 표시용.
- 창을 닫거나 종료하면 워치독 정지 파일을 쓰고, 남은 `disablesleep`만 관리자 권한으로 되돌린다.

## 1.4.0

- 닫힘 유지를 덮개가 열린 동안에도 `disablesleep`으로 건다. 1.2.0이 화면 자동꺼짐을 지키려다 뚜껑 닫힘 잠을 막지 못했다.
- 시작 스크립트가 워치독보다 먼저 `disablesleep 1`을 건다. 워치독이 안 뜨면 즉시 되돌린다.

## 1.5.0

- 강제 종료 대비: 워치독을 `--require-gui`로 띄워, 앱이 사라지면 약 1분 안에 되돌린다.
- 워치독이 되돌린 이유를 `/tmp/lidguard_last_revert`에 남기고, 창에 "해제됨 · 시간이 끝나 잠자기로 돌아갔습니다" 같은 상태를 보여준다. 해제 버튼을 누른 뒤에는 `SleepDisabled`가 실제로 0인지 다시 확인한다.
- 닫힘 유지 중에는 "가방에 넣기 전에 남은 시간을 확인하세요" 안내를 보여준다.
- GitHub Releases 기반 자동 업데이트.

## 1.6.0 가볍게

- 화면 갱신(1초)에서 셸을 띄우던 확인을 모두 네이티브로 바꿨다. 뚜껑 상태와 `SleepDisabled`는 IOKit `IOPMrootDomain`에서, 프로세스 생존은 `kill(pid, 0)`(EPERM은 살아 있음)로 읽는다. 1초마다 실행하던 외부 프로그램 약 10개가 0개가 됐고, 뚜껑 상태 한 번 읽기가 약 19ms에서 약 17µs로 줄었다.
- 창이 가려지거나 최소화되면 그리기와 레이아웃을 건너뛴다. 타이머에 여유(tolerance)를 줘 macOS가 깨우기를 묶을 수 있게 했다.
- 열림 모드는 `caffeinate`와 감시 프로세스 대신 앱 안 IOPM 요청 하나로 끝난다.
- 감시 스크립트(bash)와 `daemonize.py`(python)를 없애고, 같은 실행 파일의 Swift 감시 모드로 옮겼다. `POSIX_SPAWN_SETSID`로 관리자 셸과 수명을 끊는다. `pmset`은 켤 때 한 번, 끌 때 한 번만 실행하고, 과열은 `ProcessInfo.thermalState`로 판단한다. 2초 간격이라 해제가 빨라졌고, SIGTERM을 받아도 잠자기를 되돌린다. 같은 조건(10초, 1초 간격)에서 CPU 시간 0.47초→0.04초, `pmset` 실행 22회→2회.
- 강제 종료 감지는 앱 이름(`pgrep`) 대신 앱 PID로 한다.
- 업데이트 확인은 임시(ephemeral) 네트워크 세션을 쓰고 끝나면 닫는다. 빌드는 `-dead_strip`과 `strip -x`.

## 개발

```bash
bash scripts/build.sh
bash tests/test_watchdog.sh   # 가짜 pmset·뚜껑·과열로 감시 모드 14가지 시나리오
bash tests/test_native.sh     # 실제 Mac에서 IOKit·kill·IOPM 요청·호출 비용 확인
bash scripts/release.sh [노트파일]   # Info.plist 버전으로 v태그 릴리스, zip + sha256 업로드
```
