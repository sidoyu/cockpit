---
name: cockpit-setup
description: cockpit 첫 실행 설정 마법사. Claude Code 운영 환경(메모리 시스템·행동 규율·안전망·선택적 bypass)을 안내에 따라 설치·점검·되돌리기. 사용자가 "cockpit 설정", "setup", "설치 마법사", 또는 cockpit 플러그인 최초 사용 시 호출.
---

# cockpit 설정 마법사

이 스킬은 비개발 사용자가 **안내에 따라** cockpit 환경을 안전하게 설치하도록 돕는다. 모든 변경은 **가역**(백업+rollback)이며, 위험 동작(bypass)은 **명시적 동의** 뒤에만 한다.

도구: 같은 폴더의 `setup.py` (결정적 CLI). 경로 = `${CLAUDE_PLUGIN_ROOT}/skills/setup-wizard/setup.py`.

## 진행 순서 (이 순서를 따른다)

### 0. 거버넌스 동의 (건너뛰지 말 것 — 유일한 예외: 0.2 의 설치기 동의 기록)
먼저 `${CLAUDE_PLUGIN_ROOT}/../GOVERNANCE.md`(또는 저장소 루트 `GOVERNANCE.md`)의 **0·2·3·6장 요약**을 한국어로 보여주고, 사용자에게 다음을 명시적으로 확인받는다:
- 개인 PC·비업무·비민감 데이터 전용, **환자정보·PII·기밀 입력 금지**
- bypass·원격·외부 송출을 이해
- 끄는 법/지우는 법을 알고, 최종 책임이 본인에게 있음

동의하지 않으면 **설치를 중단**한다.

### 0.2 설치기 결정 읽기 (v0.1.8+ — 이미 답한 것은 재질문 스킵)

Windows 설치기(v0.1.8+)는 설치 말미 온보딩 폼의 결정을 상태 파일로 남긴다. 먼저 확인:
```
cat ~/.claude/cc-companion/installer-onboarding.json 2>/dev/null
```
**파일이 없으면**(구 이미지·무인 설치·폼 건너뜀·staged 경로) 이 단계를 무시하고 아래 절차 전체를
그대로 진행한다. **파일이 있고 `schema_version`==1, `source`=="installer"** 면 — 설치기 폼에서 이미
묻고 답한 것을 재질문하지 않는다:

- `governance_ack`=true 일 때**만** **0단계 재동의 스킵**(요지 1줄 + 아래 "끄기/긴급정지" 요약만 안내).
  `governance_ack` 가 true 가 아니면 state 를 신뢰하지 말고 **0단계부터 기존대로 진행**한다.
- **§3.5/3.6 스킵**하고 현 상태만 한 줄 보고. 단 **불일치 감지 시 해당 단계 재안내 — 아래 순서로
  검사한다**(마커=동의 게이트가 상위 개념이므로 먼저):
  1. `memory_egress`=true 인데 egress 마커(`setup_complete`) 부재 → **3.5 재안내**(설치기 부분 실패). 마커와 키가 둘 다 없어도 3.5 부터.
  2. (마커는 있는데) `memory_egress`=true 이고 추출 키 파일 부재(doctor 출력으로 확인) → **3.6 재안내**(설치기 키 등록 실패·백업 복원 직후 케이스 — 키는 백업에 포함되지 않는다).
- **§3.7 은 state 만 보고 스킵하지 않는다** — 뷰어는 v0.1.9 필수설치화라 정상값은 "installed"/"failed"("skipped" 는 구 설치·백업 잔재). `dashboard_viewer`=="installed" 여도 실물 확인(`/usr/local/bin/cockpit-dashboard status` 가 NOT_INSTALLED 가 아님)을 통과할 때만 스킵(백업 복원 후 state 만 살아 있는 오판 방지). 실물 부재/"failed" → 재설치·재시도 제안 / "skipped"(구 잔재) → "원하면 이 단계만 다시 실행 가능" 1줄.
- 사용자가 설정 **변경**을 원하면 state 와 무관하게 해당 단계만 재실행한다(재설정 경로). 이 state 파일은 "설치기가 물었고 사용자가 답했다"의 기록일 뿐 — 현재 동작의 단일 출처는 항상 실물(egress 마커·키 파일·뷰어 설치 여부)이다.

