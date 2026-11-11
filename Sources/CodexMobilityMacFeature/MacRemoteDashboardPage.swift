import Foundation

enum MacRemoteDashboardPage {
    static let html = #"""
    <!doctype html>
    <html lang="zh-CN">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
      <meta name="theme-color" content="#080a0d">
      <meta name="color-scheme" content="dark">
      <title>Tidux助手</title>
      <style>
        :root {
          --bg: #080a0d;
          --surface: #12151a;
          --surface-strong: #171b21;
          --surface-soft: #0e1115;
          --border: #2b3038;
          --divider: #292e35;
          --text: #f4f6f8;
          --muted: #9299a3;
          --faint: #686f79;
          --blue: #2878f6;
          --green: #62c96b;
          --amber: #f0aa42;
          --red: #ef6666;
          --radius: 16px;
          --safe-bottom: env(safe-area-inset-bottom, 0px);
          font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", sans-serif;
          color: var(--text);
          background: var(--bg);
        }

        * { box-sizing: border-box; }
        html { min-height: 100%; background: var(--bg); }
        body {
          min-height: 100%;
          margin: 0;
          background: var(--bg);
          color: var(--text);
          -webkit-font-smoothing: antialiased;
        }
        button, input, select { font: inherit; }
        button { -webkit-tap-highlight-color: transparent; }

        .shell {
          width: min(100%, 760px);
          margin: 0 auto;
          padding: max(18px, env(safe-area-inset-top)) 16px calc(88px + var(--safe-bottom));
        }

        .topbar {
          display: flex;
          align-items: flex-start;
          justify-content: space-between;
          gap: 16px;
          margin: 2px 2px 20px;
        }
        .title {
          margin: 0;
          font-size: clamp(28px, 8vw, 36px);
          line-height: 1.08;
          letter-spacing: -0.035em;
          font-weight: 750;
        }
        .secure-line {
          display: flex;
          align-items: center;
          gap: 8px;
          margin-top: 12px;
          color: var(--muted);
          font-size: 14px;
          line-height: 1.3;
        }
        .online {
          display: flex;
          align-items: center;
          gap: 8px;
          flex: 0 0 auto;
          margin-top: 6px;
          color: var(--green);
          font-size: 15px;
          font-weight: 650;
          white-space: nowrap;
        }
        .dot {
          width: 9px;
          height: 9px;
          border-radius: 999px;
          background: currentColor;
        }

        .section { margin-top: 28px; }
        .page-section { display: none; }
        body[data-active-page="overview"] [data-page="overview"],
        body[data-active-page="control"] [data-page="control"],
        body[data-active-page="files"] [data-page="files"],
        body[data-active-page="settings"] [data-page="settings"] { display: block; }
        .page-section:first-of-type { margin-top: 0; }
        .section-title {
          margin: 0 2px 12px;
          font-size: 20px;
          line-height: 1.2;
          letter-spacing: -0.02em;
          font-weight: 700;
        }
        .panel {
          overflow: hidden;
          background: var(--surface);
          border: 1px solid var(--border);
          border-radius: var(--radius);
        }

        .control-row {
          display: grid;
          grid-template-columns: minmax(0, 1fr) auto;
          align-items: center;
          gap: 16px;
          min-height: 112px;
          padding: 20px;
        }
        .control-row + .control-row { border-top: 1px solid var(--divider); }
        .control-title {
          margin: 0;
          font-size: 21px;
          line-height: 1.25;
          letter-spacing: -0.015em;
          font-weight: 690;
        }
        .control-status {
          margin-top: 7px;
          color: var(--muted);
          font-size: 14px;
          line-height: 1.45;
        }
        .control-source {
          display: block;
          margin-top: 3px;
          color: var(--faint);
          font-size: 12px;
        }
        .override-line {
          display: none;
          grid-column: 1 / -1;
          align-items: center;
          gap: 10px;
          margin: -4px 0 16px 20px;
          color: #5d9cff;
          font-size: 13px;
          line-height: 1.35;
        }
        .override-line.visible { display: flex; }
        .override-mark {
          width: 28px;
          height: 16px;
          border-left: 2px solid currentColor;
          border-bottom: 2px solid currentColor;
          border-bottom-left-radius: 4px;
        }

        .switch {
          position: relative;
          width: 58px;
          height: 34px;
          flex: 0 0 auto;
        }
        .switch input {
          position: absolute;
          width: 1px;
          height: 1px;
          opacity: 0;
          pointer-events: none;
        }
        .switch-track {
          position: absolute;
          inset: 0;
          border-radius: 999px;
          background: #343942;
          border: 1px solid #454b55;
          transition: background .18s ease, opacity .18s ease;
          cursor: pointer;
        }
        .switch-track::after {
          content: "";
          position: absolute;
          top: 3px;
          left: 3px;
          width: 26px;
          height: 26px;
          border-radius: 50%;
          background: #f7f8fa;
          box-shadow: 0 1px 3px rgba(0,0,0,.42);
          transition: transform .18s ease;
        }
        .switch input:checked + .switch-track {
          background: var(--blue);
          border-color: var(--blue);
        }
        .switch input:checked + .switch-track::after { transform: translateX(24px); }
        .switch input:focus-visible + .switch-track { outline: 3px solid rgba(40,120,246,.42); }
        .switch input:disabled + .switch-track { opacity: .45; cursor: not-allowed; }

        .lock-panel { padding: 4px 16px 16px; }
        .lock-setting-row {
          display: grid;
          grid-template-columns: minmax(0, 1fr) minmax(142px, auto);
          align-items: center;
          gap: 14px;
          min-height: 68px;
          border-bottom: 1px solid var(--divider);
        }
        .lock-setting-label {
          font-size: 15px;
          font-weight: 620;
          line-height: 1.35;
        }
        .lock-setting-hint {
          margin-top: 3px;
          color: var(--faint);
          font-size: 11px;
          line-height: 1.35;
        }
        .lock-select {
          width: 100%;
          min-height: 40px;
          padding: 7px 30px 7px 10px;
          color: var(--text);
          background: var(--surface-soft);
          border: 1px solid var(--border);
          border-radius: 9px;
          outline: none;
        }
        .session-duration-select { width: 142px; }
        .session-automation-note { margin: 0; padding: 0 20px 20px; }
        .lock-select:focus { border-color: var(--blue); }
        .lock-select:disabled { opacity: .45; }
        .lock-status {
          padding: 13px 2px 0;
          color: var(--muted);
          font-size: 12px;
          line-height: 1.5;
        }
        .lock-save {
          width: 100%;
          min-height: 44px;
          margin-top: 13px;
          color: white;
          background: var(--blue);
          border: 0;
          border-radius: 10px;
          font-weight: 680;
        }
        .lock-save:disabled { opacity: .42; }

        .status-list { padding: 0 16px; }
        .status-row {
          display: grid;
          grid-template-columns: 34px minmax(0, 1fr) auto;
          align-items: center;
          gap: 12px;
          min-height: 76px;
          border-bottom: 1px solid var(--divider);
        }
        .status-row:last-child { border-bottom: 0; }
        .status-icon {
          width: 24px;
          height: 24px;
          color: var(--blue);
        }
        .status-icon.healthy { color: var(--green); }
        .status-icon.warning { color: var(--amber); }
        .status-label {
          font-size: 16px;
          font-weight: 620;
        }
        .status-value {
          max-width: 190px;
          color: #bcc1c8;
          font-size: 15px;
          text-align: right;
          line-height: 1.35;
        }
        .temperature-row {
          grid-template-rows: auto auto;
          min-height: 190px;
          padding: 16px 0 14px;
        }
        .temperature-row > .status-icon { align-self: start; margin-top: 1px; }
        .temperature-heading { min-width: 0; }
        .temperature-source {
          margin-top: 3px;
          color: var(--faint);
          font-size: 12px;
          line-height: 1.3;
        }
        .temperature-chart {
          grid-column: 2 / -1;
          width: 100%;
          min-width: 0;
          padding-top: 14px;
        }
        .temperature-chart-meta,
        .temperature-chart-axis {
          display: flex;
          align-items: center;
          justify-content: space-between;
          gap: 10px;
          color: var(--muted);
          font-size: 11px;
          line-height: 1.3;
        }
        .temperature-chart-range {
          color: #c8cdd4;
          font-variant-numeric: tabular-nums;
          white-space: nowrap;
        }
        .temperature-chart svg {
          display: block;
          width: 100%;
          height: 78px;
          margin: 6px 0 5px;
          overflow: visible;
        }
        .temperature-grid-line {
          stroke: #2c323a;
          stroke-width: 1;
          vector-effect: non-scaling-stroke;
        }
        .temperature-line {
          fill: none;
          stroke: var(--green);
          stroke-width: 2.25;
          stroke-linecap: round;
          stroke-linejoin: round;
          vector-effect: non-scaling-stroke;
        }
        .temperature-line.warning { stroke: var(--amber); }
        .temperature-current-dot {
          fill: var(--surface);
          stroke: var(--green);
          stroke-width: 2.25;
          vector-effect: non-scaling-stroke;
        }
        .temperature-current-dot.warning { stroke: var(--amber); }
        .temperature-chart-status {
          min-width: 0;
          overflow: hidden;
          text-align: center;
          text-overflow: ellipsis;
          white-space: nowrap;
        }

        .network-grid {
          display: grid;
          grid-template-columns: repeat(3, minmax(0, 1fr));
          padding: 18px 4px;
        }
        .network-cell {
          min-width: 0;
          padding: 0 12px;
          text-align: center;
        }
        .network-cell + .network-cell { border-left: 1px solid var(--divider); }
        .network-key {
          color: var(--muted);
          font-size: 12px;
          line-height: 1.3;
        }
        .network-value {
          margin-top: 8px;
          overflow-wrap: anywhere;
          font-size: 15px;
          line-height: 1.3;
          font-variant-numeric: tabular-nums;
        }
        .network-note {
          padding: 0 18px 18px;
          color: var(--muted);
          font-size: 13px;
          line-height: 1.45;
        }

