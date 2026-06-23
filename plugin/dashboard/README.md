# 원격 대시보드 — 선택 기능 (개인 VPN 내부 한정)

Claude Code **세션 로그 대시보드**(목록·검색·세션 시작/재개)를 호스트 PC에서 띄우고,
**같은 개인 VPN(예: Tailscale)에 묶인 다른 기기**(휴대폰·노트북)의 브라우저에서 보거나
세션을 조종하는 **선택 기능**이다.

> ⚠️ **이 패키지에서 가장 위험한 기능**이다. 원격 조종 = 다른 기기에서 호스트의 Claude Code를
> 움직인다는 뜻이고, bypass 가 켜진 환경에선 더더욱 신중해야 한다. GOVERNANCE.md 0·3·4·6장 필독.
> **개인 PC·비업무·비민감 데이터 전용**(2장). 기본값은 **비활성**이며, 켜는 것은 사용자 책임이다.

## 구성 요소(이 디렉터리)

| 파일 | 역할 |
|------|------|
| `config.example.sh` | 사용자 설정(포트·바인드·타임존·healthcheck·경로). 복사해서 채운다. |
| `dashboard-run.sh` | 서버 기동 래퍼 — 설정(env)을 적재한 뒤 뷰어 서버를 exec(launchd 가 설정을 받게). |
| `com.cockpit.dashboard.plist.template` | (macOS) launchd 자동시작 템플릿(`dashboard-run.sh` 실행). `{{...}}` 치환. |
| `cron-sweep.template.sh` | 로그→HTML 주기 변환 + (선택) healthcheck ping. 경로·키 파라미터화·이식성 stat. |
| `disable-remote.sh` | **원격 비활성화** — 포트 LISTEN 서버 중지(cmdline 검증)·launchd 영구 disable·접속 차단 안내(멱등·dry-run 기본). |

## 뷰어 본체는 어디에?

세션 로그를 HTML 로 변환하고 서빙하는 **뷰어 본체(서버·변환기·PWA)는 이 패키지에 포함하지 않는다.**
별도의 공개 제네릭 프로젝트(**claude-session-dashboard**, 사용자가 직접 가져옴)를 뷰어로 쓰고,
이 디렉터리는 그 위에 얹는 **원격 접속 거버넌스·설정·비활성화 레이어**만 제공한다.

- **이유(기술부채 회피)**: 뷰어 본체는 이미 독립적으로 유지·배포되는 큰 코드베이스다. 사본을 여기에
  또 두면 세 곳을 동기화해야 하는 부채가 생긴다. 단일 출처(공개 뷰어 repo)를 참조한다.
- 셋업: 공개 뷰어를 `CC_DASH_HOME`(기본 `~/claude-logs`)에 설치 → 이 디렉터리의 설정/템플릿으로
  포트·바인드·자동시작·healthcheck 를 입힌다. (설치 마법사 연동은 후속.)

## 접근 통제 — "개인 VPN 내부 한정"이 어떻게 동작하나

권장 구성에서 뷰어 서버는 **요청자 IP 를 검사해 다음만 허용하고 나머지는 403 으로 거부**한다:

- **localhost**(127.0.0.0/8, ::1)
- **개인 VPN 대역**(기본 Tailscale CGNAT `100.64.0.0/10`; 다른 VPN 이면 그 대역으로 교체)

즉 집/회사 LAN(192.168.x·10.x)에서의 직접 접속도 차단된다. 개인 기기의 특정 IP 를 코드에 박지 않고
**대역 기준**이라 이 패키지에는 개인 IP 가 없다.

> ⚠️ **`0.0.0.0` 바인딩의 진실**: 서버는 보통 `0.0.0.0:PORT`(모든 인터페이스)로 바인딩한다
> (특정 IP 바인딩의 VPN-기동 의존성 함정 회피). 이는 **공개·LAN 인터페이스에서도 LISTEN 한다는 뜻**이다.
> 외부로부터의 실제 보호는 위 **애플리케이션 allowlist 와 "포트를 공개로 노출하지 않는 것"** 두 가지뿐이다.
> - **절대 금지**: 라우터 포트포워딩, Tailscale **Funnel/Serve** 공개, 클라우드 방화벽 인바운드 개방.
> - allowlist 가 (오설치·뷰어 버전 차이로) 동작하지 않으면 그 즉시 **인증 없는 공개 HTTP** 가 된다.
> - HTTPS 미적용은 트래픽이 VPN(WireGuard 등)으로 암호화된다는 전제에 기댄다 — VPN 밖으로 노출하지 말 것.

> ⚠️ **이 allowlist 는 뷰어(참조하는 공개 repo)가 구현·제공하는 속성**이며, 이 패키지가 강제하지 못한다.
> 따라서 **검증된(allowlist 를 갖춘) 뷰어 버전을 고정해서** 쓰고, 업데이트 시 접근 통제가 유지되는지
> 직접 확인한다(아래 "뷰어 버전 고정" 참조). `cockpit-doctor` 는 포트 LISTEN 여부만 탐지할 뿐,
> allowlist 동작 자체를 보장하지 않는다.

