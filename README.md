# cc-companion / cockpit

> 한 사람의 Claude Code 운영 환경을, 비개발 동료가 **"마법사가 시키는 대로"** 따라 하면 거의 그대로 깔 수 있게 만든 패키지.
> 개인정보·시크릿은 **전부 제거**되어 있고, 각자 자기 것을 **설치 마법사**로 주입한다.

⚠️ **먼저 [GOVERNANCE.md](./GOVERNANCE.md)를 읽으세요.** 이 환경은 강력하지만 느슨하게 설정되어 있어(bypass·원격·이중 송출) 사용 경계를 반드시 지켜야 합니다.

---

## 무엇이 깔리나

- **작업 규율(행동층)**: 자율 진행 경계, 두 순간 자기점검, 읽기/검색 위생 등. → 설치 마법사가 `~/.claude/CLAUDE.md`로 적용(플러그인은 CLAUDE.md를 자동 주입할 수 없으므로 마법사가 설치한다).
- **메모리 시스템**: 파일 기반(md + python 훅). 세션 시작 시 상태 주입, 종료 시 기억 후보 추출, 인덱스 자동 재생성, 동시 세션 쓰기 보호.
- **안전망**: 파괴/비가역 명령 금지목록(deny-list), 긴급정지(kill switch), 감사 로그.
- **보조 검토(Codex, 선택)**: 외부 LLM CLI 를 "보이지 않는 2차 검토자"로 호출. 기본 비활성·스위치식·과금 차단. 이중 송출 고지(`plugin/codex/`).
- **원격 대시보드(선택)**: 세션 로그 대시보드를 개인 VPN 내부 기기에서 보기/조종. 거버넌스·설정·`disable-remote`·접근 통제 레이어 제공(뷰어 본체는 공개 repo 참조). `plugin/dashboard/`.
- **설치 마법사**: 기본 사용자·메모리 디렉터리·(선택)보조 검토·(선택)원격 제어를 안내하고, 충돌 검사·dry-run·롤백을 제공.

> **현 빌드의 위험 기능 기본값**: bypass=ON · 보조 검토(Codex)=기본 비활성(스위치식) · 원격 대시보드=**기본 비활성(명시 opt-in)**. 원격은 *설계상 on-by-default* 이지만 이 빌드에선 설치 마법사 자동 활성화 배선 전이라 직접 설정해야 켜진다. 끄기/상태: GOVERNANCE.md 6장.
>
> **⚠ 출고 상태 ≠ 운영 모드(Windows 골든 이미지)**: 위 "bypass=ON" 은 설치 마법사(`/cockpit-setup`) 동의를 거친 뒤의 *운영 모드*다. Windows WSL2 골든 이미지 자체는 **위험 기능 전부 OFF 로 출고**되며(bypass 미적용·Codex 스위치 없음·원격 자동시작 없음), 사용자가 첫 실행 때 동의 게이트를 통과해야만 켜진다. 이미지 OFF 출고 불변식은 `scripts/smoke-image.sh` 가 빌드마다 검증한다.

---

## 구조

```
cc-env-pack/                       # = 마켓플레이스 루트
├── .claude-plugin/marketplace.json   # 마켓플레이스 매니페스트
├── GOVERNANCE.md                     # 거버넌스 경계 문서 (먼저 읽기)
├── README.md  ·  LICENSE  ·  .gitignore
├── plugin/                           # = 플러그인 "cockpit"  (source: "./plugin")
│   ├── .claude-plugin/plugin.json
│   ├── hooks/
│   │   ├── hooks.json                # 훅 배선(${CLAUDE_PLUGIN_ROOT} 사용)
│   │   └── memory/                   # 이식된 메모리 시스템 훅(경로 파라미터화)
│   ├── skills/setup-wizard/SKILL.md  # 첫 실행 마법사
│   ├── safety/                       # deny-list · 긴급정지 · 감사로그
│   ├── templates/CLAUDE.md.template  # 살균된 행동 규율(플레이스홀더)
│   └── memory-template/              # 빈 스키마 + 예시 메모리
├── scripts/secret-scan.sh            # 발행 전 시크릿 스캔
└── docs/
```

경로는 **하드코딩하지 않는다.** 훅은 `${CLAUDE_PLUGIN_ROOT}`(플러그인 설치 위치)와 `${HOME}`, 그리고 메모리 디렉터리 환경변수(`CC_MEMORY_DIR`, 기본 `~/.claude/cc-memory`)로 동작한다.

---

## 설치 (마법사가 자세히 안내)

```bash
# 1) 마켓플레이스 등록
/plugin marketplace add https://github.com/sidoyu/cockpit
# (기여자 로컬 테스트:  claude plugin marketplace add ./cc-env-pack)

# 2) 플러그인 설치
/plugin install cockpit@cc-companion

# 3) 첫 실행 설정 마법사
/cockpit-setup        # (또는 스킬 자동 호출)
```

Windows(WSL2) 설치·다운로드·체크섬은 웹 안내(`web/index.html`) 참조. 이 배포본은 **코드서명 없음(unsigned)** — 무결성은 SHA-256 체크섬 대조로 보장한다.

---

## 릴리스 (배포자용)

발행마다 `bash scripts/publish-gate.sh` 가 차단 게이트를 돌린다(placeholder 잔존·핀 미고정·미서명 매니페스트·발행 트리 시크릿·docs 노출 검사). 통과 조건:

- [ ] `scripts/publish-gate.sh` BLOCK 0
- [ ] 매니페스트 `homepage`/`repository`/`owner`/`author` 실제값
- [ ] `version` bump(발행마다)
- [ ] GOVERNANCE.md 동의 문구 검토

> **상태**: v0.1.0 — 미서명+체크섬 발행(코드서명 인증서 미보유, 무결성은 SHA-256 핀 대조). 공개 repo `github.com/sidoyu/cockpit`.