> ⚠ `setup_complete` 는 **egress 동의 게이트**다 — 온보딩 완료/재질문 스킵 판정에 이 파일을 읽지
> 말 것(재사용 금지). 스킵 판정 근거는 오직 `installer-onboarding.json`.

### 1. 점검 (doctor)
```
python3 "${CLAUDE_PLUGIN_ROOT}/skills/setup-wizard/setup.py" doctor
```
출력의 ✗(치명)·⚠(주의)를 사용자에게 한국어로 풀어 설명한다. 특히:
- `~/.claude/CLAUDE.md` 가 이미 있고 템플릿과 다르면: **기본은 보존(덮어쓰지 않음)**이라 install 이 거부된다. 기존 운영 규칙을 잃지 않으려면 그대로 두고 템플릿 내용을 수동 병합하거나, 정말 교체하려면 `--replace-claude-md`(교체 전 자동 백업 → rollback 복원 가능)를 함께 전달한다.
- 메모리 **자동 추출** 키가 없으면 자동추출만 비활성(나머지는 정상)임을 알린다. 등록을 원하면 **아래 3.6 단계**(`set-extraction-key`)로 안내한다. ⚠️ `ANTHROPIC_API_KEY` 를 셸에 직접 export 해 두면 claude.ai **Remote Control 이 거부**되므로(키 설정 시 비활성), 추출 키는 `ANTHROPIC_API_KEY_FOR_SCRIPTS` 또는 키 파일(3.6)로 두는 것을 권장한다.

### 1.5 이전 백업 복원 (재설치라면 — 멈춰 질문)

doctor 가 "기억 저장소에 사용자 기억이 없습니다(비었거나 초기 템플릿뿐) + 이전 백업 발견: …"을 표시하면(= 재설치 직후 + 복원할 백업이 실제로 있음 — fresh 이미지는 초기 템플릿을 미리 담고 있으므로 '템플릿뿐'도 재설치 직후에 해당하고, 백업이 하나도 없으면 이 줄 자체가 안 나온다), 사용자에게 **"이전 설치의 기억·설정 백업을 발견했습니다. 복원할까요?"** 를 묻는다. 이 줄이 없으면(신규 설치·백업 없음·이미 기억 사용 중) 건너뛴다.

```
python3 "${CLAUDE_PLUGIN_ROOT}/hooks/memory/backup.py" --scan            # 백업 위치 탐색
python3 "${CLAUDE_PLUGIN_ROOT}/hooks/memory/backup.py" --restore         # 기본 dry-run: 무엇이 어디로 가는지 보고만
python3 "${CLAUDE_PLUGIN_ROOT}/hooks/memory/backup.py" --restore --apply # 사용자 확인 후 실제 복원
```

- 복원 대상 = 기억(cc-memory)·상태(cc-companion)·CLAUDE.md·(있으면) 대시보드 데이터. **settings.json 은 기본 제외**(새 이미지의 베이크 설정 보존 — 꼭 필요하면 `--include-settings`).
- 비파괴: 기존 데이터가 있으면 `<경로>.pre-restore-<시각>` 으로 통째 보존 후 복원한다(문제 시 이름을 되돌리면 원복).
- 백업 위치가 여러 곳이면 `--dir` 로, 특정 파일이면 `--file` 로 지정.
- 복원 후 아래 doctor 를 다시 돌려 기억 저장소가 채워졌는지 확인한다.

### 2. 미리보기 (dry-run)
```
python3 ".../setup.py" install            # 기본이 dry-run
```
바뀔 작업 목록을 보여주고 사용자 확인을 받는다.

