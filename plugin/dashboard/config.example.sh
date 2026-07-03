#!/bin/bash
# cockpit 원격 대시보드 설정 (예시) — 복사해서 채운다:
#   cp config.example.sh ~/.config/cockpit/dashboard.env
#   chmod 600 ~/.config/cockpit/dashboard.env   # 경로·키가 들어가므로 owner-only
#
# 이 파일은 뷰어(공개 claude-session-dashboard)와 이 디렉터리의 템플릿이 함께 읽는다.
# ⚠️ 개인 IP·healthcheck UUID·API 키 실제 값을 패키지(git)에 커밋하지 말 것. 이 사본에만 둔다.

# ── 뷰어 설치 위치 ──────────────────────────────────────────────
# 공개 claude-session-dashboard 를 설치한 디렉터리(서버·변환기·PWA 본체).
export CC_DASH_HOME="${CC_DASH_HOME:-$HOME/claude-logs}"

# ── 서버 ────────────────────────────────────────────────────────
export CC_DASH_PORT="${CC_DASH_PORT:-18080}"
# 바인드 주소. 권장 핀 9f2bdba(2026-07-03)+ 의 뷰어는 이 변수를 존중하며 기본 127.0.0.1(로컬 전용).
# 정식 IPv4 리터럴만 허용 — 잘못된 값("0"·"localhost" 등)은 뷰어가 기동 시 에러로 종료한다(사일런트
# 폴백 없음). 다른 기기(폰 등) 열람이 필요할 때만 0.0.0.0 으로 바꾼다(그때도 뷰어 allowlist 는 유지).
# ⚠ 구핀(d4482d5 이하)은 이 변수를 읽지 않고 0.0.0.0 하드코딩이었다 — 핀을 올려 쓸 것(README "바인드와
# 노출의 진실"·"플랫폼 메모").
export CC_DASH_BIND="${CC_DASH_BIND:-127.0.0.1}"

# 유휴 자가 종료(선택, 9f2bdba+): 허용된(allowlist 통과) 요청이 N초간 없으면 뷰어 서버가 스스로 종료.
# 비우면 끔(기본). 런처가 서버 수명을 관리하는 구성(창 닫힘=종료)의 백스톱용 — 장시간 요청 중단 방지를
# 위해 300 이상 권장(미만이면 뷰어가 기동 시 경고).
export CC_DASH_IDLE_EXIT_SECS="${CC_DASH_IDLE_EXIT_SECS:-}"
# 대시보드 표시 타임존(미설정 시 UTC).
export CC_DASH_TZ="${CC_DASH_TZ:-UTC}"
# python 실행 파일(homebrew/시스템 등 환경에 맞게).
export CC_DASH_PYTHON="${CC_DASH_PYTHON:-python3}"

# ── 접근 통제(개인 VPN 내부 한정) ───────────────────────────────
# 허용할 사설 VPN 대역. 기본 = Tailscale CGNAT(100.64.0.0/10). 다른 VPN 이면 그 대역으로 교체.
# localhost 는 뷰어가 항상 허용한다.
export CC_DASH_ALLOW_CIDR="${CC_DASH_ALLOW_CIDR:-100.64.0.0/10}"

# ── 운영 가시성(선택) ───────────────────────────────────────────
# healthcheck ping URL. 비우면 ping 안 함(기능에 영향 없음). 예: https://hc-ping.com/<본인-UUID>
export CC_DASH_HEALTHCHECK_URL="${CC_DASH_HEALTHCHECK_URL:-}"

# ── AI 제목 요약(선택) ──────────────────────────────────────────
# cron 변환이 세션 제목을 LLM 으로 다듬게 하려면 별도 600 권한 키파일 경로를 둔다(없으면 첫 발화 제목).
# ⚠️ 외부 송출: 세션 본문 일부가 LLM 제공자로 전송된다. 민감정보 금지(GOVERNANCE 3장).
export CC_DASH_SUMMARY_KEY_ENV="${CC_DASH_SUMMARY_KEY_ENV:-$HOME/.config/cockpit/dashboard-summary.env}"
