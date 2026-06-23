---
description: cockpit 환경 상태·충돌 점검(읽기 전용, 변경 없음)
---

`${CLAUDE_PLUGIN_ROOT}/skills/setup-wizard/setup.py` 의 `doctor` 서브커맨드를 실행하세요:

```
python3 "${CLAUDE_PLUGIN_ROOT}/skills/setup-wizard/setup.py" doctor
```

출력의 ✓/⚠/✗ 항목을 한국어로 풀어 설명하고, 문제(✗)나 주의(⚠)가 있으면 해결 방법을 제안하세요. 설치·변경이 필요하면 `cockpit-setup` 마법사 스킬로 안내하세요. 이 명령 자체는 어떤 것도 변경하지 않습니다.
