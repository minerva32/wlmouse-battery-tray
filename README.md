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
- **모든 WLMouse 자동 지원** — VID `0x36A7` 장비 자동 감지, PID별 알맞은 프로토콜로 배터리 조회

## Supported devices

모든 WLMouse 마우스를 자동으로 지원합니다. HID 장치에서 VID `0x36A7`을 검색해서, 알려진 PID는 해당 프로토콜(Feature Report 또는 Interrupt Endpoint)로, 알려지지 않은 PID는 두 방식을 순차적으로 시도합니다.

| 제품 | PID | 프로토콜 |
|---|---|---|
| Beast MAX 8K Receiver | `A880` | Feature Report ✅ 검증됨 |
| Beast X 8K Receiver | `A883` | Feature Report |
| Beast X 8K | `A884` | Feature Report |
| Beast X Receiver | `A887` | Interrupt Endpoint |
| Beast X | `A888` | Interrupt Endpoint |
| Beast X Mini / Mini Pro / Pro / Miao / 기타 | 미확인 PID | 자동 감지 (두 프로토콜 순차 시도) |

WLMouse의 모든 마우스는 공식 "MOUSE Connect" 웹 설정 앱을 공유하므로, 위 테이블에 없는 신형/미확인 모델도 대부분 자동으로 잡힙니다.

## Requirements

- Windows 10/11
- PowerShell 5.1+ (Windows 기본 제공)
- WLMouse 마우스 중 하나 (Beast MAX 8K / Beast X 8K / Beast X / Mini / Pro / Miao 등)

> ✅ `hidapitester.exe` 바이너리가 저장소에 포함되어 있습니다 (GPL v3 라이선스, `vendor/hidapitester/LICENSE` 참고). 별도 다운로드 불필요.

## Setup

루트 폴더에는 사용자가 실행할 파일만 남겨두었습니다:

```
wlmouse-battery-tray/
├── install.bat          # 처음 실행: 트레이 시작 + 로그인 자동 시작 등록 옵션
├── start.bat            # 수동으로 트레이 모니터 시작
├── diagnose.bat         # 문제 발생 시 진단 보고서 생성
├── README.md
├── app/                 # 내부 스크립트 (직접 실행할 필요 없음)
│   ├── wlmouse_battery_tray.ps1
│   ├── run_silently.vbs
│   ├── register_startup.ps1
│   ├── diagnose.ps1
│   ├── wlmouse_battery_monitor.ps1
│   └── test_parser.ps1
├── vendor/
│   └── hidapitester/
│       ├── hidapitester.exe
│       └── LICENSE
└── data/                # 자동 생성: 로그/설정 (git 제외)
```

## Usage

- **처음 설치**: `install.bat` 더블클릭
- **수동 실행**: `start.bat` 더블클릭
- **문제 진단**: `diagnose.bat` 더블클릭 후 생성되는 `diagnostic_report.txt` 첨부

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

- `install.bat` — 사용자가 처음 실행할 설치/자동시작 등록 파일
- `start.bat` — 트레이 모니터 빠른 실행
- `diagnose.bat` — 문제 발생 시 `diagnostic_report.txt` 생성
- `app/` — 내부 PowerShell/VBS 스크립트
- `vendor/hidapitester/` — GPL v3 `hidapitester.exe`와 라이선스
- `data/` — 로그/설정 자동 생성 폴더 (`.gitignore` 제외)

## Troubleshooting (문제 해결)

배터리가 표시되지 않거나 이상하게 동작한다면, **`diagnose.bat`을 더블클릭**하세요. 약 30초 안에 `diagnostic_report.txt` 파일이 생성됩니다. 이 파일에는:

- 윈도우 버전 / PowerShell 버전
- 연결된 WLMouse 장치의 PID와 인터페이스 정보
- HID 응답 원본 데이터와 해석
- 최근 모니터 로그 (마지막 30줄)
- 현재 설정값

이 정보가 있으면 대부분의 문제를 빠르게 진단할 수 있습니다.

### 자주 묻는 문제

| 증상 | 해결책 |
|---|---|
| 아이콘이 안 뜨거나 "응답 없음" | 마우스를 움직여서 깨운 뒤 몇 초 후 다시 확인 (5분 폴링 주기) |
| 항상 0% 로 표시 | `diagnose.bat` 실행 → status byte가 `0xA1`이 아니면 마우스가 절전 중 |
| 다른 WLMouse 모델에서 안 됨 | `diagnose.bat` 보고서를 이슈로 제출해 주세요 (아래 참고) |
| 설치 후 아이콘이 안 보임 | 작업표시줄 트레이 오버플로우 `^` 클릭 → 아이콘을 작업표시줄로 드래그 |

## Feedback (피드백)

**모든 피드백을 환영합니다!** 버그 신고, 기능 제안, 새로운 WLMouse 모델 지원 요청, 코드 개선 아이디어, 사용 후기 전부 환영입니다. 🙌

- **버그 / 기능 요청**: [GitHub Issues](https://github.com/minerva32/wlmouse-battery-tray/issues)에 새 이슈를 열어주세요
- **새 모델 지원 요청**: 꼭 `diagnostic_report.txt`를 첨부해 주세요 — 그 안에 PID와 응답 패턴이 있으면 바로 지원 추가 가능합니다
- **코드 기여**: Pull Request 언제든 환영합니다
- **단순 질문**: 이슈에 "question" 라벨로 남겨주세요

특히 아래 장비를 가진 분들의 피드백이 필요합니다:
- Beast X (비-8K), Beast X Mini / Mini Pro / Pro / Miao — Interrupt 프로토콜 코드는 있지만 실장비 검증이 안 되었습니다. `diagnose.bat` 한 번만 돌려주시면 지원을 확정할 수 있어요.

이 프로젝트는 역엔지니어링에 기반하고 있어, 다양한 실제 장비에서의 동작 보고가 매우 소중합니다.


## License

MIT License — 본 저장소의 스크립트 코드에 한합니다.
`hidapitester.exe`는 해당 프로젝트의 라이선스를 따릅니다.
