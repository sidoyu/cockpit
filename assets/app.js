/* cc-companion 프런트도어 — 의존성 없는 바닐라 JS.
   기능: OS 감지 + 트랙 토글 · 복사 버튼 · 거버넌스 동의 게이팅 · 체크리스트 영속.
   안전: 외부 통신·추적 없음. 모든 상태는 localStorage(로컬)만 사용. */
(function () {
  "use strict";

  /* ── OS 감지 (Windows 우선) ───────────────────────────────── */
  function detectOS() {
    try {
      var uad = navigator.userAgentData;
      if (uad && uad.platform) {
        var p = uad.platform.toLowerCase();
        if (p.indexOf("win") !== -1) return "windows";
        if (p.indexOf("mac") !== -1) return "macos";
      }
    } catch (e) { /* userAgentData 미지원 → UA 폴백 */ }
    var ua = navigator.userAgent || "";
    if (/Windows|Win64|WOW64/i.test(ua)) return "windows";
    if (/Macintosh|Mac OS X/i.test(ua)) return "macos";
    return null; // 미상 → Windows 트랙을 기본 노출(권장 경로)
  }

  var SUPPORTED = ["windows", "macos"];
  function applyOS(os) {
    var sel = SUPPORTED.indexOf(os) !== -1 ? os : "windows";
    // 트랙 표시
    document.querySelectorAll(".track").forEach(function (el) {
      el.classList.toggle("show", el.classList.contains("os-" + sel));
    });
    // OS 전용 체크리스트 항목
    document.querySelectorAll(".os-only").forEach(function (el) {
      el.classList.toggle("show", el.classList.contains("os-" + sel));
    });
    // 탭 상태
    document.querySelectorAll(".os-tab").forEach(function (btn) {
      btn.setAttribute("aria-selected", String(btn.getAttribute("data-os") === sel));
    });
  }

  var detected = detectOS();
  applyOS(detected);
  var detEl = document.getElementById("os-detected");
  if (detEl) {
    detEl.textContent = detected
      ? "감지된 운영체제: " + (detected === "windows" ? "Windows" : "macOS") + " (필요하면 위에서 직접 바꾸세요)"
      : "운영체제를 감지하지 못해 Windows 경로를 표시합니다. 필요하면 위에서 직접 바꾸세요.";
  }
  document.querySelectorAll(".os-tab").forEach(function (btn) {
    btn.addEventListener("click", function () { applyOS(btn.getAttribute("data-os")); });
  });

  /* ── 거버넌스 동의 게이팅 (다운로드 버튼·복사 버튼 잠금/해제) ── */
  var consent = document.getElementById("consent-check");
  var hint = document.getElementById("consent-hint");
  var cta = document.getElementById("dl-cta");
  function syncGate() {
    var ok = consent && consent.checked;
    document.querySelectorAll(".code[data-gated]").forEach(function (el) {
      el.classList.toggle("locked", !ok);
    });
    if (cta) {
      // fail-closed: 동의 전에는 href 가 #downloads(표 폴백)이고, 동의 시에만 실제 URL 주입.
      cta.classList.toggle("locked", !ok);
      cta.setAttribute("aria-disabled", String(!ok));
      var real = cta.getAttribute("data-href");
      if (ok && real) cta.setAttribute("href", real);
      else cta.setAttribute("href", "#downloads");
    }
    if (hint) hint.textContent = ok
      ? "확인됨 — 아래 다운로드 버튼이 활성화되었습니다."
      : "체크하면 아래 다운로드 버튼이 활성화됩니다.";
  }
  if (consent) {
    // 동의는 매 방문 새로 받음(영속 안 함) — 경계 재확인 의도.
    consent.checked = false;
    consent.addEventListener("change", syncGate);
  }
  if (cta) {
    cta.addEventListener("click", function (e) {
      if (cta.classList.contains("locked")) {
        e.preventDefault(); // href 는 이미 #downloads 라 이중 방어
        if (hint) hint.textContent = "먼저 위 3가지 확인에 체크해 주세요.";
        var g = document.getElementById("governance");
        if (g && g.scrollIntoView) g.scrollIntoView({ behavior: "smooth", block: "start" });
      }
    });
  }
  syncGate();

  /* ── 복사 버튼 ────────────────────────────────────────────── */
  function copyText(text) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      return navigator.clipboard.writeText(text);
    }
    // 폴백: 숨김 textarea + execCommand
    return new Promise(function (resolve, reject) {
      try {
        var ta = document.createElement("textarea");
        ta.value = text; ta.style.position = "fixed"; ta.style.opacity = "0";
        document.body.appendChild(ta); ta.focus(); ta.select();
        var ok = document.execCommand("copy");
        document.body.removeChild(ta);
        ok ? resolve() : reject(new Error("copy failed"));
      } catch (e) { reject(e); }
    });
  }
  document.querySelectorAll(".code .copy").forEach(function (btn) {
    btn.addEventListener("click", function () {
      var box = btn.closest(".code");
      if (box && box.getAttribute("data-gated") !== null && box.classList.contains("locked")) {
        if (hint) { hint.textContent = "먼저 위의 경계 동의에 체크하세요."; }
        var g = document.getElementById("governance");
        if (g && g.scrollIntoView) g.scrollIntoView({ behavior: "smooth", block: "start" });
        return;
      }
      var code = box ? box.querySelector("code") : null;
      var text = code ? code.innerText : "";
      copyText(text).then(function () {
        var orig = btn.textContent;
        btn.textContent = "복사됨"; btn.classList.add("copied");
        setTimeout(function () { btn.textContent = orig; btn.classList.remove("copied"); }, 1400);
      }).catch(function () {
        btn.textContent = "복사 실패";
        setTimeout(function () { btn.textContent = "복사"; }, 1400);
      });
    });
  });

  /* ── 체크리스트 영속 (localStorage) ───────────────────────── */
  var STORE = "ccp.checklist.v1";
  var state = {};
  try { state = JSON.parse(localStorage.getItem(STORE) || "{}") || {}; } catch (e) { state = {}; }
  document.querySelectorAll("input[type=checkbox][data-persist]").forEach(function (cb) {
    var key = cb.getAttribute("data-persist");
    if (state[key]) cb.checked = true;
    cb.addEventListener("change", function () {
      state[key] = cb.checked;
      try { localStorage.setItem(STORE, JSON.stringify(state)); } catch (e) { /* 사파리 프라이빗 등 무시 */ }
    });
  });
})();
