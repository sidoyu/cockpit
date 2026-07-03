#!/usr/bin/env python3
"""
chain_nudge.py — UserPromptSubmit hook.

긴 세션에서 컨텍스트가 비대해지면(품질 저하·토큰 비효율 구간), 사용자가 요청하지 않아도
Claude가 "체인 세션 분할 + 복붙용 NEXT-SESSION 프롬프트"를 선제 제안하도록
additionalContext 를 결정적으로 주입한다.

설계 원칙:
  - 정밀 계기판이 아니라 "가벼운 fail-open 넛지". 어떤 예외도 조용히 통과(exit 0, no output).
  - 매 프롬프트 transcript 전체 파싱 금지 → tail-read 로 최신 usage 1건만.
  - 3단계 임계(균형 기본값): 관찰 / 제안 / 강함.
  - 세션별 debounce 로 잔소리·멀티세션 중복 방지(세션마다 자기 state 파일만 read/write).
  - 상태(state)는 플러그인 캐시(읽기전용·업데이트마다 교체)가 아니라 CC_STATE_DIR 밑에 둔다.

메시지는 자기완결적이다(고정 필드·저장 위치·상시 의무를 본문에 담음). 별도 메모리/문서 의존 없음.
"""
import sys, os, json, time

# ── 튜닝 상수 (env 로 1회 override 가능; 영구 변경은 이 값 수정) ──────────────
# 모두 "현재 세션 누적 입력 토큰"(input + cache_read + cache_creation) 기준.
WINDOW   = int(os.environ.get("CHAIN_WINDOW",   1_000_000))  # 기본 컨텍스트 윈도우(이미지 핀 모델 기준)
OBSERVE  = int(os.environ.get("CHAIN_OBSERVE",    150_000))  # 이하: 아무것도 안 함
PROPOSE  = int(os.environ.get("CHAIN_PROPOSE",    250_000))  # 이상: 제안 의무 발동
STRONG   = int(os.environ.get("CHAIN_STRONG",     600_000))  # 이상(또는 WINDOW의 STRONG_PCT): 강하게 제안
STRONG_PCT     = float(os.environ.get("CHAIN_STRONG_PCT", 0.70))
DEBOUNCE_TOKENS  = int(os.environ.get("CHAIN_DEBOUNCE_TOKENS", 100_000))  # 같은 단계 재제안 최소 증가량
DEBOUNCE_SECONDS = int(os.environ.get("CHAIN_DEBOUNCE_SECONDS", 3600))    # 같은 단계 재제안 최소 간격(초)
TAIL_BYTES = 3_000_000  # transcript 끝에서 읽을 양(최신 usage 포함 보장용)

# ── 상태 위치: 플러그인 밖의 영속 위치(CC_STATE_DIR). 기본 단일 출처는 cc_paths ──
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "memory"))
try:
    import cc_paths  # type: ignore
    _STATE_BASE = cc_paths.STATE_DIR
except Exception:
    _STATE_BASE = os.path.realpath(os.path.expanduser(
        os.environ.get("CC_STATE_DIR") or "~/.claude/cc-companion"))
STATE_DIR = os.path.join(_STATE_BASE, "chain-session")


def _fail_open():
    """어떤 문제든 조용히 통과 — 사용자 흐름을 절대 막지 않는다."""
    sys.exit(0)


def read_last_usage_tokens(transcript_path):
    """transcript .jsonl 끝부분만 읽어 최신 message.usage 의 컨텍스트 토큰 합을 추정."""
    try:
        size = os.path.getsize(transcript_path)
    except OSError:
        return None
    start = max(0, size - TAIL_BYTES)
    try:
        with open(transcript_path, "rb") as f:
            f.seek(start)
            data = f.read()
    except OSError:
        return None
    text = data.decode("utf-8", "ignore")
    lines = text.split("\n")
    if start > 0 and lines:
        lines = lines[1:]  # 잘린 첫 줄 버림
    last = None
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            o = json.loads(line)
        except Exception:
            continue
        if not isinstance(o, dict):
            continue
        u = None
        m = o.get("message")
        if isinstance(m, dict) and isinstance(m.get("usage"), dict):
            u = m["usage"]
        elif isinstance(o.get("usage"), dict):
            u = o["usage"]
        if u:
            last = u
    if not last:
        return None
    return sum(int(last.get(k, 0) or 0) for k in
               ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"))


def tier_for(tokens):
    if tokens >= STRONG or tokens >= WINDOW * STRONG_PCT:
        return 3
    if tokens >= PROPOSE:
        return 2
    if tokens >= OBSERVE:
        return 1
    return 0


def load_state(session_id):
    path = os.path.join(STATE_DIR, f"{session_id}.json")
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return {"last_tier": 0, "last_tokens": 0, "last_ts": 0}


def save_state(session_id, tier, tokens, ts):
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        path = os.path.join(STATE_DIR, f"{session_id}.json")
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"last_tier": tier, "last_tokens": tokens, "last_ts": ts}, f)
        os.replace(tmp, path)  # atomic
    except Exception:
        pass  # 상태 저장 실패도 fail-open


