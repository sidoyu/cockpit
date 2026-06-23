---
name: cockpit-setup
description: cockpit 첫 실행 설정 마법사. Claude Code 운영 환경(메모리 시스템·행동 규율·안전망·선택적 bypass)을 안내에 따라 설치·점검·되돌리기. 사용자가 "cockpit 설정", "setup", "설치 마법사", 또는 cockpit 플러그인 최초 사용 시 호출.
---

# cockpit 설정 마법사

이 스킬은 비개발 사용자가 **안내에 따라** cockpit 환경을 안전하게 설치하도록 돕는다. 모든 변경은 **가역**(백업+rollback)이며, 위험 동작(bypass)은 **명시적 동의** 뒤에만 한다.

도구: 같은 폴더의 `setup.py` (결정적 CLI). 경로 = `${CLAUDE_PLUGIN_ROOT}/skills/setup-wizard/setup.py`.

## 진행 순서 (이 순서를 따른다)

### 0. 거버넌스 동의 (건너뛰지 말 것)
먼저 `${CLAUDE_PLUGIN_ROOT}/../GOVERNANCE.md`(또는 저장소 루트 `GOVERNANCE.md`)의 **0·2·3·6장 요약**을 한국어로 보여주고, 사용자에게 다음을 명시적으로 확인받는다:
- 개인 PC·비업무·비민감 데이터 전용, **환자정보·PII·기밀 입력 금지**
- bypass·원격·(보조 검토 시) 이중 송출을 이해
- 끄는 법/지우는 법을 알고, 최종 책임이 본인에게 있음

동의하지 않으면 **설치를 중단**한다.

### 1. 점검 (doctor)
```
python3 "${CLAUDE_PLUGIN_ROOT}/skills/setup-wizard/setup.py" doctor
```
출력의 ✗(치명)·⚠(주의)를 사용자에게 한국어로 풀어 설명한다. 특히:
- `~/.claude/CLAUDE.md` 가 이미 있고 템플릿과 다르면: **기본은 보존(덮어쓰지 않음)**이라 install 이 거부된다. 기존 운영 규칙을 잃지 않으려면 그대로 두고 템플릿 내용을 수동 병합하거나, 정말 교체하려면 `--replace-claude-md`(교체 전 자동 백업 → rollback 복원 가능)를 함께 전달한다.
- `ANTHROPIC_API_KEY` 가 없으면: 메모리 **자동 추출**만 비활성(나머지는 정상)임을 알린다. 키 설정을 원하면 안내(개인 키, 셸 프로필 export).

### 2. 미리보기 (dry-run)
```
python3 ".../setup.py" install            # 기본이 dry-run
```
바뀔 작업 목록을 보여주고 사용자 확인을 받는다.

### 3. bypass 결정 (위험 — 멈춰 질문)
"권한 확인 생략(bypass)을 켤까요?"를 **명시적으로** 묻는다. 장점(매번 확인 팝업 없음)과 위험(파괴 명령 자동 실행 가능 — deny-list 가 backstop)을 균형있게 설명한다. 추천: 처음엔 **끄고 시작**, 익숙해지면 켜기. 사용자가 켜기로 하면 다음 단계에 `--enable-bypass` 추가.

### 4. 설치 (apply)
```
python3 ".../setup.py" install --apply [--i-accept-governance] [--enable-bypass] [--replace-claude-md]
```
`--i-accept-governance` 는 GOVERNANCE(특히 §3 이중 송출·§8 동의)를 읽고 동의했다는 신호다. **이 플래그가 있을 때만** ① `--enable-bypass`(권한 확인 생략)가 허용되고, ② **메모리 자동 추출의 외부 송신(egress)이 활성화**된다(없으면 세션 본문이 외부로 나가지 않음 — 키가 있어도 no-op). **0단계에서 사용자가 명시적으로 동의했을 때만** `--i-accept-governance` 를 전달한다. bypass 는 별도로 다시 묻는다(3단계). 기존 CLAUDE.md 가 다르면 `--replace-claude-md` 없이는 보존(거부)된다.
완료 후: ① `~/.claude/CLAUDE.md` 의 `{{...}}` 플레이스홀더(언어·역할·경로 약칭 등)를 사용자와 함께 채운다. ② 메모리 저장소(`~/.claude/cc-memory`)에 예시 메모리가 들어갔음을 알리고, 본인 것으로 교체/삭제하도록 안내한다. ③ 새 세션을 시작하면 세션 시작 훅이 PROJECT_STATUS 를 주입하고, 종료 시 기억 후보가 쌓임을 설명한다.

### 5. 사후 점검
```
python3 ".../setup.py" doctor
```
설치 상태가 반영됐는지 확인한다.

## 되돌리기 (rollback)
문제가 있거나 사용자가 원하면:
```
python3 ".../setup.py" rollback --latest    # 마지막 설치 백업으로 복원
python3 ".../setup.py" rollback --list      # 백업 스냅샷 목록
```
백업된 파일은 복원, 설치 때 새로 생긴 `CLAUDE.md`/`settings.json` 은 제거된다. 메모리·상태 디렉터리는 데이터 보호를 위해 **수동 삭제**(경로는 rollback 출력에 표시).

## 끄기/긴급정지 (사용자에게 안내)
- **보조 검토 끄기**: `rm ~/.claude/codex_enabled` (해당 기능 활성화 시)
- **bypass 끄기**: `setup.py rollback` 또는 settings.json 의 `permissions.defaultMode` 를 제거/`ask` 로
- **긴급정지(즉시 자동 진행 중단)**: `touch ~/.claude/CC_KILL_SWITCH` → 모든 Bash·쓰기 도구가 차단됨. 재개: `rm ~/.claude/CC_KILL_SWITCH`
- **감사 로그 확인**: `~/.claude/cc-companion/audit.log` (차단·강행 기록)

## 원칙
- 절대 사용자 데이터(기존 메모리·CLAUDE.md)를 백업 없이 덮어쓰지 않는다.
- 위험·비가역 단계(bypass)는 한 번에 하나씩, 동의를 받고 진행한다.
- 모든 셸 출력은 한국어로 풀어 설명한다(원문 로그는 그대로 인용 가능).
