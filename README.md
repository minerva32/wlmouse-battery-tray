# WLMouse Battery Tray Monitor

Windows 작업표시줄 시스템 트레이에 WLMouse 배터리 잔량을 숫자로 표시하는 경량 모니터입니다.

A lightweight Windows system-tray monitor that displays the live battery percentage of
WLMouse wireless mice (Beast MAX 8K / Beast X 8K and their receivers) as a number drawn
directly on the tray icon.

![tray icon concept](https://img.shields.io/badge/icon-live%20battery-000000)
## Quick Start (받자마자 바로 실행)

**가장 빠른 방법** — 아래 단계만 따라 하시면 됩니다:

1. 이 저장소를 다운로드하세요 (초록 `Code` 버튼 → `Download ZIP`) 또는
   ```
   git clone https://github.com/minerva32/wlmouse-battery-tray.git
   ```
2. 압축을 풀고 폴더로 이동
3. **`install.bat`을 더블클릭**
   - 트레이 모니터가 즉시 실행됩니다
   - 로그인 시 자동 시작 여부를 물어봅니다 (Y 권장)
4. 작업표시줄 오른쪽 트레이 영역(`^`)에서 **검정 네모에 숫자가 표시된 아이콘**을 확인하세요

> ✨ `hidapitester.exe` 바이너리가 이미 포함되어 있어 별도 다운로드 불필요합니다.

이후에는 `start.bat`을 더블클릭하거나, 자동 시작을 등록했다면 로그인 시 자동으로 실행됩니다.


## Features

- **Live tray icon** — 배터리 %가 아이콘 자체에 표시 (매 5분 자동 갱신)
- **Color-coded by state** (검정 배경 + 글자 색)
  - 🟢 초록 — 정상 (임계값 초과)
  - 🟠 주황 — 부족 (11% ~ 임계값)
  - 🔴 빨강 — 위험 (10% 이하)
  - 🔵 파랑 + ⚡ — 충전 중
- **Tooltip** — 마우스 호버 시 `🔋 WLMouse: 74%` / 충전 중 `⚡ WLMouse: 80%`
- **Right-click menu**
  - 지금 새로고침
  - 경고 임계값 ▶ (10 / 15 / 20 / 30%) — 변경 시 `settings.json`에 저장
  - 종료
- **자동 기기 감지** — 지원하는 WLMouse 수신기(VID `0x36A7`) 자동 인식

## Supported devices

| 제품 | PID | 프로토콜 |
|---|---|---|
| Beast MAX 8K Receiver | `A880` | Feature Report |
| Beast X 8K Receiver | `A883` | Feature Report |
| Beast X 8K | `A884` | Feature Report |

Beast X (비-8K, PID `A887`/`A888`)는 Interrupt Endpoint 방식을 사용하여 현재 지원하지 않습니다.

## Requirements

- Windows 10/11
- PowerShell 5.1+ (Windows 기본 제공)
- 호환되는 WLMouse 수신기 (Beast MAX 8K / Beast X 8K 계열)

> ✅ `hidapitester.exe` 바이너리가 저장소에 포함되어 있습니다 (GPL v3 라이선스, `hidapitester/LICENSE` 참고). 별도 다운로드 불필요.

## Setup

저장소에는 아래 파일들이 포함되어 있습니다:

```
wlmouse-battery-tray/
├── install.bat                   # 더블클릭 한 번으로 설치 + 실행 (Quick Start)
├── start.bat                     # 트레이 모니터 빠른 실행
├── wlmouse_battery_tray.ps1     # 메인 스크립트 (트레이 모니터)
├── wlmouse_battery_monitor.ps1  # (선택) 토스트 알림 전용 스크립트
├── run_silently.vbs             # 백그라운드 실행용 런처
├── test_parser.ps1              # HID 응답 디버깅 도구
├── settings.json                # 자동 생성 (임계값 등) - .gitignore 제외
└── hidapitester/
    ├── hidapitester.exe         # GPL v3, todbot/hidapitester 포함
    └── LICENSE                  # hidapitester GPL v3 라이선스
```

## Usage

**트레이 모니터 시작** — `run_silently.vbs` 더블클릭 (또는 작업 스케줄러에 로그온 시 실행되도록 등록)

트레이 오버플로우 영역(`^`)에서 숫자 아이콘을 찾을 수 있습니다. 항상 보이게 하려면 작업표시줄로 드래그하세요.

## How it works

HID Feature Report 프로토콜은 [mee7ya/wlmouse-cli](https://github.com/mee7ya/wlmouse-cli)와
[snems/WLPower](https://github.com/snems/WLPower)의 역엔지니어링 결과를 따릅니다.

1. 65바이트 Feature Report 전송 (`cmd 0x83` at offset 6)
2. ~120ms 대기 (장치가 응답을 준비할 시간)
3. Feature Report 읽기
4. 활성 응답 검증 (`status 0xA1` + `cmd echo 0x83`)
5. `bytes[8]` = 배터리 %, `bytes[9]` = 충전 여부

## Files

- `wlmouse_battery_tray.ps1` — 메인 트레이 모니터
- `wlmouse_battery_monitor.ps1` — 배터리 부족 시 토스트 알림만 띄우는 단순 버전
- `test_parser.ps1` — HID 응답 파싱 디버깅 스크립트
- `run_silently.vbs` — 창 없이 백그라운드 실행

## License

MIT License — 본 저장소의 스크립트 코드에 한합니다.
`hidapitester.exe`는 해당 프로젝트의 라이선스를 따릅니다.