        .file-panel { padding: 16px; }
        .file-toolbar {
          display: flex;
          align-items: flex-start;
          justify-content: space-between;
          gap: 14px;
        }
        .file-directory { min-width: 0; }
        .file-directory-name {
          overflow: hidden;
          font-size: 16px;
          font-weight: 680;
          line-height: 1.35;
          text-overflow: ellipsis;
          white-space: nowrap;
        }
        .file-directory-detail {
          margin-top: 5px;
          color: var(--muted);
          font-size: 12px;
          line-height: 1.4;
        }
        .file-refresh {
          min-width: 66px;
          min-height: 36px;
          padding: 0 12px;
          color: #cbd1d8;
          background: var(--surface-strong);
          border: 1px solid var(--border);
          border-radius: 9px;
          font-size: 13px;
        }
        .file-refresh:disabled { opacity: .45; }
        .file-actions {
          display: grid;
          grid-template-columns: repeat(3, minmax(0, 1fr));
          gap: 10px;
          margin-top: 16px;
        }
        .file-action {
          min-height: 44px;
          padding: 0 10px;
          color: white;
          background: var(--blue);
          border: 0;
          border-radius: 10px;
          font-size: 13px;
          font-weight: 680;
        }
        .file-action.secondary {
          color: #dce6f7;
          background: #1c365d;
          border: 1px solid #2c548d;
        }
        .file-action:disabled { opacity: .42; }
        .file-limit-note {
          margin-top: 9px;
          color: var(--faint);
          font-size: 11px;
          line-height: 1.4;
          text-align: center;
        }
        .file-search {
          width: 100%;
          min-height: 40px;
          margin-top: 15px;
          padding: 8px 12px;
          color: var(--text);
          background: var(--surface-soft);
          border: 1px solid var(--border);
          border-radius: 10px;
          outline: none;
        }
        .file-search:focus { border-color: var(--blue); }
        .file-empty {
          padding: 24px 4px 10px;
          color: var(--muted);
          font-size: 14px;
          line-height: 1.55;
          text-align: center;
        }
        .file-list { margin-top: 12px; }
        .file-row {
          display: grid;
          grid-template-columns: 34px minmax(0, 1fr);
          align-items: center;
          gap: 10px;
          min-height: 66px;
          border-top: 1px solid var(--divider);
        }
        .file-kind {
          display: grid;
          width: 30px;
          height: 34px;
          place-items: center;
          color: #a9c8fa;
          background: #1b2a40;
          border-radius: 7px;
          font-size: 11px;
          font-weight: 740;
        }
        .file-info { min-width: 0; }
        .file-name {
          overflow: hidden;
          font-size: 14px;
          line-height: 1.35;
          text-overflow: ellipsis;
          white-space: nowrap;
        }
        .file-path,
        .file-meta {
          margin-top: 3px;
          overflow: hidden;
          color: var(--muted);
          font-size: 11px;
          line-height: 1.35;
          text-overflow: ellipsis;
          white-space: nowrap;
        }
        .file-download {
          min-width: 52px;
          min-height: 34px;
          color: #84b6ff;
          background: transparent;
          border: 1px solid #315582;
          border-radius: 8px;
          font-size: 12px;
          font-weight: 650;
        }
        .file-download:disabled { opacity: .42; }
        .file-row-actions {
          grid-column: 2;
          display: flex;
          gap: 8px;
          padding-bottom: 10px;
        }
        .file-preview {
          min-width: 52px;
          min-height: 34px;
          color: #c8d8ef;
          background: #1c2430;
          border: 1px solid #3b4a5d;
          border-radius: 8px;
          font-size: 12px;
          font-weight: 650;
        }
        .file-more {
          width: 100%;
          min-height: 42px;
          margin-top: 12px;
          color: #a9c8fa;
          background: var(--surface-soft);
          border: 1px solid var(--border);
          border-radius: 9px;
          font-size: 13px;
        }
        .upload-list:empty { display: none; }
        .upload-row {
          margin-top: 12px;
          padding: 11px 12px;
          background: var(--surface-soft);
          border: 1px solid var(--border);
          border-radius: 10px;
        }
        .upload-heading {
          display: flex;
          justify-content: space-between;
          gap: 10px;
          color: #d8dde4;
          font-size: 12px;
        }
        .upload-heading span:first-child {
          overflow: hidden;
          text-overflow: ellipsis;
          white-space: nowrap;
        }
        .upload-track {
          height: 5px;
          margin-top: 9px;
          overflow: hidden;
          background: #262b33;
          border-radius: 99px;
        }
        .upload-progress {
          width: 0;
          height: 100%;
          background: var(--blue);
          transition: width .15s ease;
        }
        .upload-row.complete .upload-progress { background: var(--green); }
        .upload-row.failed .upload-progress { background: var(--red); }
        .upload-detail {
          margin-top: 7px;
          color: var(--muted);
          font-size: 11px;
          line-height: 1.4;
          overflow-wrap: anywhere;
        }
        .transfer-cancel {
          margin-top: 8px;
          padding: 0;
          color: #9fbce7;
          background: transparent;
          border: 0;
          font-size: 11px;
        }
        .transfer-cancel:disabled { display: none; }

        .activity-list { padding: 6px 16px; }
        .activity-empty {
          padding: 24px 2px;
          color: var(--muted);
          font-size: 14px;
        }
        .activity-row {
          display: grid;
          grid-template-columns: 58px 12px minmax(0, 1fr);
          gap: 10px;
          min-height: 58px;
          padding: 11px 0;
          border-bottom: 1px solid var(--divider);
        }
        .activity-row:last-child { border-bottom: 0; }
        .activity-time {
          padding-top: 2px;
          color: var(--faint);
          font-size: 12px;
          font-variant-numeric: tabular-nums;
        }
        .activity-dot {
          width: 8px;
          height: 8px;
          margin-top: 5px;
          border-radius: 50%;
          background: #777e87;
        }
        .activity-dot.control { background: var(--blue); }
        .activity-dot.healthy { background: var(--green); }
        .activity-dot.warning { background: var(--amber); }
        .activity-title {
          font-size: 14px;
          line-height: 1.35;
        }
        .activity-detail {
          margin-top: 3px;
          color: var(--muted);
          font-size: 12px;
          line-height: 1.4;
          overflow-wrap: anywhere;
        }