FIELDS = ("현재 목표 / 완료 / 미완료 / 결정사항 / 버린 대안 / 열린 질문 / "
          "수정된 파일 / 검증 결과 / 새 세션 첫 행동")


# 핸드오프 저장 위치 안내(repo / 비-repo 양쪽). debounce 가 침묵해도 의무가 유지되도록
# "상시 의무(standing obligation)"로 프레이밍 — 이 트리거를 한 번 보면 세션 끝까지 적용.
_SAVE = ("핸드오프 파일에도 저장(repo면 docs/handoffs/NEXT-SESSION-prompt.md; 아니면 그 작업의 "
         "핸드오프 디렉터리에 NEXT-SESSION-prompt.md)")
_STANDING = ("⚠ 이건 점-시점 알림이 아니라 **상시 의무**다: 이 트리거를 본 이후, 이 세션을 "
             "마무리·요약·종료하거나 사용자가 '끝/다음 세션/정리' 신호를 주는 **모든 응답**에서, "
             "요청이 없어도 **반드시 복붙용 NEXT-SESSION 프롬프트(코드블록)를 먼저 제시**한다. "
             "마무리 발화에서 누락 = 규칙 위반. (debounce 로 이 알림이 다시 안 떠도 의무는 유지된다.)")


def message_for(tier, tokens):
    k = round(tokens / 1000)
    if tier == 3:
        return (f"[chain-session 자동 트리거·강함] 현재 세션 누적 입력 ≈{k}K 토큰 — "
                f"품질 저하·자동 컴팩션 임박 구간. **이번 응답에서** 현재 작업을 안전 지점"
                f"(커밋·권위기록 갱신)에서 마무리하고, 즉시 체인 세션 분할 제안 + NEXT-SESSION "
                f"프롬프트(코드블록)를 제시할 것. 더 미루지 말 것. {_STANDING} "
                f"프롬프트 고정 필드: {FIELDS}. {_SAVE}.")
    # tier 2
    return (f"[chain-session 자동 트리거] 현재 세션 누적 입력 ≈{k}K 토큰 — 컨텍스트가 길어지는 중. "
            f"작업 중간이면 지금 끊지 말고 자연스러운 경계까지 진행하되, {_STANDING} "
            f"프롬프트 고정 필드: {FIELDS}. {_SAVE}.")


def main():
    try:
        raw = sys.stdin.read()
        payload = json.loads(raw) if raw.strip() else {}
    except Exception:
        _fail_open()
    transcript = payload.get("transcript_path")
    session_id = payload.get("session_id")
    if not transcript or not session_id:
        _fail_open()

    tokens = read_last_usage_tokens(transcript)
    if tokens is None:
        _fail_open()

    tier = tier_for(tokens)
    if tier < 2:
        _fail_open()  # 관찰 단계 이하는 사용자向 주입 없음

    st = load_state(session_id)
    now = int(time.time())
    last_tier = int(st.get("last_tier", 0) or 0)
    last_tokens = int(st.get("last_tokens", 0) or 0)
    last_ts = int(st.get("last_ts", 0) or 0)

    escalating = tier > last_tier
    grew = (tokens - last_tokens) >= DEBOUNCE_TOKENS
    aged = (now - last_ts) >= DEBOUNCE_SECONDS
    if not (escalating or grew or aged):
        _fail_open()  # debounce: 같은 단계에서 최근 이미 제안함

    save_state(session_id, tier, tokens, now)
    out = {
        "hookSpecificOutput": {
            "hookEventName": "UserPromptSubmit",
            "additionalContext": message_for(tier, tokens),
        },
        "suppressOutput": True,
    }
    sys.stdout.write(json.dumps(out, ensure_ascii=False))
    sys.exit(0)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception:
        _fail_open()