> 🛑 **켜기 전 필수 — 설치한 뷰어가 allowlist 를 실제로 갖췄는지 자가검증.**
> IP allowlist(localhost+VPN 대역만 허용)·CSRF 가드는 공개 뷰어 `claude-session-dashboard`
> **`d4482d5`(2026-06-23) 이상에 반영**돼 있다. 그 이전 커밋을 고정했거나 오설치된 경우엔 없을 수 있고,
> allowlist 없는 뷰어로 원격을 켜면 그 즉시 **인증 없는 공개 HTTP** 가 된다. 따라서 버전과 무관하게
> **아래 자가검증으로 직접 확인하기 전에는 원격을 켜지 말 것.**

### 뷰어 버전 고정(권장)

`reference-not-vendor` 구조라 접근 통제·동작은 외부 뷰어 구현에 의존한다. 부동(floating) 최신 대신
**known-good 커밋/태그를 고정**해 설치한다 — **`d4482d5`(2026-06-23, allowlist+CSRF 도입) 이상** 권장.
올릴 때마다 ① IP allowlist 동작 ② `CC_DASH_*` 설정 반영을 스모크 확인한다. (설치 마법사의 버전 핀·호환성 체크 연동은 후속.)

**자가검증(필수) — allowlist 가 실제로 동작하는가:**

1. 뷰어를 띄운다(아래 "켜는 법").
2. **같은 Wi-Fi/LAN 에 있지만 VPN(Tailscale 등)은 끈 기기**의 브라우저로
   `http://<호스트의 LAN IP>:PORT/` 에 접속한다. (이 기기는 호스트에 **네트워크적으로 도달은 하되 VPN 대역이
   아니므로**, allowlist 가 있으면 거부되어야 한다 — 이것이 allowlist 를 실제로 시험하는 구성이다.)
3. **명시적 `403 Forbidden` 으로 거부되면 정상**(allowlist 동작). **화면이 그대로 보이면 allowlist 가 없는
   것**이므로 즉시 `disable-remote.sh --apply` 로 끄고, allowlist 를 갖춘 뷰어 버전으로 교체할 때까지
   원격을 켜지 않는다.
4. (보조) **VPN 에 접속한 기기**에서 `http://<호스트 VPN IP>:PORT/` 가 정상으로 열리는지도 확인한다.

> ⚠️ **접속 시간초과·연결거부·"페이지를 찾을 수 없음" 은 검증이 아니다.** 그것은 NAT·라우팅·방화벽 때문일
> 수 있어 allowlist 동작을 증명하지 못한다("안 열리니 안전"으로 오판 금지). **반드시 같은 LAN 의 LAN IP 로
> 접속해 `403` 을 직접 확인**해야 한다. 그래서 ②는 *LTE 만 켠 외부 기기*가 아니라 *같은 LAN·VPN 끈 기기*다.

> 코드로도 확인할 수 있다: 설치한 뷰어 소스에 `ipaddress`·VPN 대역(`100.64.0.0/10` 등)·요청자 IP 검사·`403`
> 처리 코드가 있는지 직접 본다. 없으면 allowlist 미구현으로 본다.

## 켜는 법(개요)

1. **검증된(allowlist 보유) 뷰어 버전을 고정**해 `CC_DASH_HOME` 에 설치하고 동작 확인("뷰어 버전 고정" 참조).
2. `cp config.example.sh ~/.config/cockpit/dashboard.env` 후 값 채우기(포트·TZ·healthcheck 등). `chmod 600`.
3. (macOS) `com.cockpit.dashboard.plist.template` 의 `{{RUN_WRAPPER}}`=`dashboard-run.sh` 절대경로로 치환해
   `~/Library/LaunchAgents/` 에 두고 `launchctl bootstrap gui/$(id -u) <plist>`. `cron-sweep.template.sh` 치환 후 crontab 등록(선택).
4. VPN(Tailscale 등) 연결 + 다른 기기 브라우저에서 `http://<호스트 VPN IP>:PORT/` 접속.
   **포트를 라우터/Funnel/방화벽으로 공개 노출하지 말 것**(위 경고).

## 끄는 법 — `disable-remote.sh`

```sh
bash plugin/dashboard/disable-remote.sh          # 무엇을 멈출지 미리보기(dry-run)
bash plugin/dashboard/disable-remote.sh --apply  # 실제 비활성화
```
서버 프로세스 중지 + launchd 자동시작 해제 + 재접속 차단을 수행하고, VPN ACL 해제 안내를 출력한다.
재활성화 절차도 함께 안내한다. 자세히는 GOVERNANCE.md 6장.

## ⚠️ 플랫폼 메모

원격 **세션 시작/재개**(다른 기기에서 호스트의 Claude Code 를 띄우는 부분)는 호스트 OS 에 강하게
의존한다(macOS 는 Terminal 자동화). **Windows/WSL 용 세션 시작 메커니즘은 별도(Windows 빌드 단계)
에서 정의**한다. 그전까지 WSL 에서는 **읽기 전용 뷰어/검색**만 안전하게 동작한다고 본다.
