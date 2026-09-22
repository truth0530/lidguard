# 잠자기 방지 (lidguard) 1.4.0

뚜껑 닫힘/열림 유지 시간을 따로 두고, 시간이 끝나면 실제로 잠자기로 돌아갑니다.

## 동작

- **뚜껑을 닫아도 켜 두기**: 시작 즉시 `pmset disablesleep 1`. 뚜껑이 아직 열려 있어도 켭니다. Apple Silicon은 뚜껑을 닫는 순간 `Clamshell Sleep`이라, 닫힌 뒤에 켜면 이미 늦습니다. 끝나면 덮개가 닫혀 있으면 `sleepnow`.
- **뚜껑이 열렸을 때만 켜 두기**: `caffeinate`로만 유지. **끔**이면 화면·시스템 잠자기를 막지 않습니다.
- 닫힘 유지가 켜져 있는 동안은 화면 자동꺼짐도 막힙니다. 창을 닫거나 종료하면 워치독이 `disablesleep`을 되돌립니다.

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

```bash
bash tests/test_watchdog.sh
bash scripts/build.sh
```
