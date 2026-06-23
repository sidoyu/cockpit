# 보조 검토(Codex) — 선택 기능

외부 LLM CLI(**OpenAI Codex**)를 "보이지 않는 보조 검토자"로 호출해 작업 품질을 높이는
**선택 기능**이다. 호출한 Claude 가 Codex 응답을 본인 결론과 비교해 **의미 있는 차이만**
사용자에게 전한다(결과 원문은 노출하지 않음).

> ⚠️ **이중 송출**: 이 기능을 켜면 검토 대상 맥락이 **Anthropic + OpenAI 두 곳**으로 전송된다.
> 자세한 고지는 [`GOVERNANCE.md`](../../GOVERNANCE.md) 3장. **민감정보·PII 입력 금지.**

기본값은 **비활성**이다. 아래 3가지를 갖췄을 때만 동작한다.

## 켜는 법 (3단계)

1. **OpenAI Codex CLI 설치 + 로그인** (구독 인증 권장 — API 종량 과금 회피)
   ```sh
   # 설치는 OpenAI 공식 안내를 따른다. 로그인:
   codex login
   codex login status   # exit 0 이면 인증 OK
   ```
2. **활성화 스위치 파일 생성**
   ```sh
   touch ~/.claude/codex_enabled      # 끄기: rm ~/.claude/codex_enabled
   ```
3. **(선택) 글로벌 브리프 작성** — 매 호출 앞에 결합되는 메타 컨텍스트
   ```sh
   cp plugin/codex/codex_global_brief.template.md ~/.codex/codex_global_brief.md
   # 편집해서 {{...}} 를 채운다. 없어도 동작함(작업 브리프만 전송).
   ```

## 동작 확인

```sh
bash plugin/codex/codex_call.sh --health
```
스위치·codex 바이너리·로그인 상태·디렉터리 권한을 자가 진단한다.

## 호출 방법

```sh
bash plugin/codex/codex_call.sh \
  --brief /tmp/brief.txt \
  --resp  /tmp/resp.txt \
  --trigger <type>
```
- 응답은 **`$RESP` 파일**에서 읽는다(stdout 아님). 호출 후 `echo exit=$?` 로 실행 확인.
- 본문엔 raw 응답을 인용하지 말고 **`$RESP.meta`**(자동 생성 안전 요약)를 읽는다.
- 트리거 타입: `4a`~`4h`/`manual` (CLAUDE.md §4.3 분류).

## 내장 안전 설계 (wrapper 자동 적용)

| 항목 | 동작 |
|------|------|
| 활성화 게이트 | 스위치 파일 없으면 어떤 호출도 거부(exit 3) |
| 인증 게이트 | `codex login status` exit code 단독 판정, 실패 시 스킵(exit 4) |
| **과금 차단** | 모든 호출에 `OPENAI_API_KEY=` 빈 접두 → 구독 인증만, API 종량 과금 원천 차단 |
| 읽기 전용 | `--sandbox read-only --skip-git-repo-check --ignore-user-config` |
| 시크릿 레닥션 | 송신 brief + 디스크 캡처물 양쪽에서 **API 키 패턴** 제거(정상 호출엔 no-op) |
| 타임아웃 | `CODEX_TIMEOUT_SEC`(기본 600s) 초과 시 우아한 스킵(부분응답 미노출·재시도 없음) |
| 결과 비노출 | 성공 시에만 `$RESP` 로 원자적 승격, 실패/타임아웃은 고정 스킵 문구만 |

## 경로·설정 (환경변수)

| 변수 | 기본값 | 용도 |
|------|--------|------|
| `CC_CODEX_ENABLED` | `~/.claude/codex_enabled` | 활성화 스위치 파일 |
| `CC_CODEX_GLOBAL_BRIEF` | `~/.codex/codex_global_brief.md` | 글로벌 브리프(선택) |
| `CC_STATE_DIR` | `~/.claude/cc-companion` | 로그·캡처물 루트(`/codex` 하위) |
| `CODEX_MODEL` | `gpt-5.5` | 모델(단일 출처 = wrapper 상단 상수) |
| `CODEX_REASONING_EFFORT` | `high` | 추론 강도 |
| `CODEX_TIMEOUT_SEC` | `600` | codex exec 타임아웃(초) |

> model/effort 의 정확한 현재 값은 항상 `codex_call.sh` 상단 상수를 본다(이 표는 참조용).

## 로그·민감도

- `$CC_STATE_DIR/codex/codex_calls.log` — 메타데이터 인덱스(원문 아님).
- `$CC_STATE_DIR/codex/codex_calls/<ts>/` — 호출별 brief·response 보관(권한 700/600).
  PII·시크릿이 섞일 수 있는 영역이다. 레닥션은 불완전하므로 **권한 제한 + 주기적 삭제**가 주 방어선.
  민감정보를 애초에 넣지 않는 것이 유일하게 확실한 보호다(GOVERNANCE 2.3).

> ⚠️ **레닥션의 한계**: 자동 레닥션은 흔한 **API 키 패턴**만 가린다. 실명·이메일·전화번호·내부 명칭
> 같은 **개인정보(PII)·식별자는 자동 제거되지 않는다**(외부 전송분 포함). 브리프·작업 내용에 민감정보를
> 넣지 않는 것이 유일하게 확실한 보호다.

## 끄기 / 제거

- 끄기: `rm ~/.claude/codex_enabled` (이후 어떤 트리거에도 OpenAI 로 호출 안 함).
- 로그 삭제: `rm -rf "$CC_STATE_DIR/codex"` (사용자 판단).