### 3. bypass 결정 (위험 — 멈춰 질문)
"권한 확인 생략(bypass)을 켤까요?"를 **명시적으로** 묻는다. 장점(매번 확인 팝업 없음)과 위험(파괴 명령 자동 실행 가능 — deny-list 가 backstop)을 균형있게 설명한다. 사용자가 켜기로 하면 다음 단계에 `--enable-bypass` 추가.
> **참고**: cockpit WSL 골든 이미지(동료 배포본)는 **bypass 가 이미 settings.json 에 사전적용**돼 있다(2026-06-26 결정·"동의 한 화면" 외 기술세팅 사전화). 이 경우 본 단계는 "이미 켜져 있음"을 알리고, 끄려면 settings.json 의 `permissions.defaultMode` 를 제거/`ask` 로 바꾸도록 안내한다. 플러그인만 따로 설치한 비-이미지 환경에서는 위처럼 명시 질문한다.

### 3.5 기억 자동 추출 선택 — 옵션 1 / 옵션 2 (멈춰 질문)

기억 자동 추출 = 세션이 끝날 때마다 별도의 작은 AI(Haiku)가 방금 끝난 대화를 훑어 "기억할 가치가 있는 것"(선호·피드백·프로젝트 맥락) 후보를 자동으로 쌓아 두고, 다음 세션이 이를 반영하는 기능이다. **아래 두 옵션을 사용자에게 그대로 제시하고 고르게 한다.** 어느 쪽을 골라도 정상 경로이고, 대답이 없거나 망설이면 기본은 옵션 2(나중에 언제든 이 단계만 다시 실행 가능).

**옵션 1. API 키 입력하고 기억능력 보강하기**
- **효과**: 대화 중 직접 기록하는 수동 기억에 더해, 세션 종료 시 대화를 자동 분석해 기억 후보를 쌓는다. 다음 세션 시작 때 "pending N건" 알림으로 반영된다 — 오래 쓸수록 기억 품질 격차가 커지는 기능.
- **조건**: ① 본인 Anthropic API 키(Claude 구독과 **별개** 과금) ② 세션 종료 후 대화 내용이 Anthropic API 로 **외부 송신**되는 것에 동의(GOVERNANCE §3 — 의료/PII 맥락에선 신중히).
- **예상 비용**(Haiku 단가 입력 $1/출력 $5 per 백만 토큰 · 추출은 입력 15,000자/출력 2,000토큰 상한이 코드에 고정): **세션 1회 최대 약 50원, 보통 10원 안팎.** 하루 5세션 기준 한 달 통상 1천~2천 원 수준. 콘솔에서 **사용량 한도(spend limit)** 를 걸면 상한이 보장된다.
- 선택 시: 4단계 install 에 `--enable-memory-egress` 를 추가하고, **아래 3.6 절차로 키를 등록**한다.

**옵션 2. API 키 입력 없이 사용하기**
- **효과**: 기억 시스템은 전부 정상 동작한다(세션 시작 상태 주입·수동 기억·인덱스 자동 재생성·백업). "세션 끝나고 자동으로 훑어주는" 부분만 꺼진다 — 기억은 대화 중 직접 기록한 것만 쌓인다.
- **조건·비용 없음.** 이 기능(자동 추출) 목적의 **추가** 외부 송신이 없다는 뜻이다 — 대화 자체가 Anthropic 의 Claude 서비스로 처리되는 것은 Claude Code 의 기본 동작이며 이 선택과 무관(GOVERNANCE §3).
- 선택 시: `--enable-memory-egress` 를 붙이지 않고 3.6 을 건너뛴다. 나중에 마음이 바뀌면 이 단계(3.5~3.6)만 다시 실행하면 된다.

> 내부 구조 참고: egress 동의(`--enable-memory-egress`)와 키 등록(`set-extraction-key`)은 별개 장치다(bypass 동의가 egress 를 자동으로 켜지 않는 것과 같은 분리 원칙 — v0.1.1). 옵션 1 = 둘 다, 옵션 2 = 둘 다 없음. 한쪽만 있으면 자동추출은 안전하게 no-op 이다.

### 3.6 API 키 등록 (옵션 1 을 골랐다면)

