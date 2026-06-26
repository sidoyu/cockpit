# web/ — 웹 프런트도어 (가이드 / 런처)

비개발 동료가 처음 도착하는 **안내 페이지**다. OS를 감지해 맞는 설치 경로를 보여주고,
거버넌스 경계를 먼저 읽게 한 뒤, **복사·붙여넣기 한 번**으로 설치를 시작하게 한다.

> ⚠️ 이것은 **install engine 이 아니라 guide/launcher** 다. 브라우저는 로컬에 무엇도 설치하지 못한다
> (`ms-appinstaller:` URI 도 2023-12 이후 기본 비활성). 실제 설치는 사용자가 직접 명령을 실행하고,
> 그 뒤 설치 마법사(`/cockpit-setup`)가 안내한다.

## 구성 (의존성·빌드 단계 없음)

| 파일 | 역할 |
|------|------|
| `index.html` | 단일 페이지. 거버넌스 동의 → OS 트랙 → 사전 준비 체크리스트 → 설치 명령 → 설치 후 → 다운로드 → 원격(고급). |
| `assets/style.css` | 직각·청결·차분 테마. 다크모드 대응. 외부 폰트/CDN 미사용 → `file://` 에서도 동작. |
| `assets/app.js` | OS 감지(Windows 우선) + 트랙 토글 · 복사 버튼 · 동의 게이팅 · 체크리스트 영속(localStorage). 외부 통신·추적 없음. |

정적 파일뿐이라 **아무 정적 호스트**(사용자 도메인·Vercel·GitHub Pages)에 그대로 올리거나, 로컬에서 `index.html`을 열어 미리볼 수 있다.

## 동작 요약

- **OS 감지**: `navigator.userAgentData.platform` → `userAgent` 정규식 폴백 → 실패 시 **Windows 트랙**(권장 경로) 기본. 사용자가 탭으로 직접 전환 가능.
- **동의 게이팅**: 거버넌스 경계 체크박스를 켜야 설치 명령의 복사 버튼이 활성화된다(보안이 아니라 **경계 재확인 의도** — 동의는 매 방문 새로 받음).
- **복사 버튼**: `navigator.clipboard` → `execCommand` 폴백.
- **체크리스트**: 사전 준비 항목만 localStorage 영속(편의). 동의 체크는 영속 안 함.

## 릴리스 치환 참조 (배포자용)

v0.1.1 발행 — 명령·링크는 실제 값으로 치환됨. 다음 릴리스 시 갱신 항목:

- [x] 마켓플레이스/릴리스 URL → `github.com/sidoyu/cockpit` 로 치환.
- [ ] Windows `Install-Cockpit.ps1`(+ 스테이지드 `Install-Cockpit-Staged.ps1`) / `cockpit-wsl.tar.gz` / `provenance.json` 링크 + **SHA-256 체크섬** 채우기(이 빌드는 코드서명 없음 — 무결성은 체크섬 대조로만 보장, Authenticode 서명층 없음). 이미지 SHA-256 은 `Install-Cockpit.ps1` 의 `$PinnedSha256` 에도 박는다.
- [ ] 다운로드 표의 `—（배포 시）` 체크섬 칸 채우기.
- [ ] 데모 영상/GIF placeholder(`#demo-ph`) → 실제 미디어 삽입.
- [ ] `<a href="../GOVERNANCE.md">` 등 상대 링크가 배포 사이트 구조에서 유효한지 확인(같은 repo를 통째로 호스팅하면 그대로 동작; 별도 호스팅이면 절대 URL로).
- [ ] 푸터 버전(`#ver`)이 `marketplace.json`/`plugin.json` 버전과 일치하는지.
- [ ] 발행 정책 결정 반영: 원격 기본값(현재 OFF·opt-in) 문구 · 뷰어 버전 핀.

## 알려진 의존성 (다른 단계가 채움)

- **설치 명령 본체**: 플러그인 마켓플레이스가 **발행**돼야 `/plugin marketplace add` 가 동작한다(현재 미push·보류).
- **Windows 트랙**: WSL2 부트스트랩(단계 4)·골든 이미지가 아직 없어 `⏳ 준비 중`으로 표시. 단계 4에서 실제 명령·서명 부트스트랩으로 교체.
- **원격 대시보드**: 접근 통제(IP allowlist·CSRF)는 **뷰어(공개 repo)** 가 제공하며 `claude-session-dashboard` `d4482d5`(2026-06-23) 이상에 반영돼 있다. 그 이전·오설치 버전엔 없을 수 있어, 페이지는 버전과 무관하게 "켜기 전 자가검증(VPN 밖에서 403 확인)"을 명시한다. 상세: `../plugin/dashboard/README.md`.
