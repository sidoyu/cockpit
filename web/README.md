# web/ — 웹 프런트도어 (가이드 / 런처)

비개발 동료가 처음 도착하는 **안내 페이지**다. OS를 감지해 맞는 설치 경로를 보여주고,
거버넌스 경계를 먼저 읽게 한 뒤, **OS별 한 단계**(Windows=`Cockpit-Install.cmd` 더블클릭 · macOS=플러그인 명령 복사·붙여넣기)로 설치를 시작하게 한다.

> ⚠️ 이것은 **install engine 이 아니라 guide/launcher** 다. 브라우저는 로컬에 무엇도 설치하지 못한다
> (`ms-appinstaller:` URI 도 2023-12 이후 기본 비활성). 실제 설치는 사용자가 직접 명령을 실행하고,
> 그 뒤 설치 마법사(`/cockpit-setup`)가 안내한다.

## 구성 (의존성·빌드 단계 없음)

| 파일 | 역할 |
|------|------|
| `index.html` | 단일 페이지. 거버넌스 동의 → OS 트랙 → 사전 준비 체크리스트 → 설치(Windows=`Cockpit-Install.cmd` 더블클릭) → 설치 후 → 대시보드 켜기(로컬) → 다운로드 → 원격(고급). |
| `assets/style.css` | 직각·청결·차분 테마. 다크모드 대응. 외부 폰트/CDN 미사용 → `file://` 에서도 동작. |
| `assets/app.js` | OS 감지(Windows 우선) + 트랙 토글 · 복사 버튼 · 동의 게이팅 · 체크리스트 영속(localStorage). 외부 통신·추적 없음. |

정적 파일뿐이라 **아무 정적 호스트**(사용자 도메인·Vercel·GitHub Pages)에 그대로 올리거나, 로컬에서 `index.html`을 열어 미리볼 수 있다.

## 동작 요약

- **OS 감지**: `navigator.userAgentData.platform` → `userAgent` 정규식 폴백 → 실패 시 **Windows 트랙**(권장 경로) 기본. 사용자가 탭으로 직접 전환 가능.
- **동의 게이팅**: 거버넌스 경계 체크박스를 켜야 설치 명령의 복사 버튼이 활성화된다(보안이 아니라 **경계 재확인 의도** — 동의는 매 방문 새로 받음).
- **복사 버튼**: `navigator.clipboard` → `execCommand` 폴백.
- **체크리스트**: 사전 준비 항목만 localStorage 영속(편의). 동의 체크는 영속 안 함.

## 릴리스 치환 참조 (배포자용)

v0.1.2 발행 값 기준. **페이지 본문은 v0.1.3 원터치 UX(`.cmd` 더블클릭·로컬 대시보드)를 안내**하며, 아래 v0.1.3 자산·버전 치환은 **§4-6 릴리스 단계**에서 확정한다(문구/구조는 §4-5에서 완료). 갱신 항목:

- [x] 마켓플레이스/릴리스 URL → `github.com/sidoyu/cockpit` 로 치환.
- [x] Windows `Install-Cockpit.ps1`(+ 스테이지드 `Install-Cockpit-Staged.ps1`) / `cockpit-wsl.tar.gz` / `provenance.json` 링크 + **SHA-256 체크섬** 채우기(이 빌드는 코드서명 없음 — 무결성은 체크섬 대조로만 보장, Authenticode 서명층 없음). 이미지 SHA-256 은 `Install-Cockpit.ps1` 의 `$PinnedSha256` 에도 박는다. **릴리스마다 재계산 필수.**
- [ ] **v0.1.3 신규 자산 2종**: `Cockpit-Install.cmd`(원클릭 설치)·`Cockpit-Dashboard.cmd`(로컬 대시보드) → release 자산 추가 + 다운로드 표의 링크·SHA-256 채우기(현재 다운로드 표는 `발행 시 채움` 플레이스홀더). 표의 기존 ps1/tar.gz URL·해시와 푸터 버전(`#ver`)도 v0.1.3으로 재계산·치환. **§4-6 릴리스에서 일괄 처리.**
  - ⚙️ **이 항목은 이제 `publish-gate.sh` 가 기계 강제**(BUILD-STATUS #18): `발행 시 채움` 잔존(§2a)·표 두 .cmd SHA-256 ≠ `sha256(repo .cmd)`(§2b)·`.cmd` 부재(§1b/§1c) 시 BLOCK. **순서 주의**: `Cockpit-Install.cmd` 의 SHA 는 `PS1_URL/PS1_SHA256` 치환을 **확정한 뒤** 계산해 표에 기입(먼저 채우면 §2b 가 stale 로 BLOCK). 절차=`docs/RELEASE-v0.1.3-runbook.md`.
- [x] 다운로드 표 체크섬 칸 채우기(릴리스마다 재계산).
- [ ] 데모 영상/GIF placeholder(`#demo-ph`) → 실제 미디어 삽입.
- [x] `<a href="../GOVERNANCE.md">` 등 상대 링크가 배포 사이트 구조에서 유효한지 확인(같은 repo를 통째로 호스팅하면 그대로 동작; 별도 호스팅이면 절대 URL로).
- [x] 푸터 버전(`#ver`)이 `marketplace.json`/`plugin.json` 버전과 일치하는지(릴리스마다 확인).
- [x] 발행 정책 문구: **자체호스팅 대시보드=기본 OFF(opt-in)** · 원격조종(claude.ai Remote Control)=사전적용 ON — 두 용어를 혼용하지 말 것.

## 알려진 의존성 (다른 단계가 채움)

- **설치 명령 본체**: 플러그인 마켓플레이스가 **발행**돼야 `/plugin marketplace add` 가 동작한다(현재 미push·보류).
- **Windows 트랙**: 원클릭 설치 `Cockpit-Install.cmd`(ps1 자가 다운로드+핀 해시 검증) 구현·무설치 SSH 실기 PASS(2026-07-03). 설치 단계는 파워쉘 수동 실행 → `.cmd` 더블클릭으로 교체됨(수동 ps1 경로는 "고급"으로 보존). 남은 실기(실설치 종단·SmartScreen 화면 실측·Edge `--app` 창 수명)는 **v0.1.4 fresh 실기 체크리스트**로 이월.
- **메모리 자동추출 키(G21·BYO)**: 자동추출(외부 송신)은 **개인 Anthropic API 키 옵트인**이다. 등록은 설치 마법사 3.6 단계(`setup.py set-extraction-key`)가 안내하며, 키는 대화에 남기지 않고 `~/.config/cockpit/extraction-key`(0600)에 저장된다. 미등록=수동 기억(정직 고지). 발급·과금 안내(console.anthropic.com·pay-per-token·spend limit)는 마법사 SKILL.md 3.6 이 단일 출처. 페이지(index.html "메모리 시스템" 카드)는 옵트인·별도 과금만 한 줄로 고지.
- **원격 대시보드**: 접근 통제(IP allowlist·CSRF)는 **뷰어(공개 repo)** 가 제공하며 `claude-session-dashboard` `d4482d5`(2026-06-23) 이상에 반영돼 있다. 권장 핀 `9f2bdba`(2026-07-03) 이상은 기본 bind `127.0.0.1`(로컬 전용)+`CC_DASH_BIND`·idle-exit 지원 — 옵트인 전 원격 노출 자체가 없다. 그 이전·오설치 버전엔 없을 수 있어, 페이지는 버전과 무관하게 "켜기 전 자가검증(VPN 밖에서 403 확인)"을 명시한다. 상세: `../plugin/dashboard/README.md`.
