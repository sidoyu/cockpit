#!/usr/bin/env python3
"""cmd-paren-gate.py — 배치(.cmd) 블록 내 비인용 괄호 검사(publish-gate §1e 가 호출).

무엇을 막나: `if ... (` 블록 *안*의 줄에 따옴표 밖 `)` 가 섞이면 cmd 가 블록을 조기
종결하고 ". was unexpected at this time." 로 배치 전체를 중단시킨다 — v0.1.6
Cockpit-Uninstall.cmd L73 `(if any).` 실사고(바로가기 삭제 블록 통째 미실행).
이 위험은 echo 뿐 아니라 **블록 안 rem 주석에도 적용**된다(cmd 블록 스캐너는 명령
식별 전에 구조 문자를 읽는다 — Codex 4f 발견: 수정 커밋의 주석이 같은 사고를 재현할
뻔했다). 그래서 블록 안에서는 주석도 검사한다(정책: 블록 안 텍스트는 전부 무괄호).

판정 모델(cmd 파서의 블록 수준 동작을 근사):
  - 큰따옴표는 만날 때마다 토글. cmd 에서 백슬래시는 이스케이프가 아님 — PowerShell
    -Command 안의 \" 도 cmd 눈에는 그냥 토글이다. 따옴표 안 괄호는 블록에 영향 없음.
  - 캐럿 이스케이프 ^( ^) 는 괄호로 세지 않음. `echo(` 관용구는 블록 열림이 아님.
  - `(` 가 블록을 여는 것은 **명령 위치**뿐 — 깊이 추적은 "비인용 시야가 `(` 로 끝나는
    줄 = 열림"만 상태로 삼는다(깊이 0 의 echo/rem 텍스트 괄호는 리터럴이라 무시).
  - 닫힘은 **엄격한 순수 닫힘**만: `)` 단독 / `) else` / `) else (` / `)` 뒤 리다이렉션.
    `) else echo ... )` 처럼 닫힘 뒤 명령이 붙고 그 안에 다시 `)` 가 있으면 위반으로 본다.
  - 블록 깊이 > 0 인 줄(주석 포함)이 순수 닫힘이 아닌데 따옴표 밖 `)` 를 포함하면 위반.
    텍스트 괄호가 짝을 이뤄도 위반(cmd 의 중첩 처리에 기대지 않는 보수 정책 — v0.1.6
    실사고가 정확히 짝괄호 케이스였다).

한계(정직 고지): 한 줄 안에서 열고 닫는 `if x (echo y)` 류는 상태로 추적하지 않는다(현
자산 코퍼스에 없음·필요해지면 확장). 종료코드: 0=깨끗 / 1=위반 / 2=사용 오류.
오탐 이력: 초기 프로토타입 3결함 — ①최상위 echo 의 `(` 가 깊이 오염(Dashboard L81→L82
오탐) ②"같은 줄 여는 괄호 면제"가 사고 패턴 자체를 면제 ③rem 통째 제외+느슨한 닫힘
판정(Codex 4f). 픽스처(scripts 옆 아님·publish-gate 실행 시 임시 생성 아님 — 본 저장소
테스트는 게이트 커밋 검증 세션 기록 참조)로 양방향 검증한다.
"""
import re
import sys

# 순수 닫힘: ")" / ") else" / ") else (" / ")" 뒤 리다이렉션 꼬리(예: ")>nul", ") 2>nul").
PURE_CLOSE = re.compile(r"^\)\s*(else\s*\(?\s*)?$|^\)\s*[0-9]?\s*[<>]\S*.*$")


def unquoted_view(line):
    """따옴표(토글 의미론) 안 내용을 공백으로 지운 시야(괄호 판정용)."""
    out = []
    in_q = False
    for ch in line:
        if ch == '"':
            in_q = not in_q
            out.append(" ")
        elif in_q:
            out.append(" ")
        else:
            out.append(ch)
    return "".join(out)


def scan(path):
    hits = []
    depth = 0
    with open(path, encoding="utf-8", errors="replace") as f:
        for ln, raw in enumerate(f, 1):
            line = raw.rstrip("\r\n")
            stripped = line.strip()
            body = stripped.lower()
            if body.startswith("@"):
                body = body[1:].lstrip()
            is_comment = body.startswith("rem") or body.startswith("::")
            is_label = stripped.startswith(":") and not body.startswith("::")
            if depth == 0 and (is_comment or is_label):
                continue  # 최상위 주석/라벨의 괄호는 리터럴(무해)
            vis = unquoted_view(line)
            vis = vis.replace("^(", "  ").replace("^)", "  ")
            vis = re.sub(r"echo\(", "     ", vis, flags=re.I)
            vstr = vis.strip()

            pure_close = bool(PURE_CLOSE.match(vstr))
            if depth > 0 and not pure_close and ")" in vstr:
                # 블록 안 줄(주석 포함)의 비인용 ')' — cmd 는 여기서 블록을 닫는다.
                hits.append((ln, stripped))
                continue  # 위반 줄의 괄호로 깊이를 더 오염시키지 않음

            if pure_close and depth > 0:
                depth -= 1
            if vstr.endswith("("):
                depth += 1
    return hits


def main(argv):
    if len(argv) < 2:
        print("usage: cmd-paren-gate.py <file.cmd> [...]", file=sys.stderr)
        return 2
    bad = 0
    for path in argv[1:]:
        for ln, txt in scan(path):
            print("  [paren] %s:%d: %s" % (path, ln, txt))
            bad = 1
    return bad


if __name__ == "__main__":
    sys.exit(main(sys.argv))
