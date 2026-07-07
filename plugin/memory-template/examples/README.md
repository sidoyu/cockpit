# 예시 메모리 (참고본 — 라이브 메모리에 적재되지 않음)

이 폴더의 `example_*.md` 는 **기억 파일의 작성 형식을 보여주는 참고 견본**입니다.

- 설치(`setup.py install`)는 이 폴더를 **복사하지 않습니다.** 새로 설치한 메모리 저장소
  (`~/.claude/cc-memory`)는 빈 인덱스(`MEMORY.md`)와 `PROJECT_STATUS.md` 로만 시작하므로,
  나중에 예시를 따로 정리할 필요가 없습니다.
- 기억을 어떻게 쓰는지 형식이 궁금할 때 이 견본을 열어 보세요. 규칙은 `~/.claude/CLAUDE.md`
  의 메모리 섹션에도 설명돼 있습니다.

## 한눈에 보는 규칙

- **한 파일 = 한 사실.** 파일마다 `name` · `description` · `metadata.type` 프론트매터를 둡니다.
- 인덱스(`MEMORY.md`)는 각 파일의 `description` 으로 **자동 생성**됩니다(직접 편집하지 않음).
- `type` 이 `feedback` · `project` 인 메모리는 본문에 **Why / How to apply** 를 함께 적습니다.
- 관련 메모리는 `[[다른-파일-name]]` 처럼 이중 대괄호로 링크합니다(아직 없는 이름이어도 됨).

| 파일 | type | 무엇을 보여주나 |
| --- | --- | --- |
| `example_user_profile.md` | user | 사용자 자신(역할·기술 수준·선호)을 한 줄로 요약하는 형식 |
| `example_feedback_concise.md` | feedback | 작업 방식 피드백을 Why/How 와 함께 적는 형식 |