        .tabbar {
          position: fixed;
          z-index: 20;
          right: 0;
          bottom: 0;
          left: 0;
          border-top: 1px solid var(--border);
          background: rgba(14,17,21,.96);
          padding: 7px max(10px, calc((100vw - 760px) / 2 + 10px)) calc(7px + var(--safe-bottom));
          backdrop-filter: blur(18px);
        }
        .tabbar-inner {
          display: grid;
          grid-template-columns: repeat(4, 1fr);
          gap: 4px;
          max-width: 724px;
          margin: 0 auto;
        }
        .tab-button {
          display: grid;
          min-height: 52px;
          place-items: center;
          gap: 2px;
          color: var(--muted);
          background: transparent;
          border: 0;
          border-radius: 11px;
          font-size: 11px;
          font-weight: 620;
        }
        .tab-button svg { width: 21px; height: 21px; }
        .tab-button.active { color: #75a9ff; background: rgba(40,120,246,.12); }

        .preview-overlay {
          position: fixed;
          z-index: 45;
          inset: 0;
          display: none;
          align-items: end;
          padding: 18px 16px calc(18px + var(--safe-bottom));
          background: rgba(2,4,7,.78);
          backdrop-filter: blur(12px);
        }
        .preview-overlay.visible { display: flex; }
        .preview-card {
          width: min(100%, 560px);
          max-height: 88vh;
          margin: 0 auto;
          overflow: auto;
          padding: 14px;
          background: var(--surface-strong);
          border: 1px solid var(--border);
          border-radius: 18px;
        }
        .preview-image {
          display: block;
          width: 100%;
          max-height: 58vh;
          object-fit: contain;
          background: #090b0e;
          border-radius: 12px;
        }
        .preview-title { margin: 13px 2px 0; font-size: 15px; font-weight: 680; overflow-wrap: anywhere; }
        .preview-meta { margin: 6px 2px 12px; color: var(--muted); font-size: 12px; line-height: 1.5; }
        .preview-actions { display: grid; grid-template-columns: 1fr 1fr; gap: 9px; }
        .preview-actions button { min-height: 44px; border-radius: 10px; font-weight: 650; }
        .preview-close { color: var(--text); background: #252a32; border: 1px solid #3a414b; }
        .preview-download { color: white; background: var(--blue); border: 0; }

        .auth-overlay {
          position: fixed;
          z-index: 50;
          inset: 0;
          display: none;
          place-items: center;
          padding: 24px;
          background: rgba(8,10,13,.96);
        }
        .auth-overlay.visible { display: grid; }
        .auth-card {
          width: min(100%, 380px);
          padding: 24px;
          background: var(--surface);
          border: 1px solid var(--border);
          border-radius: 18px;
        }
        .auth-card h2 { margin: 0; font-size: 22px; }
        .auth-card p { color: var(--muted); font-size: 14px; line-height: 1.55; }
        .token-input {
          width: 100%;
          min-height: 46px;
          margin: 6px 0 12px;
          padding: 10px 12px;
          color: var(--text);
          background: var(--surface-soft);
          border: 1px solid var(--border);
          border-radius: 10px;
          outline: none;
        }
        .token-input:focus { border-color: var(--blue); }
        .primary-button {
          width: 100%;
          min-height: 46px;
          color: white;
          background: var(--blue);
          border: 0;
          border-radius: 10px;
          font-weight: 680;
        }

        .toast {
          position: fixed;
          z-index: 60;
          top: max(16px, env(safe-area-inset-top));
          left: 50%;
          width: min(calc(100% - 32px), 520px);
          padding: 12px 15px;
          color: var(--text);
          background: #242933;
          border: 1px solid #3a414c;
          border-radius: 12px;
          box-shadow: 0 12px 28px rgba(0,0,0,.35);
          font-size: 14px;
          line-height: 1.4;
          transform: translate(-50%, -140%);
          transition: transform .2s ease;
        }
        .toast.visible { transform: translate(-50%, 0); }
        .toast.error { border-color: #79522d; color: #ffd3a0; }

        .skeleton { opacity: .55; }
        @media (min-width: 620px) {
          .shell { padding-right: 24px; padding-left: 24px; }
          .control-row { min-height: 104px; padding-right: 24px; padding-left: 24px; }
        }
        @media (max-width: 360px) {
          .shell { padding-right: 12px; padding-left: 12px; }
          .title { font-size: 27px; }
          .online { font-size: 13px; }
          .control-row { padding: 17px 16px; }
          .control-title { font-size: 19px; }
          .network-cell { padding: 0 7px; }
          .network-value { font-size: 13px; }
          .status-value { max-width: 135px; font-size: 14px; }
        }
        @media (prefers-reduced-motion: reduce) {
          *, *::before, *::after { scroll-behavior: auto !important; transition: none !important; }
        }
      </style>
    </head>
    <body data-active-page="overview">
      <main class="shell" id="dashboard">
        <header class="topbar">
          <div>
            <h1 class="title" id="pageTitle">概览</h1>
            <div class="secure-line">
              <svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><rect x="5" y="10" width="14" height="10" rx="2"/><path d="M8 10V7a4 4 0 0 1 8 0v3"/></svg>
              <span>Tidux助手 · <span id="footerState">连接中</span> · <span id="syncAge">正在同步</span></span>
            </div>
          </div>
          <div class="online" id="onlineState"><span class="dot"></span><span>Mac 在线</span></div>
        </header>

        <section class="panel page-section" data-page="control" aria-label="合盖控制">
          <div class="control-row">
            <div>
              <h2 class="control-title">合盖运行</h2>
              <div class="control-status" id="baselineStatus">正在读取当前配置</div>
              <span class="control-source" id="baselineSource"></span>
            </div>
            <label class="switch" aria-label="切换合盖运行">
              <input id="baselineToggle" type="checkbox">
              <span class="switch-track"></span>
            </label>
          </div>
          <div class="control-row">
            <div>
              <h2 class="control-title">移动办公模式</h2>
              <div class="control-status" id="temporaryStatus">正在读取临时模式</div>
              <span class="control-source" id="temporaryTimer"></span>
            </div>
            <label class="switch" aria-label="切换移动办公模式">
              <input id="temporaryToggle" type="checkbox">
              <span class="switch-track"></span>
            </label>
          </div>
          <label class="control-row">
            <span><span class="lock-setting-label">随行时长</span><span class="control-source">启动后固定本次时长<br>到期自动恢复</span></span>
            <select class="lock-select session-duration-select" id="temporaryDuration" aria-label="随行时长" onchange="this.dataset.dirty = 'true'">
                <option value="900">15 分钟</option>
                <option value="1800">30 分钟</option>
                <option value="2700">45 分钟</option>
                <option value="3600">1 小时</option>
                <option value="4500">1 小时 15 分</option>
                <option value="5400">1 小时 30 分</option>
                <option value="6300">1 小时 45 分</option>
                <option value="7200" selected>2 小时</option>
                <option value="8100">2 小时 15 分</option>
                <option value="9000">2 小时 30 分</option>
                <option value="9900">2 小时 45 分</option>
                <option value="10800">3 小时</option>
                <option value="11700">3 小时 15 分</option>
                <option value="12600">3 小时 30 分</option>
                <option value="13500">3 小时 45 分</option>
                <option value="14400">4 小时</option>
            </select>
          </label>
          <p class="control-status session-automation-note">启动即连接已保存的目标热点。合盖或锁屏可能影响 computer use 的截图和点击；浏览器后台操作需单独验证。</p>
          <div class="override-line" id="overrideLine">
            <span class="override-mark" aria-hidden="true"></span>
            <span>当前临时覆盖“合盖运行”，结束后恢复启动前配置</span>
          </div>
        </section>

        <section class="section page-section" data-page="settings" aria-labelledby="screenLockTitle">
          <h2 class="section-title" id="screenLockTitle">自动锁屏</h2>
          <div class="panel lock-panel">
            <label class="lock-setting-row">
              <span>
                <span class="lock-setting-label">使用电池时</span>
                <span class="lock-setting-hint">闲置多久后关闭屏幕</span>
              </span>
              <select class="lock-select" id="lockBatteryMinutes">
                <option value="0">永不</option>
                <option value="1">1 分钟</option>
                <option value="2">2 分钟</option>
                <option value="5">5 分钟</option>
                <option value="10">10 分钟</option>
                <option value="15">15 分钟</option>
                <option value="20">20 分钟</option>
                <option value="30">30 分钟</option>
                <option value="45">45 分钟</option>
                <option value="60">1 小时</option>
                <option value="90">1.5 小时</option>
                <option value="120">2 小时</option>
                <option value="150">2.5 小时</option>
                <option value="180">3 小时</option>
              </select>
            </label>
            <label class="lock-setting-row">
              <span>
                <span class="lock-setting-label">接入电源时</span>
                <span class="lock-setting-hint">可与电池模式分别设置</span>
              </span>
              <select class="lock-select" id="lockPowerMinutes">
                <option value="0">永不</option>
                <option value="1">1 分钟</option>
                <option value="2">2 分钟</option>
                <option value="5">5 分钟</option>
                <option value="10">10 分钟</option>
                <option value="15">15 分钟</option>
                <option value="20">20 分钟</option>
                <option value="30">30 分钟</option>
                <option value="45">45 分钟</option>
                <option value="60">1 小时</option>
                <option value="90">1.5 小时</option>
                <option value="120">2 小时</option>
                <option value="150">2.5 小时</option>
                <option value="180">3 小时</option>
              </select>
            </label>
            <label class="lock-setting-row">
              <span>
                <span class="lock-setting-label">关闭屏幕后需要密码</span>
                <span class="lock-setting-hint">只读；仅可在这台 Mac 的“系统设置 → 锁定屏幕”中修改</span>
              </span>
              <select class="lock-select" id="lockPasswordDelay" disabled aria-readonly="true">
                <option value="-1">不需要密码</option>
                <option value="0">立即</option>
                <option value="5">5 秒后</option>
                <option value="60">1 分钟后</option>
                <option value="300">5 分钟后</option>
                <option value="900">15 分钟后</option>
                <option value="3600">1 小时后</option>
                <option value="14400">4 小时后</option>
                <option value="28800">8 小时后</option>
              </select>
            </label>
            <label class="lock-setting-row">
              <span>
                <span class="lock-setting-label">合盖后锁定屏幕</span>
                <span class="lock-setting-hint">合盖会先立即关闭显示器；开盖会取消尚未到期的锁屏</span>
              </span>
              <select class="lock-select" id="lockLidCloseDelay">
                <option value="-1">关闭</option>
                <option value="0">立即</option>
                <option value="15">15 秒后</option>
                <option value="30">30 秒后</option>
                <option value="60">1 分钟后</option>
                <option value="300">5 分钟后</option>
                <option value="900">15 分钟后</option>
              </select>
            </label>
            <div class="lock-status" id="lidCloseLockStatus">合盖锁屏正在初始化</div>
            <div class="lock-status">锁屏密码策略在手机端只读。修改后请回到此页，实时状态会自动同步。</div>
            <div class="lock-status">提示：若系统的“关闭屏幕后需要密码”更短，macOS 会按两者中较早的时间要求密码。</div>
            <div class="lock-status" id="lockSettingsStatus">正在读取 macOS 实际配置</div>
            <button class="lock-save" id="lockSettingsSave" type="button">保存到这台 Mac</button>
          </div>
        </section>

        <section class="section page-section" data-page="settings" aria-labelledby="macOnlyTitle">
          <h2 class="section-title" id="macOnlyTitle">只在 Mac 上配置</h2>
          <div class="panel lock-panel">
            <div class="lock-setting-row"><span><span class="lock-setting-label">同步根目录</span><span class="lock-setting-hint">选择、更换、移除目录和在 Finder 打开</span></span><span class="control-source">本机操作</span></div>
            <div class="lock-setting-row"><span><span class="lock-setting-label">系统助手与实验模块</span><span class="lock-setting-hint">管理员授权、模块总开关、语音输入能力</span></span><span class="control-source">本机操作</span></div>
            <div class="lock-setting-row"><span><span class="lock-setting-label">配对与联网身份</span><span class="lock-setting-hint">配对码、令牌轮换和已保存热点名称</span></span><span class="control-source">本机操作</span></div>
            <div class="lock-status">这些操作可能中断当前远程连接或扩大系统权限，因此不会在手机 H5 中伪装成可远程配置项。</div>
          </div>
        </section>

        <section class="section page-section" data-page="overview">
          <h2 class="section-title">运行概览</h2>
          <div class="panel status-list">
            <div class="status-row">
              <svg class="status-icon healthy" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><rect x="2" y="7" width="18" height="10" rx="2"/><path d="M22 10v4"/><path d="M5 10h11v4H5z" fill="currentColor" stroke="none"/></svg>
              <div class="status-label">电池</div>
              <div class="status-value" id="batteryValue">—</div>
            </div>
            <div class="status-row temperature-row">
              <svg class="status-icon healthy" id="thermalIcon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><path d="M9 14.8V5a3 3 0 0 1 6 0v9.8a5 5 0 1 1-6 0Z"/><path d="M12 8v8"/></svg>
              <div class="temperature-heading">
                <div class="status-label">温度 / 热状态</div>
                <div class="temperature-source" id="temperatureSource">正在读取传感器</div>
              </div>
              <div class="status-value" id="thermalValue">—</div>
              <div class="temperature-chart">
                <div class="temperature-chart-meta">
                  <span>过去 12 小时 · 每分钟</span>
                  <span class="temperature-chart-range" id="temperatureRange">—</span>
                </div>
                <svg viewBox="0 0 360 78" preserveAspectRatio="none" role="img" aria-labelledby="temperatureChartTitle">
                  <title id="temperatureChartTitle">过去 12 小时温度曲线，正在读取数据</title>
                  <line class="temperature-grid-line" x1="0" y1="8" x2="360" y2="8"/>
                  <line class="temperature-grid-line" x1="0" y1="39" x2="360" y2="39"/>
                  <line class="temperature-grid-line" x1="0" y1="70" x2="360" y2="70"/>
                  <path class="temperature-line" id="temperatureLine" d=""/>
                  <circle class="temperature-current-dot" id="temperatureCurrentDot" cx="0" cy="0" r="3.5" hidden/>
                </svg>
                <div class="temperature-chart-axis">
                  <span>12 小时前</span>
                  <span class="temperature-chart-status" id="temperatureHistoryStatus">正在积累分钟采样</span>
                  <span>现在</span>
                </div>
              </div>
            </div>
            <div class="status-row">
              <svg class="status-icon" id="networkIcon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><path d="M2 8.8a15 15 0 0 1 20 0"/><path d="M5 12.3a10.5 10.5 0 0 1 14 0"/><path d="M8.5 15.8a5.2 5.2 0 0 1 7 0"/><circle cx="12" cy="19" r="1" fill="currentColor" stroke="none"/></svg>
              <div class="status-label">网络</div>
              <div class="status-value" id="networkValue">—</div>
            </div>
            <div class="status-row">
              <svg class="status-icon" id="remoteIcon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><rect x="3" y="4" width="18" height="13" rx="2"/><path d="M8 21h8M12 17v4"/></svg>
              <div class="status-label">Codex 远控</div>
              <div class="status-value" id="remoteValue">—</div>
            </div>
          </div>
        </section>

        <section class="section page-section" data-page="overview">
          <h2 class="section-title">网络详情</h2>
          <div class="panel">
            <div class="network-grid">
              <div class="network-cell">
                <div class="network-key">接口</div>
                <div class="network-value" id="interfaceValue">—</div>
              </div>
              <div class="network-cell">
                <div class="network-key">可用路径时长</div>
                <div class="network-value" id="durationValue">—</div>
              </div>
              <div class="network-cell">
                <div class="network-key">热点恢复</div>
                <div class="network-value" id="hotspotValue">—</div>
              </div>
            </div>
            <div class="network-note" id="networkNote">正在读取网络与热点守护状态。</div>
          </div>
        </section>

        <section class="section page-section" data-page="files" aria-labelledby="fileSyncTitle">
          <h2 class="section-title" id="fileSyncTitle">文件同步</h2>
          <div class="panel file-panel">
            <div class="file-toolbar">
              <div class="file-directory">
                <div class="file-directory-name" id="fileDirectoryName">正在读取同步目录</div>
                <div class="file-directory-detail" id="fileDirectoryDetail">手机与 Mac 使用同一份文件列表</div>
              </div>
              <button class="file-refresh" id="fileRefreshButton" type="button">刷新</button>
            </div>
            <div class="file-actions">
              <button class="file-action" id="uploadFileButton" type="button">选择文件</button>
              <button class="file-action secondary" id="uploadMediaButton" type="button">照片 / 视频</button>
              <button class="file-action secondary" id="uploadDirectoryButton" type="button">整个目录</button>
            </div>
            <div class="file-limit-note" id="fileLimitNote">上传内容将安全保存到 Mac 选定的同步目录</div>
            <input id="fileInput" type="file" multiple hidden>
            <input id="mediaInput" type="file" accept="image/*,video/*" multiple hidden>
            <input id="directoryInput" type="file" multiple webkitdirectory directory hidden>
            <div class="upload-list" id="uploadList" aria-live="polite"></div>
            <input class="file-search" id="fileSearch" type="search" placeholder="搜索文件名或路径" aria-label="搜索同步文件">
            <div class="file-list" id="fileList">
              <div class="file-empty">正在读取 Mac 同步目录…</div>
            </div>
          </div>
        </section>

        <section class="section page-section" data-page="overview">
          <h2 class="section-title">最近活动</h2>
          <div class="panel activity-list" id="activityList">
            <div class="activity-empty">等待状态变化…</div>
          </div>
        </section>
      </main>

      <nav class="tabbar" aria-label="主要功能">
        <div class="tabbar-inner">
          <button class="tab-button active" type="button" data-tab="overview"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M4 13h6V4H4v9Zm10 7h6v-9h-6v9ZM4 20h6v-3H4v3Zm10-13h6V4h-6v3Z"/></svg><span>概览</span></button>
          <button class="tab-button" type="button" data-tab="control"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M4 21v-7m0-4V3m8 18v-9m0-4V3m8 18v-5m0-4V3"/><path d="M1 14h6M9 8h6m2 8h6"/></svg><span>控制</span></button>
          <button class="tab-button" type="button" data-tab="files"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 7a2 2 0 0 1 2-2h5l2 2h7a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7Z"/></svg><span>文件</span></button>
          <button class="tab-button" type="button" data-tab="settings"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .34 1.88l.06.06-2.83 2.83-.06-.06A1.7 1.7 0 0 0 15 19.4a1.7 1.7 0 0 0-1 .6 1.7 1.7 0 0 0-.4 1.1V21h-4v-.09A1.7 1.7 0 0 0 8.6 19.4a1.7 1.7 0 0 0-1.88.34l-.06.06-2.83-2.83.06-.06A1.7 1.7 0 0 0 4.6 15a1.7 1.7 0 0 0-.6-1 1.7 1.7 0 0 0-1.1-.4H3v-4h.09A1.7 1.7 0 0 0 4.6 8.6a1.7 1.7 0 0 0-.34-1.88l-.06-.06 2.83-2.83.06.06A1.7 1.7 0 0 0 9 4.6a1.7 1.7 0 0 0 1-.6 1.7 1.7 0 0 0 .4-1.1V3h4v.09A1.7 1.7 0 0 0 15.4 4.6a1.7 1.7 0 0 0 1.88-.34l.06-.06 2.83 2.83-.06.06A1.7 1.7 0 0 0 19.4 9c.13.38.34.72.6 1 .3.3.7.4 1.1.4H21v4h-.09a1.7 1.7 0 0 0-1.51.6Z"/></svg><span>设置</span></button>
        </div>
      </nav>

      <div class="preview-overlay" id="previewOverlay" role="dialog" aria-modal="true" aria-labelledby="previewTitle">
        <div class="preview-card">
          <img class="preview-image" id="previewImage" alt="低流量图片预览">
          <div class="preview-title" id="previewTitle">图片预览</div>
          <div class="preview-meta" id="previewMeta">正在生成低分辨率预览…</div>
          <div class="preview-actions">
            <button class="preview-close" id="previewClose" type="button">关闭</button>
            <button class="preview-download" id="previewDownload" type="button">下载原图</button>
          </div>
        </div>
      </div>

      <div class="auth-overlay" id="authOverlay" role="dialog" aria-modal="true" aria-labelledby="authTitle">
        <form class="auth-card" id="authForm">
          <h2 id="authTitle">连接这台 Mac</h2>
          <p>当前打开的是不含凭证的基础地址。请从 Mac 的“手机控制台”菜单选择“复制公网安全访问链接”或“在浏览器打开公网控制台”，也可以输入完整链接中的访问令牌。</p>
          <input class="token-input" id="tokenInput" type="password" autocomplete="off" placeholder="访问令牌" aria-label="访问令牌">
          <button class="primary-button" type="submit">安全连接</button>
        </form>
      </div>
      <div class="toast" id="toast" role="status" aria-live="polite"></div>

      <script>
        (() => {
          const debugViewport = new URLSearchParams(location.search).get("debugViewport");
          if (debugViewport === "440x860" && window.self === window.top) {
            const frame = document.createElement("iframe");
            frame.title = "Tidux助手 440×860 移动端调试视口";
            frame.src = `${location.pathname}?embeddedDebugViewport=440x860`;
            frame.style.cssText = "display:block;width:440px;height:860px;border:0;background:#080a0d";
            document.body.style.margin = "0";
            document.body.replaceChildren(frame);
            return;
          }
          const hubBasePath = location.pathname.startsWith("/app/codex-watch-pet")
            ? "/app/codex-watch-pet"
            : "";
          const isHubMode = hubBasePath.length > 0;
          const endpoint = path => `${hubBasePath}${path}`;
          const state = {
            token: "",
            snapshot: null,
            lastSyncAt: null,
            socket: null,
            webSocketReady: false,
            reconnectTimer: null,
            reconnectAttempt: 0,
            fallbackTimer: null,
            clockTimer: null,
            toastTimer: null,
            actionBusy: false,
            screenLockBusy: false,
            files: [],
            fileConfig: null,
            fileRenderLimit: 200,
            filesVersion: null,
            filesLoading: false,
            fileRefreshTimer: null,
            uploadBusyCount: 0,
            previewObjectURL: null,
            previewFile: null,
            reconnectAllowed: true
          };

          const el = id => document.getElementById(id);
          const baselineToggle = el("baselineToggle");
          const temporaryToggle = el("temporaryToggle");

          function activatePage(page) {
            const titles = { overview: "概览", control: "控制", files: "文件", settings: "设置" };
            if (!titles[page]) return;
            document.body.dataset.activePage = page;
            el("pageTitle").textContent = titles[page];
            document.querySelectorAll("[data-tab]").forEach(button => {
              const active = button.dataset.tab === page;
              button.classList.toggle("active", active);
              button.setAttribute("aria-current", active ? "page" : "false");
            });
            sessionStorage.setItem("cwp-active-page", page);
            window.scrollTo({ top: 0, behavior: "instant" });
            if (page === "files") refreshFiles({ quiet: true });
          }

          function setScreenLockControlsDisabled(disabled) {
            el("lockBatteryMinutes").disabled = disabled;
            el("lockPowerMinutes").disabled = disabled;
            el("lockPasswordDelay").disabled = true;
            el("lockLidCloseDelay").disabled = state.screenLockBusy;
            el("lockSettingsSave").disabled = disabled;
          }

          function ensureSelectValue(select, value, suffix) {
            if (value === null || value === undefined || !Number.isFinite(Number(value))) return;
            const normalized = String(Number(value));
            if (!Array.from(select.options).some(option => option.value === normalized)) {
              const option = document.createElement("option");
              option.value = normalized;
              option.textContent = `${normalized} ${suffix}（当前值）`;
              select.appendChild(option);
            }
            select.value = normalized;
          }

          function applyScreenLockSettings(settings) {
            if (!settings) {
              el("lockSettingsStatus").textContent = "macOS 尚未返回自动锁屏配置";
              setScreenLockControlsDisabled(true);
              return;
            }
            ensureSelectValue(
              el("lockBatteryMinutes"),
              settings.batteryDisplaySleepMinutes,
              "分钟"
            );
            ensureSelectValue(
              el("lockPowerMinutes"),
              settings.powerAdapterDisplaySleepMinutes,
              "分钟"
            );
            if (settings.requiresPassword === false) {
              el("lockPasswordDelay").value = "-1";
            } else {
              ensureSelectValue(
                el("lockPasswordDelay"),
                settings.passwordDelaySeconds,
                "秒后"
              );
            }
            el("lockLidCloseDelay").value = settings.lidCloseLockDelaySeconds === null
              || settings.lidCloseLockDelaySeconds === undefined
              ? "-1"
              : String(Number(settings.lidCloseLockDelaySeconds));
            el("lidCloseLockStatus").textContent = settings.lidCloseLockStatus
              || "合盖锁屏已连接";
            el("lockSettingsStatus").textContent = settings.status
              || "已读取 macOS 自动锁屏配置";
            setScreenLockControlsDisabled(
              state.screenLockBusy || !settings.isConfigurable
            );
          }

          function loadToken() {
            if (isHubMode) {
              state.token = "";
              el("authOverlay").classList.remove("visible");
              return;
            }
            const params = new URLSearchParams(location.hash.slice(1));
            const fragmentToken = params.get("token");
            if (fragmentToken) {
              sessionStorage.setItem("cwp-web-token", fragmentToken);
              history.replaceState(null, "", location.pathname + location.search);
            }
            state.token = fragmentToken || sessionStorage.getItem("cwp-web-token") || "";
            el("authOverlay").classList.toggle("visible", !state.token);
          }

          function showToast(message, isError = false) {
            const toast = el("toast");
            toast.textContent = message;
            toast.classList.toggle("error", isError);
            toast.classList.add("visible");
            clearTimeout(state.toastTimer);
            state.toastTimer = setTimeout(() => toast.classList.remove("visible"), 3600);
          }

          async function request(path, options = {}) {
            const headers = new Headers(options.headers || {});
            if (state.token) headers.set("Authorization", `Bearer ${state.token}`);
            if (options.body && !headers.has("Content-Type")) {
              headers.set("Content-Type", "application/json");
            }
            const response = await fetch(endpoint(path), { ...options, headers, cache: "no-store" });
            const payload = await response.json().catch(() => ({}));
            if (response.status === 401) {
              clearAuthentication();
            }
            if (!response.ok) {
              const error = new Error(payload.error || payload.message || `请求失败 (${response.status})`);
              error.payload = payload;
              throw error;
            }
            return payload;
          }

          async function refreshFiles({ quiet = false } = {}) {
            if ((!isHubMode && !state.token) || state.filesLoading) return;
            state.filesLoading = true;
            el("fileRefreshButton").disabled = true;
            try {
              const payload = await request("/api/files");
              state.fileConfig = payload;
              state.files = Array.isArray(payload.files) ? payload.files : [];
              state.fileRenderLimit = 200;
              renderFiles();
            } catch (error) {
              state.fileConfig = null;
              state.files = [];
              el("fileDirectoryName").textContent = "同步目录暂不可用";
              el("fileDirectoryDetail").textContent = error.message;
              el("fileList").replaceChildren();
              appendFileEmpty("无法读取同步目录，请检查 Mac 端目录状态。", el("fileList"));
              setFileActionsEnabled(false);
              if (!quiet) showToast(error.message, true);
            } finally {
              state.filesLoading = false;
              el("fileRefreshButton").disabled = false;
            }
          }

          function renderFiles() {
            const config = state.fileConfig;
            const list = el("fileList");
            list.replaceChildren();
            if (!config || !config.isConfigured) {
              el("fileDirectoryName").textContent = "尚未选择同步目录";
              el("fileDirectoryDetail").textContent = "请在 Mac 应用的“文件同步”中选择目标文件夹";
              el("fileLimitNote").textContent = "H5 不能远程选择 Mac 的任意目录";
              setFileActionsEnabled(false);
              appendFileEmpty("请先在 Mac 端选择同步目录，随后这里会显示同一份文件列表。", list);
              return;
            }

            const countText = config.isTruncated
              ? `显示 ${state.files.length} / ${config.totalCount} 个文件`
              : `${config.totalCount} 个文件`;
            el("fileDirectoryName").textContent = config.directoryName || "同步目录";
            el("fileDirectoryDetail").textContent = config.isEnabled
              ? `${countText} · 手机与 Mac 已连接`
              : `${countText} · Mac 端同步已暂停`;
            el("fileLimitNote").textContent = `单文件上限 ${formatFileSize(config.maximumUploadBytes)}；同名文件会保留为新副本`;
            setFileActionsEnabled(!!config.isEnabled);

            const query = el("fileSearch").value.trim().toLocaleLowerCase("zh-CN");
            const files = query
              ? state.files.filter(file => file.relativePath.toLocaleLowerCase("zh-CN").includes(query))
              : state.files;
            if (!files.length) {
              appendFileEmpty(query ? "没有匹配的文件。" : "目录当前没有可同步文件。", list);
              return;
            }

            const visibleFiles = files.slice(0, state.fileRenderLimit);
            for (const file of visibleFiles) {
              const row = document.createElement("div");
              row.className = "file-row";
              const kind = document.createElement("div");
              kind.className = "file-kind";
              kind.textContent = fileKindLabel(file.mediaKind);
              const info = document.createElement("div");
              info.className = "file-info";
              const name = document.createElement("div");
              name.className = "file-name";
              name.textContent = file.name;
              const path = document.createElement("div");
              path.className = "file-path";
              path.textContent = file.relativePath;
              const meta = document.createElement("div");
              meta.className = "file-meta";
              meta.textContent = `${formatFileSize(file.byteCount)} · ${formatFileDate(file.modifiedAt)}`;
              info.append(name, path, meta);
              const actions = document.createElement("div");
              actions.className = "file-row-actions";
              if (file.mediaKind === "image") {
                const preview = document.createElement("button");
                preview.className = "file-preview";
                preview.type = "button";
                preview.textContent = "预览";
                preview.disabled = !config.isEnabled;
                preview.addEventListener("click", () => previewFile(file, preview));
                actions.appendChild(preview);
              }
              const button = document.createElement("button");
              button.className = "file-download";
              button.type = "button";
              button.textContent = "下载";
              button.disabled = !config.isEnabled;
              button.addEventListener("click", () => downloadFile(file, button));
              actions.appendChild(button);
              row.append(kind, info, actions);
              list.appendChild(row);
            }
            if (visibleFiles.length < files.length) {
              const more = document.createElement("button");
              more.className = "file-more";
              more.type = "button";
              more.textContent = `继续显示（还有 ${files.length - visibleFiles.length} 个）`;
              more.addEventListener("click", () => {
                state.fileRenderLimit += 200;
                renderFiles();
              });
              list.appendChild(more);
            }
          }

          function appendFileEmpty(message, list) {
            const empty = document.createElement("div");
            empty.className = "file-empty";
            empty.textContent = message;
            list.appendChild(empty);
          }

          function setFileActionsEnabled(enabled) {
            const available = enabled;
            el("uploadFileButton").disabled = !available;
            el("uploadMediaButton").disabled = !available;
            el("uploadDirectoryButton").disabled = !available;
            el("fileSearch").disabled = !state.fileConfig?.isConfigured;
          }

          function fileKindLabel(kind) {
            return ({ image: "图", video: "影", audio: "音", document: "文", archive: "压" })[kind] || "件";
          }

          function formatFileSize(value) {
            const bytes = Math.max(Number(value) || 0, 0);
            if (bytes < 1024) return `${bytes} B`;
            const units = ["KB", "MB", "GB", "TB"];
            let amount = bytes;
            let unit = -1;
            do {
              amount /= 1024;
              unit += 1;
            } while (amount >= 1024 && unit < units.length - 1);
            return `${amount >= 10 ? amount.toFixed(1) : amount.toFixed(2)} ${units[unit]}`;
          }

          function formatFileDate(value) {
            const date = new Date(value);
            if (Number.isNaN(date.getTime())) return "时间未知";
            return new Intl.DateTimeFormat("zh-CN", {
              month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hour12: false
            }).format(date);
          }

          async function downloadFile(file, button) {
            const path = `/api/files/download?path=${encodeURIComponent(file.relativePath)}`;
            const view = createTransferView(file, "下载");
            const controller = new AbortController();
            view.cancel.addEventListener("click", () => controller.abort(), { once: true });
            if (button) {
              button.disabled = true;
              button.textContent = "下载中";
            }
            try {
              const headers = new Headers();
              if (state.token) headers.set("Authorization", `Bearer ${state.token}`);
              const response = await fetch(endpoint(path), {
                headers,
                cache: "no-store",
                credentials: "same-origin",
                signal: controller.signal
              });
              if (response.status === 401) clearAuthentication();
              if (!response.ok) {
                const payload = await response.json().catch(() => ({}));
                throw new Error(payload.error || `下载失败 (${response.status})`);
              }
              const total = Number(response.headers.get("Content-Length")) || Number(file.byteCount) || 0;
              const startedAt = performance.now();
              let received = 0;
              const chunks = [];
              if (response.body?.getReader) {
                const reader = response.body.getReader();
                while (true) {
                  const { done, value } = await reader.read();
                  if (done) break;
                  chunks.push(value);
                  received += value.byteLength;
                  const elapsed = Math.max((performance.now() - startedAt) / 1000, .1);
                  updateTransferProgress(view, total ? received / total : 0, transferDetail("正在下载", received, total, received / elapsed));
                }
              } else {
                const blob = await response.blob();
                chunks.push(new Uint8Array(await blob.arrayBuffer()));
                received = blob.size;
              }
              const blob = new Blob(chunks, { type: response.headers.get("Content-Type") || file.contentType });
              const objectURL = URL.createObjectURL(blob);
              const link = document.createElement("a");
              link.href = objectURL;
              link.download = file.name;
              document.body.appendChild(link);
              link.click();
              link.remove();
              setTimeout(() => URL.revokeObjectURL(objectURL), 30_000);
              updateTransferProgress(view, 1, `下载完成 · ${formatFileSize(received)}`, "complete");
              showToast(`${file.name} 已下载`);
            } catch (error) {
              const message = error.name === "AbortError" ? "下载已取消" : error.message;
              updateTransferProgress(view, 1, message, "failed");
              showToast(message, error.name !== "AbortError");
            } finally {
              view.cancel.disabled = true;
              if (button) {
                button.disabled = !state.fileConfig?.isEnabled;
                button.textContent = "下载";
              }
            }
          }

          async function previewFile(file, button) {
            button.disabled = true;
            el("previewTitle").textContent = file.name;
            el("previewMeta").textContent = "正在生成低分辨率预览…";
            el("previewImage").removeAttribute("src");
            state.previewFile = file;
            el("previewOverlay").classList.add("visible");
            try {
              const headers = new Headers();
              if (state.token) headers.set("Authorization", `Bearer ${state.token}`);
              const response = await fetch(endpoint(`/api/files/preview?maxPixel=960&path=${encodeURIComponent(file.relativePath)}`), {
                headers,
                credentials: "same-origin",
                cache: "no-store"
              });
              if (!response.ok) {
                const payload = await response.json().catch(() => ({}));
                throw new Error(payload.error || `预览失败 (${response.status})`);
              }
              const blob = await response.blob();
              if (state.previewObjectURL) URL.revokeObjectURL(state.previewObjectURL);
              state.previewObjectURL = URL.createObjectURL(blob);
              el("previewImage").src = state.previewObjectURL;
              el("previewMeta").textContent = `低流量预览 ${formatFileSize(blob.size)} · 原图 ${formatFileSize(file.byteCount)}。确认后再下载原图。`;
            } catch (error) {
              el("previewMeta").textContent = error.message;
              showToast(error.message, true);
            } finally {
              button.disabled = !state.fileConfig?.isEnabled;
            }
          }

          function closePreview() {
            el("previewOverlay").classList.remove("visible");
            if (state.previewObjectURL) URL.revokeObjectURL(state.previewObjectURL);
            state.previewObjectURL = null;
            state.previewFile = null;
            el("previewImage").removeAttribute("src");
          }

          async function uploadSelectedFiles(fileList) {
            const files = Array.from(fileList || []);
            if (!files.length || !state.fileConfig?.isEnabled) return;
            state.uploadBusyCount += files.length;
            setFileActionsEnabled(true);
            try {
              let nextIndex = 0;
              const worker = async () => {
                while (nextIndex < files.length) {
                  const file = files[nextIndex++];
                  try { await uploadFile(file); }
                  finally { state.uploadBusyCount = Math.max(state.uploadBusyCount - 1, 0); }
                }
              };
              await Promise.all(Array.from({ length: Math.min(3, files.length) }, worker));
            } finally {
              setFileActionsEnabled(!!state.fileConfig?.isEnabled);
              el("fileInput").value = "";
              el("mediaInput").value = "";
              el("directoryInput").value = "";
            }
          }

          async function uploadFile(file) {
            const relativePath = (file.webkitRelativePath || file.name)
              .replace(/\\/g, "/")
              .replace(/^\/+/, "");
            const view = createTransferView(file, "上传", relativePath);
            const controller = new AbortController();
            view.cancel.addEventListener("click", () => controller.abort(), { once: true });
            let transferID = null;
            try {
              if (file.size > Number(state.fileConfig.maximumUploadBytes)) {
                throw new Error(`文件超过 ${formatFileSize(state.fileConfig.maximumUploadBytes)} 上限`);
              }
              const sha256 = await sha256File(file, view, controller.signal);
              const started = await request("/api/files/upload/start", {
                method: "POST",
                signal: controller.signal,
                body: JSON.stringify({
                  relativePath,
                  byteCount: file.size,
                  modifiedAt: new Date(file.lastModified || Date.now()).toISOString(),
                  sha256
                })
              });
              transferID = started.transferID;
              let offset = Number(started.offset) || 0;
              const chunkBytes = Math.min(Number(started.maximumChunkBytes) || 1048576, 1048576);
              if (offset > file.size) throw new Error("Mac 返回了无效的续传位置");
              const startedAt = performance.now();

              while (offset < file.size) {
                const end = Math.min(offset + chunkBytes, file.size);
                const chunk = await file.slice(offset, end).arrayBuffer();
                const result = await request(
                  `/api/files/upload/chunk?transferID=${encodeURIComponent(transferID)}&offset=${offset}`,
                  {
                    method: "POST",
                    headers: { "Content-Type": "application/octet-stream" },
                    signal: controller.signal,
                    body: chunk
                  }
                );
                offset = Number(result.offset);
                const elapsed = Math.max((performance.now() - startedAt) / 1000, .1);
                updateTransferProgress(view, .1 + .88 * (file.size ? offset / file.size : 1), transferDetail("正在上传", offset, file.size, Math.max(offset - Number(started.offset || 0), 0) / elapsed));
              }

              const completed = await request(
                `/api/files/upload/complete?transferID=${encodeURIComponent(transferID)}`,
                { method: "POST" }
              );
              updateTransferProgress(view, 1, `已保存到 ${completed.relativePath}`, "complete");
              showToast(`${file.name} 已同步到 Mac`);
              await refreshFiles({ quiet: true });
            } catch (error) {
              if (transferID) {
                await request(
                  `/api/files/upload/cancel?transferID=${encodeURIComponent(transferID)}`,
                  { method: "POST" }
                ).catch(() => {});
              }
              const message = error.name === "AbortError" ? "上传已取消" : error.message;
              updateTransferProgress(view, 1, message, "failed");
              showToast(`${file.name}：${message}`, error.name !== "AbortError");
            } finally {
              view.cancel.disabled = true;
            }
          }

          function createTransferView(file, direction, displayName = file.name) {
            const row = document.createElement("div");
            row.className = "upload-row";
            const heading = document.createElement("div");
            heading.className = "upload-heading";
            const name = document.createElement("span");
            name.textContent = `${direction} · ${displayName}`;
            const percent = document.createElement("span");
            percent.textContent = "0%";
            heading.append(name, percent);
            const track = document.createElement("div");
            track.className = "upload-track";
            const progress = document.createElement("div");
            progress.className = "upload-progress";
            track.appendChild(progress);
            const detail = document.createElement("div");
            detail.className = "upload-detail";
            detail.textContent = direction === "上传" ? "等待校验" : "等待下载";
            const cancel = document.createElement("button");
            cancel.className = "transfer-cancel";
            cancel.type = "button";
            cancel.textContent = "取消";
            row.append(heading, track, detail, cancel);
            el("uploadList").prepend(row);
            return { row, percent, progress, detail, cancel };
          }

          function updateTransferProgress(view, ratio, detail, phase = "") {
            const percent = Math.max(0, Math.min(Math.round(ratio * 100), 100));
            view.percent.textContent = `${percent}%`;
            view.progress.style.width = `${percent}%`;
            view.detail.textContent = detail;
            view.row.classList.toggle("complete", phase === "complete");
            view.row.classList.toggle("failed", phase === "failed");
          }

          function transferDetail(label, completed, total, bytesPerSecond) {
            const remaining = Math.max(Number(total) - Number(completed), 0);
            const eta = bytesPerSecond > 0 ? Math.ceil(remaining / bytesPerSecond) : 0;
            const etaText = eta > 0 ? ` · 剩余约 ${eta < 60 ? `${eta} 秒` : `${Math.ceil(eta / 60)} 分钟`}` : "";
            return `${label} ${formatFileSize(completed)} / ${formatFileSize(total)} · ${formatFileSize(bytesPerSecond)}/s${etaText}`;
          }

          class IncrementalSHA256 {
            constructor() {
              this.hash = new Uint32Array([
                0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
              ]);
              this.buffer = new Uint8Array(64);
              this.bufferLength = 0;
              this.byteLength = 0;
            }
            update(bytes) {
              this.byteLength += bytes.length;
              let offset = 0;
              while (offset < bytes.length) {
                const copied = Math.min(64 - this.bufferLength, bytes.length - offset);
                this.buffer.set(bytes.subarray(offset, offset + copied), this.bufferLength);
                this.bufferLength += copied;
                offset += copied;
                if (this.bufferLength === 64) {
                  this.transform(this.buffer);
                  this.bufferLength = 0;
                }
              }
            }
            digestHex() {
              const bitLength = this.byteLength * 8;
              this.buffer[this.bufferLength++] = 0x80;
              if (this.bufferLength > 56) {
                this.buffer.fill(0, this.bufferLength);
                this.transform(this.buffer);
                this.bufferLength = 0;
              }
              this.buffer.fill(0, this.bufferLength, 56);
              const view = new DataView(this.buffer.buffer);
              view.setUint32(56, Math.floor(bitLength / 0x100000000), false);
              view.setUint32(60, bitLength >>> 0, false);
              this.transform(this.buffer);
              const output = new Uint8Array(32);
              const outputView = new DataView(output.buffer);
              this.hash.forEach((value, index) => outputView.setUint32(index * 4, value, false));
              return Array.from(output).map(byte => byte.toString(16).padStart(2, "0")).join("");
            }
            transform(chunk) {
              const constants = IncrementalSHA256.constants;
              const words = new Uint32Array(64);
              const source = new DataView(chunk.buffer, chunk.byteOffset, 64);
              for (let index = 0; index < 16; index += 1) words[index] = source.getUint32(index * 4, false);
              for (let index = 16; index < 64; index += 1) {
                const x = words[index - 15];
                const y = words[index - 2];
                const s0 = ((x >>> 7) | (x << 25)) ^ ((x >>> 18) | (x << 14)) ^ (x >>> 3);
                const s1 = ((y >>> 17) | (y << 15)) ^ ((y >>> 19) | (y << 13)) ^ (y >>> 10);
                words[index] = (words[index - 16] + s0 + words[index - 7] + s1) >>> 0;
              }
              let [a, b, c, d, e, f, g, h] = this.hash;
              for (let index = 0; index < 64; index += 1) {
                const s1 = ((e >>> 6) | (e << 26)) ^ ((e >>> 11) | (e << 21)) ^ ((e >>> 25) | (e << 7));
                const choose = (e & f) ^ (~e & g);
                const first = (h + s1 + choose + constants[index] + words[index]) >>> 0;
                const s0 = ((a >>> 2) | (a << 30)) ^ ((a >>> 13) | (a << 19)) ^ ((a >>> 22) | (a << 10));
                const majority = (a & b) ^ (a & c) ^ (b & c);
                const second = (s0 + majority) >>> 0;
                h = g; g = f; f = e; e = (d + first) >>> 0;
                d = c; c = b; b = a; a = (first + second) >>> 0;
              }
              this.hash[0] = (this.hash[0] + a) >>> 0;
              this.hash[1] = (this.hash[1] + b) >>> 0;
              this.hash[2] = (this.hash[2] + c) >>> 0;
              this.hash[3] = (this.hash[3] + d) >>> 0;
              this.hash[4] = (this.hash[4] + e) >>> 0;
              this.hash[5] = (this.hash[5] + f) >>> 0;
              this.hash[6] = (this.hash[6] + g) >>> 0;
              this.hash[7] = (this.hash[7] + h) >>> 0;
            }
          }
          IncrementalSHA256.constants = new Uint32Array([
            0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
            0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
            0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
            0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
            0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
            0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
            0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
            0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
          ]);

          async function sha256File(file, view, signal) {
            const hasher = new IncrementalSHA256();
            const chunkSize = 1024 * 1024;
            let offset = 0;
            while (offset < file.size) {
              if (signal.aborted) throw new DOMException("Aborted", "AbortError");
              const end = Math.min(offset + chunkSize, file.size);
              hasher.update(new Uint8Array(await file.slice(offset, end).arrayBuffer()));
              offset = end;
              updateTransferProgress(view, file.size ? .1 * offset / file.size : .1, `正在校验完整性 ${formatFileSize(offset)} / ${formatFileSize(file.size)}`);
              await new Promise(resolve => setTimeout(resolve, 0));
            }
            if (file.size === 0) updateTransferProgress(view, .1, "空文件校验完成");
            return hasher.digestHex();
          }

          async function refresh({ quiet = false } = {}) {
            if ((!isHubMode && !state.token) || state.actionBusy) return;
            try {
              const snapshot = await request("/api/status");
              applySnapshot(snapshot, "http");
            } catch (error) {
              setOffline(error.message);
              if (!quiet) showToast(error.message, true);
            }
          }

          function clearAuthentication() {
            if (isHubMode) {
              const next = `${location.pathname}${location.search}`;
              location.assign(`/?next=${encodeURIComponent(next)}`);
              return;
            }
            sessionStorage.removeItem("cwp-web-token");
            state.token = "";
            state.reconnectAllowed = false;
            state.webSocketReady = false;
            clearTimeout(state.reconnectTimer);
            if (state.socket) state.socket.close();
            state.socket = null;
            el("authOverlay").classList.add("visible");
          }

          function connectWebSocket() {
            if ((!isHubMode && !state.token) || !state.reconnectAllowed || !window.WebSocket) return;
            if (state.socket && [WebSocket.CONNECTING, WebSocket.OPEN].includes(state.socket.readyState)) return;

            clearTimeout(state.reconnectTimer);
            const scheme = location.protocol === "https:" ? "wss:" : "ws:";
            const socket = new WebSocket(`${scheme}//${location.host}${endpoint("/ws")}`);
            state.socket = socket;
            state.webSocketReady = false;
            el("footerState").textContent = "正在建立实时连接";

            socket.addEventListener("open", () => {
              if (state.socket !== socket) return;
              if (!isHubMode) {
                socket.send(JSON.stringify({ type: "authenticate", token: state.token }));
              }
            });

            socket.addEventListener("message", event => {
              if (state.socket !== socket) return;
              let message;
              try {
                message = JSON.parse(event.data);
              } catch {
                return;
              }
              if (message.type === "ready") {
                state.webSocketReady = true;
                state.reconnectAttempt = 0;
                el("footerState").textContent = "实时同步";
              } else if (message.type === "snapshot" && message.snapshot) {
                state.webSocketReady = true;
                state.reconnectAttempt = 0;
                applySnapshot(message.snapshot, "websocket");
              } else if (message.type === "error") {
                showToast(message.message || "实时连接认证失败", true);
                clearAuthentication();
              }
            });

            socket.addEventListener("close", () => {
              if (state.socket !== socket) return;
              state.socket = null;
              state.webSocketReady = false;
              if ((!isHubMode && !state.token) || !state.reconnectAllowed) return;
              setOffline("实时连接中断，正在自动重连");
              refresh({ quiet: true });
              scheduleWebSocketReconnect();
            });
          }

          function scheduleWebSocketReconnect() {
            clearTimeout(state.reconnectTimer);
            const delay = Math.min(1000 * (2 ** state.reconnectAttempt), 15000);
            state.reconnectAttempt += 1;
            state.reconnectTimer = setTimeout(connectWebSocket, delay);
          }

          function applySnapshot(snapshot, source = state.webSocketReady ? "websocket" : "http") {
            const nextFilesVersion = Number(snapshot.filesVersion);
            const filesDidChange = Number.isFinite(nextFilesVersion)
              && state.filesVersion !== null
              && nextFilesVersion !== state.filesVersion;
            if (Number.isFinite(nextFilesVersion)) state.filesVersion = nextFilesVersion;
            state.snapshot = snapshot;
            state.lastSyncAt = new Date();
            document.body.classList.remove("skeleton");
            el("onlineState").innerHTML = '<span class="dot"></span><span>Mac 在线</span>';
            el("onlineState").style.color = "var(--green)";
            el("footerState").textContent = source === "websocket" ? "实时同步" : "状态正常 · HTTP 兜底";

            baselineToggle.checked = !!snapshot.baselineClosedLid.isOn;
            baselineToggle.disabled = state.actionBusy || !snapshot.baselineClosedLid.isEnabled || snapshot.baselineClosedLid.isBusy;
            el("baselineStatus").textContent = snapshot.baselineClosedLid.status;
            el("baselineSource").textContent = snapshot.baselineClosedLid.source ? `来源：${snapshot.baselineClosedLid.source}` : "";

            const durationSelect = el("temporaryDuration");
            if (!durationSelect.dataset.dirty || snapshot.temporarySession.isOn) {
              durationSelect.value = String(snapshot.temporarySession.durationSeconds || 7200);
            }
            durationSelect.disabled = state.actionBusy || snapshot.temporarySession.isOn
              || snapshot.temporarySession.isBusy || !snapshot.temporarySession.isEnabled;
            temporaryToggle.checked = !!snapshot.temporarySession.isOn;
            temporaryToggle.disabled = state.actionBusy || !snapshot.temporarySession.isEnabled || snapshot.temporarySession.isBusy;
            el("temporaryStatus").textContent = snapshot.temporarySession.status;
            el("overrideLine").classList.toggle("visible", !!snapshot.temporarySession.overridesBaseline);

            el("batteryValue").textContent = snapshot.battery.displayName;
            const thermalWarning = ["serious", "critical", "unknown"].includes(snapshot.thermal.state);
            const temperature = Number(snapshot.thermal.temperatureCelsius);
            const hasTemperature = Number.isFinite(temperature);
            el("thermalValue").textContent = hasTemperature
              ? `${formatTemperature(temperature)} · ${snapshot.thermal.displayName}`
              : snapshot.thermal.displayName;
            el("temperatureSource").textContent = snapshot.thermal.temperatureSource
              || "温度传感器暂不可用";
            el("thermalIcon").classList.toggle("healthy", !thermalWarning);
            el("thermalIcon").classList.toggle("warning", thermalWarning);
            el("temperatureLine").classList.toggle("warning", thermalWarning);
            el("temperatureCurrentDot").classList.toggle("warning", thermalWarning);
            renderTemperatureHistory(snapshot.thermal, snapshot.observedAt);

            const duration = formatDuration(snapshot.network.connectedDurationSeconds);
            el("networkValue").textContent = snapshot.network.isConnected
              ? `${snapshot.network.displayName} · ${duration}`
              : "离线 · 等待恢复";
            el("networkIcon").classList.toggle("warning", !snapshot.network.isConnected);

            el("remoteValue").textContent = snapshot.remoteControl.status;
            el("remoteIcon").classList.toggle("healthy", snapshot.remoteControl.isConnected);
            el("remoteIcon").classList.toggle("warning", !snapshot.remoteControl.isConnected);
            applyScreenLockSettings(snapshot.screenLock);

            el("interfaceValue").textContent = snapshot.network.interfaceName || snapshot.network.displayName;
            el("durationValue").textContent = duration;
            el("hotspotValue").textContent = hotspotShortName(snapshot.hotspot.phase);
            const target = snapshot.hotspot.targetName ? `目标：${snapshot.hotspot.targetName}` : "尚未配置目标热点";
            el("networkNote").textContent = `${snapshot.network.detail}；${target}；${snapshot.hotspot.status}`;
            renderActivities(snapshot.activities || []);
            updateClocks();
            if (filesDidChange) refreshFiles({ quiet: true });
          }

          function formatTemperature(value) {
            return `${Number(value).toFixed(1)}°C`;
          }

          function renderTemperatureHistory(thermal, observedAt) {
            const chartWidth = 360;
            const chartTop = 8;
            const chartBottom = 70;
            const intervalMs = Math.max(Number(thermal.sampleIntervalSeconds) || 60, 1) * 1000;
            const windowMs = Math.max(Number(thermal.historyWindowSeconds) || 43200, 60) * 1000;
            const observedTime = new Date(observedAt).getTime();
            const windowEnd = Number.isFinite(observedTime) ? observedTime : Date.now();
            const windowStart = windowEnd - windowMs;
            const points = (Array.isArray(thermal.history) ? thermal.history : [])
              .map(point => ({
                time: new Date(point.recordedAt).getTime(),
                celsius: Number(point.celsius)
              }))
              .filter(point => Number.isFinite(point.time)
                && Number.isFinite(point.celsius)
                && point.time >= windowStart
                && point.time <= windowEnd + intervalMs)
              .sort((left, right) => left.time - right.time);

            const line = el("temperatureLine");
            const currentDot = el("temperatureCurrentDot");
            if (!points.length) {
              line.setAttribute("d", "");
              currentDot.setAttribute("hidden", "");
              el("temperatureRange").textContent = "暂无数据";
              el("temperatureHistoryStatus").textContent = "正在积累分钟采样";
              el("temperatureChartTitle").textContent = "过去 12 小时温度曲线，暂无有效温度采样";
              return;
            }

            const temperatures = points.map(point => point.celsius);
            const observedMinimum = Math.min(...temperatures);
            const observedMaximum = Math.max(...temperatures);
            const midpoint = (observedMinimum + observedMaximum) / 2;
            const span = Math.max(observedMaximum - observedMinimum, 6);
            const yMinimum = midpoint - span / 2 - 1;
            const yMaximum = midpoint + span / 2 + 1;
            const xFor = time => Math.max(0, Math.min(
              chartWidth,
              ((time - windowStart) / windowMs) * chartWidth
            ));
            const yFor = celsius => chartBottom - (
              ((celsius - yMinimum) / (yMaximum - yMinimum))
                * (chartBottom - chartTop)
            );

            let path = "";
            let previousTime = null;
            for (const point of points) {
              const command = previousTime === null
                || point.time - previousTime > intervalMs * 2.2
                ? "M"
                : "L";
              path += `${command}${xFor(point.time).toFixed(2)},${yFor(point.celsius).toFixed(2)} `;
              previousTime = point.time;
            }
            line.setAttribute("d", path.trim());

            const latest = points[points.length - 1];
            currentDot.setAttribute("cx", xFor(latest.time).toFixed(2));
            currentDot.setAttribute("cy", yFor(latest.celsius).toFixed(2));
            currentDot.removeAttribute("hidden");
            el("temperatureRange").textContent = `${formatTemperature(observedMinimum)}–${formatTemperature(observedMaximum)}`;
            el("temperatureHistoryStatus").textContent = points.length === 1
              ? "已记录 1 个分钟点"
              : `已记录 ${points.length} 个分钟点`;
            el("temperatureChartTitle").textContent = `过去 12 小时温度曲线，最低 ${formatTemperature(observedMinimum)}，最高 ${formatTemperature(observedMaximum)}，共 ${points.length} 个分钟采样`;
          }

          function renderActivities(activities) {
            const list = el("activityList");
            list.replaceChildren();
            if (!activities.length) {
              const empty = document.createElement("div");
              empty.className = "activity-empty";
              empty.textContent = "暂无状态变化，控制台正在持续监测。";
              list.appendChild(empty);
              return;
            }
            for (const activity of activities) {
              const row = document.createElement("div");
              row.className = "activity-row";
              const time = document.createElement("div");
              time.className = "activity-time";
              time.textContent = formatTime(activity.createdAt);
              const dot = document.createElement("div");
              dot.className = `activity-dot ${activity.accent || "neutral"}`;
              const content = document.createElement("div");
              const title = document.createElement("div");
              title.className = "activity-title";
              title.textContent = activity.title;
              content.appendChild(title);
              if (activity.detail) {
                const detail = document.createElement("div");
                detail.className = "activity-detail";
                detail.textContent = activity.detail;
                content.appendChild(detail);
              }
              row.append(time, dot, content);
              list.appendChild(row);
            }
          }

          function setOffline(message) {
            el("onlineState").innerHTML = '<span class="dot"></span><span>连接中断</span>';
            el("onlineState").style.color = "var(--amber)";
            el("footerState").textContent = "等待重连";
            el("syncAge").textContent = message || "同步失败";
          }

          function updateClocks() {
            if (state.lastSyncAt) {
              const age = Math.max((Date.now() - state.lastSyncAt.getTime()) / 1000, 0);
              el("syncAge").textContent = state.webSocketReady && age < 4
                ? "WebSocket 实时同步"
                : (age < 4 ? "刚刚同步" : `${Math.floor(age)} 秒前同步`);
            }
            const snapshot = state.snapshot;
            if (!snapshot) return;
            if (snapshot.network.connectedAt && snapshot.network.isConnected) {
              const seconds = Math.max((Date.now() - new Date(snapshot.network.connectedAt).getTime()) / 1000, 0);
              const value = formatDuration(seconds);
              el("durationValue").textContent = value;
              el("networkValue").textContent = `${snapshot.network.displayName} · ${value}`;
            }
            if (snapshot.temporarySession.expiresAt && snapshot.temporarySession.isOn) {
              const remaining = Math.max((new Date(snapshot.temporarySession.expiresAt).getTime() - Date.now()) / 1000, 0);
              el("temporaryTimer").textContent = `剩余 ${formatDuration(remaining)}`;
            } else {
              el("temporaryTimer").textContent = "";
            }
            if (snapshot.screenLock?.pendingLidCloseLockAt) {
              const remaining = Math.max(
                Math.ceil(
                  (new Date(snapshot.screenLock.pendingLidCloseLockAt).getTime() - Date.now())
                    / 1000
                ),
                0
              );
              el("lidCloseLockStatus").textContent = remaining > 0
                ? `显示器已请求立即关闭 · 剩余 ${formatDuration(remaining)} 后锁定`
                : "正在锁定屏幕";
            }
          }

          function formatDuration(value) {
            if (value === null || value === undefined || !Number.isFinite(Number(value))) return "—";
            const total = Math.max(Math.floor(Number(value)), 0);
            const hours = Math.floor(total / 3600);
            const minutes = Math.floor((total % 3600) / 60);
            const seconds = total % 60;
            return [hours, minutes, seconds].map(part => String(part).padStart(2, "0")).join(":");
          }

          function formatTime(value) {
            const date = new Date(value);
            if (Number.isNaN(date.getTime())) return "—";
            return new Intl.DateTimeFormat("zh-CN", {
              hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false
            }).format(date);
          }

          function hotspotShortName(phase) {
            const values = {
              stopped: "待命",
              monitoring: "监测中",
              confirmingFailure: "确认断线",
              reconnecting: "重连中",
              waitingForConnectivity: "等待网络",
              backingOff: "低频重试"
            };
            return values[phase] || phase || "—";
          }

          async function performAction(action, enabled) {
            if (state.actionBusy) return;
            const durationSeconds = Number(el("temporaryDuration").value);
            const prompt = action === "setBaselineClosedLid"
              ? (enabled
                  ? "开启系统级合盖运行？如果尚未安装受限系统助手，Mac 会请求一次管理员验证；后续切换不再询问密码。"
                  : "关闭合盖运行后，Mac 合盖可能进入睡眠。确认继续？")
              : (enabled
                  ? `启动移动办公 ${durationSeconds / 60} 分钟？自动连接热点并保护已解锁的桌面，到期恢复合盖配置。系统锁屏设置保持不变，请保持电脑通风。`
                  : "停止随行会话并恢复启动前配置？");
            if (!window.confirm(prompt)) {
              applySnapshot(state.snapshot);
              return;
            }

            state.actionBusy = true;
            applySnapshot(state.snapshot);
            el("footerState").textContent = "正在执行";
            try {
              const result = await request("/api/action", {
                method: "POST",
                body: JSON.stringify({ action, enabled,
                  ...(action === "setTemporaryTwoHourSession" && enabled ? { durationSeconds, mobileOffice: true } : {})
                })
              });
              if (result.ok) delete el("temporaryDuration").dataset.dirty;
              applySnapshot(result.snapshot);
              showToast(result.message, !result.ok);
            } catch (error) {
              if (error.payload && error.payload.snapshot) applySnapshot(error.payload.snapshot);
              showToast(error.message, true);
            } finally {
              state.actionBusy = false;
              if (state.snapshot) applySnapshot(state.snapshot);
              if (!state.webSocketReady) refresh({ quiet: true });
            }
          }

          async function saveScreenLockSettings() {
            if (state.screenLockBusy) return;
            const update = {
              batteryDisplaySleepMinutes: Number(el("lockBatteryMinutes").value),
              powerAdapterDisplaySleepMinutes: Number(el("lockPowerMinutes").value),
              passwordDelaySeconds: Number(el("lockPasswordDelay").value) < 0
                ? null
                : Number(el("lockPasswordDelay").value),
              lidCloseLockDelaySeconds: Number(el("lockLidCloseDelay").value) < 0
                ? null
                : Number(el("lockLidCloseDelay").value)
            };
            const displayWarning = update.batteryDisplaySleepMinutes === 0
              || update.powerAdapterDisplaySleepMinutes === 0
              ? "其中一个电源场景将永不自动关闭屏幕。"
              : "";
            const confirmed = window.confirm(
              `保存显示器与合盖锁屏配置？${displayWarning}锁屏密码策略保持当前值；显示器策略首次修改或助手升级时，Mac 可能弹出一次管理员授权。`
            );
            if (!confirmed) return;

            state.screenLockBusy = true;
            setScreenLockControlsDisabled(true);
            el("lockSettingsStatus").textContent = "正在写入并回读 macOS 实际配置…";
            try {
              const result = await request("/api/screen-lock", {
                method: "POST",
                body: JSON.stringify(update)
              });
              if (state.snapshot) state.snapshot.screenLock = result.settings;
              applyScreenLockSettings(result.settings);
              showToast(result.message, !result.ok);
            } catch (error) {
              if (error.payload?.settings) {
                if (state.snapshot) state.snapshot.screenLock = error.payload.settings;
                applyScreenLockSettings(error.payload.settings);
              }
              showToast(error.message, true);
            } finally {
              state.screenLockBusy = false;
              if (state.snapshot?.screenLock) applyScreenLockSettings(state.snapshot.screenLock);
              if (!state.webSocketReady) refresh({ quiet: true });
            }
          }

          baselineToggle.addEventListener("change", event => {
            performAction("setBaselineClosedLid", event.target.checked);
          });
          temporaryToggle.addEventListener("change", event => {
            performAction("setTemporaryTwoHourSession", event.target.checked);
          });
          el("lockSettingsSave").addEventListener("click", saveScreenLockSettings);
          el("fileRefreshButton").addEventListener("click", () => refreshFiles());
          el("fileSearch").addEventListener("input", () => {
            state.fileRenderLimit = 200;
            renderFiles();
          });
          el("uploadFileButton").addEventListener("click", () => el("fileInput").click());
          el("uploadMediaButton").addEventListener("click", () => el("mediaInput").click());
          el("uploadDirectoryButton").addEventListener("click", () => el("directoryInput").click());
          el("fileInput").addEventListener("change", event => uploadSelectedFiles(event.target.files));
          el("mediaInput").addEventListener("change", event => uploadSelectedFiles(event.target.files));
          el("directoryInput").addEventListener("change", event => uploadSelectedFiles(event.target.files));
          document.querySelectorAll("[data-tab]").forEach(button => {
            button.addEventListener("click", () => activatePage(button.dataset.tab));
          });
          el("previewClose").addEventListener("click", closePreview);
          el("previewOverlay").addEventListener("click", event => {
            if (event.target === el("previewOverlay")) closePreview();
          });
          el("previewDownload").addEventListener("click", () => {
            const file = state.previewFile;
            closePreview();
            if (file) downloadFile(file, null);
          });
          el("authForm").addEventListener("submit", event => {
            event.preventDefault();
            const token = el("tokenInput").value.trim();
            if (!token) return;
            state.token = token;
            sessionStorage.setItem("cwp-web-token", token);
            state.reconnectAllowed = true;
            state.reconnectAttempt = 0;
            el("authOverlay").classList.remove("visible");
            refresh();
            refreshFiles();
            connectWebSocket();
          });
          document.addEventListener("visibilitychange", () => {
            if (!document.hidden) {
              connectWebSocket();
              if (!state.webSocketReady) refresh({ quiet: true });
              refreshFiles({ quiet: true });
            }
          });

          loadToken();
          activatePage(sessionStorage.getItem("cwp-active-page") || "overview");
          document.body.classList.add("skeleton");
          refresh();
          refreshFiles();
          connectWebSocket();
          state.fallbackTimer = setInterval(() => {
            if (!state.webSocketReady) refresh({ quiet: true });
          }, 30000);
          state.fileRefreshTimer = setInterval(() => refreshFiles({ quiet: true }), 30000);
          state.clockTimer = setInterval(updateClocks, 1000);
        })();
      </script>
    </body>
    </html>
    """#
}