egress 를 켜도 **개인 Anthropic API 키가 없으면 자동추출은 동작하지 않는다**(no-op — 정직 고지: 이 경우 기억은 **수동으로만** 쌓인다). 자동추출을 실제로 쓰려면 키를 등록한다.

**⚠️ 키 원문은 이 대화(Claude 채팅·세션 로그)에 절대 붙여넣지 않는다.** 붙여넣으면 트랜스크립트에 시크릿이 남는다. 대신 아래 둘 중 하나로 **사용자가 직접** 등록한다:

- **(권장) 사용자가 WSL 터미널에서 직접 실행** — 키를 붙여넣으라고 나오고 **화면에 표시되지 않는다**(getpass):
  ```
  python3 "${CLAUDE_PLUGIN_ROOT}/skills/setup-wizard/setup.py" set-extraction-key
  ```
- **이미 셸에 export 해 둔 경우** — 값을 노출하지 않고 파일로 옮긴다(마법사가 대신 실행해도 안전, 키 원문이 인자·대화에 안 남음):
  ```
  python3 "${CLAUDE_PLUGIN_ROOT}/skills/setup-wizard/setup.py" set-extraction-key --from-env
  ```

키는 `~/.config/cockpit/extraction-key` 에 **0600(본인만 읽기)** 로 저장된다. 해제는 `set-extraction-key --remove`(단, `ANTHROPIC_API_KEY`류 env 를 직접 export 해 뒀다면 그 env 도 unset 해야 자동추출이 완전히 꺼진다 — `--remove` 가 env 잔존 시 경고한다).

**발급 방법(비개발자용)**: ① `console.anthropic.com` 로그인/가입 → ② 좌측 **API Keys** → **Create Key** → ③ 생성된 키 복사(**한 번만 표시**됨) → ④ **Billing** 에 결제수단/크레딧 등록(키는 결제수단이 있어야 동작).

**⚠️ 과금·보안 주의**:
- API 키 사용량은 **Claude Max/Pro 정액 구독과 별개**로 **쓴 만큼 과금**(pay-per-token)된다. 예상 규모는 3.5 옵션 1 표기 그대로(세션 1회 최대 약 50원·보통 10원 안팎). 그래도 콘솔에서 **사용량 한도(spend limit)** 를 걸어두길 권장.
- 키 파일은 0600 로 저장되므로 공유 PC 라도 본인 계정 밖에선 안 보인다. 키가 노출됐다고 판단되면 콘솔에서 **회전(revoke→재발급)** 후 `set-extraction-key` 재등록.
- `ANTHROPIC_API_KEY`(순정 이름)를 셸에 export 하면 claude.ai Remote Control 이 거부되므로, **이 키 파일 방식** 또는 `ANTHROPIC_API_KEY_FOR_SCRIPTS` 를 쓴다.

### 3.7 대시보드(세션 열람) 확인·재시도 (필수 부속 — 설치기가 기본 설치)
세션 대시보드 뷰어는 **설치기(Install-Cockpit.ps1)가 기본 부속으로 자동 설치**한다(v0.1.9 필수설치화·모든 설치 경로). 이 스텝은 **옵트인 질문이 아니라 설치 상태 확인·재시도**다:
- **먼저 실물 확인** — `doctor`(5단계)의 뷰어 항목이 "설치됨"이면 안내만 하고 넘어간다. **미설치/설치 실패**(오프라인·프록시·GitHub 차단으로 설치기 클론이 실패)면 재설치를 제안한다.
- 이것은 **로컬 민감 로그 뷰어**다 — 세션 로그(프롬프트·파일 경로·업무 내용)가 브라우저로 열린다. 설치 자체는 기본이지만, **켜기(아이콘 더블클릭)는 공유 PC·회사 보안정책 기기·화면공유 중이면 하지 말 것**(`plugin/dashboard/README.md` 필독).
- **자동시작·포트 개방은 없다**(설치≠기동). 켜는 것은 항상 명시적: Windows **바탕화면의 'Cockpit Dashboard' 아이콘** 더블클릭(설치기가 만들어 둠 — 열면 켜지고 창 닫으면 꺼짐; 아이콘이 없으면 릴리스의 `Cockpit-Dashboard.cmd` 를 받아 더블클릭) 또는 WSL 안 `/usr/local/bin/cockpit-dashboard start`.
- 설치·재설치에 네트워크가 필요하다(공개 뷰어를 핀 커밋으로 클론).

