# PROJECT_STATUS — 현재 권위 상태

> **역할**: "이 프로젝트의 현재 결론·완료·금지" 사실을 한 줄씩 담는 단일 권위 계층.
> 세션 시작 시 `session_context.py` hook 이 이 파일을 **결정적으로 로드**한다(관련성 recall 에 안 맡김).
> 상세 본문·근거는 `project_*` 메모리로 링크만 한다(본문 중복 금지 = 단일 출처 유지).
>
> **기록 규율**: 결정·완료·보류·번복을 판정하는 시점에 즉시 이 파일을 갱신한다.
> - status: ✅완료 / 🔶진행 / ⏳보류 / 🔴라이브 / 🚫Not-planned / ↩️번복
> - 형식: `[프로젝트] STATUS **핵심 한 줄**(키워드 포함) (YYYY-MM-DD) → 메모리`
> - 한 프로젝트 = 현재 상태 한 줄. 완료(✅)도 한 줄로 남긴다(사후 회상용).
> - **크기 예산**: 총 SOFT 16,000B / HARD 24,000B + 줄당 SOFT 900B / HARD 1,400B.
>   SessionStart hook 이 매 세션 측정·경고만 한다(자동 절삭 안 함 = 사일런트 손실 방지).

## 현재 스냅샷

### 진행·보류·라이브 (능동 관심)
- (예시) [my-first-project] 🔶 **여기에 진행 중인 작업을 한 줄로** — 핵심 키워드 포함. (YYYY-MM-DD)

### 완료 (✅ 한 줄 회상용 — 상세는 링크)
- (아직 없음)

## Changelog

- (최근 5건만 유지. 초과 시 오래된 항목을 아카이브로 강등.)

<!-- PROJECT_STATUS_END · size budget guarded by session_context.py memory_budget_section -->