미설치/설치 실패면 재시도 실행:
```
bash "${CLAUDE_PLUGIN_ROOT}/dashboard/install-viewer.sh"
```
기본값 = 호스트 본인 localhost 열람 전용(bind 127.0.0.1·allow_cidr 127.0.0.1/32). 다른 기기(폰 등) 열람은 고급 사용 — README 의 "자가검증(필수)"을 통과한 뒤에만 직접 변경하도록 안내한다. 이미 설치돼 있으면 재실행은 멱등(핀 재확인)이라 건너뛰어도 된다.

### 4. 설치 (apply)
```
python3 ".../setup.py" install --apply [--i-accept-governance] [--enable-bypass] [--enable-memory-egress] [--replace-claude-md]
```
`--i-accept-governance` 는 GOVERNANCE(특히 §3 외부 송출·§8 동의)를 읽고 동의했다는 신호로, **위험 기능 플래그의 공통 전제**다. 동의만으로는 아무 위험 기능도 켜지지 않으며, **각 기능마다 별도 플래그가 추가로 필요**하다: ① `--enable-bypass`(권한 확인 생략) ② `--enable-memory-egress`(메모리 자동추출의 외부 송신 — 없으면 세션 본문이 외부로 나가지 않음, 키가 있어도 no-op). **0단계에서 사용자가 명시적으로 동의했을 때만** `--i-accept-governance` 를 전달하고, bypass·egress 는 각각 3·3.5단계 결정에 따라 해당 플래그를 붙인다. 기존 CLAUDE.md 가 다르면 `--replace-claude-md` 없이는 보존(거부)된다.
완료 후: ① `~/.claude/CLAUDE.md` 의 `{{...}}` 플레이스홀더(언어·역할 등)를 사용자와 함께 채운다. ② 메모리 저장소(`~/.claude/cc-memory`)는 빈 인덱스와 `PROJECT_STATUS.md` 로 시작한다 — 예시 기억은 넣지 않으므로 따로 정리할 게 없다. 기억 작성 형식이 궁금하면 `${CLAUDE_PLUGIN_ROOT}/memory-template/examples/`(참고 견본)를 안내한다. ③ 새 세션을 시작하면 세션 시작 훅이 PROJECT_STATUS 를 주입하고, 종료 시 기억 후보가 쌓임을 설명한다.

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
- **bypass 끄기**: `setup.py rollback` 또는 settings.json 의 `permissions.defaultMode` 를 제거/`ask` 로
- **메모리 외부송신(egress) 끄기**: `rm ~/.claude/cc-companion/setup_complete` (마커 삭제 → 자동추출 즉시 no-op). `setup.py rollback` 도 마커를 제거한다.
- **원격조종 끄기**: `claude /config` 에서 "Enable Remote Control for all sessions" → `false` (또는 settings.json `remoteControlAtStartup: false`)
- **대시보드 끄기**: 앱 창 닫기(자동 종료) · 수동은 `/usr/local/bin/cockpit-dashboard stop` 또는 `bash ${CLAUDE_PLUGIN_ROOT}/dashboard/disable-remote.sh --apply`
- **긴급정지(즉시 자동 진행 중단)**: `touch ~/.claude/CC_KILL_SWITCH` → 모든 Bash·쓰기 도구가 차단됨. 재개: `rm ~/.claude/CC_KILL_SWITCH`
- **감사 로그 확인**: `~/.claude/cc-companion/audit.log` (차단·강행 기록)

## 원칙
- 절대 사용자 데이터(기존 메모리·CLAUDE.md)를 백업 없이 덮어쓰지 않는다.
- 위험·비가역 단계(bypass)는 한 번에 하나씩, 동의를 받고 진행한다.
- 모든 셸 출력은 한국어로 풀어 설명한다(원문 로그는 그대로 인용 가능).
