<?php
/* Shared CI Runner Farm web core — the crf* JS helpers, the @unraid/ui force-loader,
   and the shared .crf-* styles used by every RunnerFarm screen. include_once'd from
   the top of each page so the dependency is EXPLICIT
   and load-order-independent, instead of living inside the Fleet tab and being
   relied on by document order (renaming crfPost or reordering the tab ordinals used
   to silently break the other tabs). Emitted once per document via include_once.
   Runs in the tab's scope, so $var (the CSRF token) is available. */
require_once '/usr/local/emhttp/plugins/ci-runner-farm/include/crf-frame.php';
$crf_csrf = $var['csrf_token'] ?? '';
$crf_uui_base = '/plugins/dynamix.my.servers/unraid-components/uui/';
$crf_util_css = '';
foreach (glob('/usr/local/emhttp/plugins/dynamix.my.servers/unraid-components/standalone/standalone-apps-*.css') ?: [] as $f) {
  $crf_util_css = '/plugins/dynamix.my.servers/unraid-components/standalone/' . basename($f);
  break;
}
if (!function_exists('crf_render_shell')) {
  /** Render the product-local navigation shared by every CI Runner Farm screen. */
  function crf_render_shell(string $active = 'runners', string $settings_tab = ''): void {
    $primary = [
      'runners' => ['Runners', crf_frame_url('/Utilities/RunnerFarm/RunnerFarmFleet'), 'fa-server'],
      'history' => ['History', crf_frame_url('/Utilities/RunnerFarm/RunnerFarmHistory'), 'fa-history'],
      'logs' => ['Logs', crf_frame_url('/Utilities/RunnerFarm/RunnerFarmLogs'), 'fa-file-text-o'],
      'settings' => ['Settings', crf_frame_url('/Utilities/RunnerFarm/RunnerFarmSettings'), 'fa-cog'],
    ];
    $secondary = [
      'general' => ['General', crf_frame_url('/Utilities/RunnerFarm/RunnerFarmSettings')],
      'pools' => ['Pools', crf_frame_url('/Utilities/RunnerFarm/RunnerFarmPools')],
      'image' => ['Runner image', crf_frame_url('/Utilities/RunnerFarm/RunnerFarmImage')],
    ];
    ?>
    <header class="crf-app-header">
      <div class="crf-app-brand-rail" aria-hidden="true"></div>
      <div class="crf-app-header-inner">
        <a class="crf-app-brand" href="<?=htmlspecialchars(crf_frame_url('/Utilities/RunnerFarm/RunnerFarmFleet'), ENT_QUOTES)?>" aria-label="CI Runner Farm runners">
          <span class="crf-app-brand-icon" aria-hidden="true"><img src="/plugins/ci-runner-farm/assets/icons/brand-server.svg" alt=""></span>
          <span class="crf-app-brand-copy"><strong>Runner Farm</strong><small>ci-runner-farm</small></span>
        </a>
        <span class="crf-app-status crf-app-status-neutral" id="crf-shell-status" role="status">
          <span class="crf-app-status-dot" aria-hidden="true"></span>
          <span id="crf-shell-status-label">Connecting&hellip;</span>
        </span>
        <nav class="crf-primary-nav" aria-label="CI Runner Farm">
          <?php foreach ($primary as $key => [$label, $href, $icon]): ?>
            <a class="crf-primary-tab<?= $active === $key ? ' is-active' : '' ?>"
               href="<?=htmlspecialchars($href, ENT_QUOTES)?>"
               <?= $active === $key ? 'aria-current="page"' : '' ?>
               data-crf-primary-key="<?=htmlspecialchars($key, ENT_QUOTES)?>"
               data-rf-tab-label>
              <i class="fa <?=$icon?> crf-primary-icon" aria-hidden="true"></i>
              <span class="crf-primary-label"><?=$label?></span>
              <?php if ($key === 'runners'): ?><span class="crf-primary-count" id="crf-shell-count">&ndash;</span><?php endif; ?>
            </a>
          <?php endforeach; ?>
        </nav>
      </div>
    </header>
    <?php if ($active === 'settings'): ?>
      <nav class="crf-settings-nav" aria-label="Settings sections">
        <?php foreach ($secondary as $key => [$label, $href]): ?>
          <a class="crf-settings-tab<?= $settings_tab === $key ? ' is-active' : '' ?>"
             href="<?=htmlspecialchars($href, ENT_QUOTES)?>"
             <?= $settings_tab === $key ? 'aria-current="page"' : '' ?>><?=$label?></a>
        <?php endforeach; ?>
      </nav>
    <?php endif; ?>
    <?php
  }
}
?>
<style>
  :root{--crf-ok:#63a659;--crf-busy:#ff8c2f;--crf-err:#e22828;--crf-info:var(--link-text-color,#29b6f6);--crf-bg:#f2f2f2;--crf-panel:#fff;--crf-panel-soft:#fafafa;--crf-ink:#1c1b1b;--crf-ink-2:#525252;--crf-ink-3:#737373;--crf-ink-4:#a3a3a3;--crf-border:#e5e5e5;--crf-border-soft:#f0f0f0;--crf-orange-soft:#ffedd5;--crf-orange-ink:#9a3412;--crf-success-soft:#d0e6cc;--crf-success-ink:#314e2d;--crf-warning-soft:#fef9c3;--crf-warning-ink:#8a6914;--crf-error-soft:#ffe1e1;--crf-error-ink:#9c1818;--crf-shadow:0 4px 6px -1px rgba(0,0,0,.08)}
  body:has(.crf-app-header){background:var(--crf-bg);color:var(--crf-ink);font-family:clear-sans,ui-sans-serif,system-ui,sans-serif}
  body:has(.crf-app-header) #header,body:has(.crf-app-header) #menu,body:has(.crf-app-header) #footer{display:none!important}
  body:has(.crf-app-header) #displaybox{width:100%!important;max-width:none!important;margin:0!important;padding:0!important}
  body:has(.crf-app-header) #displaybox>.content{width:100%!important;margin:0!important;padding:0!important;overflow:visible!important}
  body:has(.crf-app-header) #displaybox>.content>div.title{display:none!important;margin:0!important;padding:0!important}
  .crf-app-header,.crf-app-header *,.crf-app-main,.crf-app-main *,.crf-settings-nav,.crf-settings-nav *{box-sizing:border-box}
  .crf-app-header{position:relative;width:100vw;margin-left:calc(50% - 50vw);background:#fff;border-bottom:1px solid var(--crf-border);box-shadow:0 1px 2px rgba(0,0,0,.04);z-index:20}
  .crf-app-brand-rail{height:3px;background:linear-gradient(90deg,#e22828,#ff8c2f)}
  .crf-app-header-inner{height:60px;max-width:1440px;margin:0 auto;padding:0 20px;display:flex;align-items:center;gap:14px}
  .crf-app-brand{display:flex;align-items:center;gap:10px;min-width:0;color:var(--crf-ink)!important;text-decoration:none!important}
  .crf-app-brand-icon{width:32px;height:32px;border-radius:7px;background:var(--crf-orange-soft);color:var(--crf-orange-ink);display:grid;place-items:center;flex:none;font-size:14px}
  .crf-app-brand-icon img{display:block;width:16px;height:16px}
  .crf-app-brand-copy{display:flex;flex-direction:column;min-width:0;line-height:1.15}
  .crf-app-brand-copy strong{font-size:16px;font-weight:600;white-space:nowrap}
  .crf-app-brand-copy small{font:10.5px/1.15 ui-monospace,Menlo,monospace;color:var(--crf-ink-4);white-space:nowrap}
  .crf-app-status{display:inline-flex;align-items:center;gap:6px;border-radius:9999px;font-size:12px;font-weight:600;padding:4px 10px;white-space:nowrap}
  .crf-app-status-dot{width:7px;height:7px;border-radius:50%;background:currentColor;flex:none}
  .crf-app-status-neutral{background:#e5e5e5;color:var(--crf-ink-2)}
  .crf-app-status-idle{background:var(--crf-success-soft);color:var(--crf-success-ink)}
  .crf-app-status-busy{background:var(--crf-orange-soft);color:var(--crf-orange-ink)}
  .crf-app-status-down{background:var(--crf-error-soft);color:var(--crf-error-ink)}
  .crf-primary-nav{margin-left:auto;display:inline-flex;align-items:center;border-radius:6px;background:#e5e5e5;padding:5px;gap:2px;max-width:100%;overflow-x:auto}
  .crf-primary-tab{position:relative;display:inline-flex;align-items:center;gap:6px;justify-content:center;border-radius:6px;padding:6px 14px;color:var(--crf-ink)!important;font-size:14px;font-weight:500;text-decoration:none!important;white-space:nowrap;transition:background .15s,color .15s}
  .crf-primary-tab:hover{background:#f5f5f5;text-decoration:none!important}
  .crf-primary-tab.is-active{background:#ff6600;color:#fff!important}
  .crf-primary-tab.has-dirty::after{content:"";position:absolute;top:4px;right:5px;width:6px;height:6px;border-radius:50%;background:#e9bf41}
  .crf-primary-count{font-size:10.5px;font-weight:700;font-variant-numeric:tabular-nums;border-radius:9999px;padding:1px 7px;background:#d4d4d4;color:var(--crf-ink-2)}
  .crf-primary-tab.is-active .crf-primary-count{background:rgba(255,255,255,.25);color:#fff}
  .crf-settings-nav{width:max-content;max-width:calc(100vw - 40px);min-height:36px;margin:20px 0 0 max(20px,calc((100vw - 1440px)/2));display:flex;align-items:center;border-radius:6px;background:#e5e5e5;padding:4px;gap:2px}
  .crf-settings-tab{display:inline-flex;align-items:center;justify-content:center;padding:5px 14px;border-radius:5px;color:var(--crf-ink-3)!important;font-size:13px;font-weight:600;text-decoration:none!important;white-space:nowrap}
  .crf-settings-tab:hover{color:var(--crf-ink)!important;text-decoration:none!important}
  .crf-settings-tab.is-active{background:#fff;color:var(--crf-ink)!important;box-shadow:0 1px 2px rgba(0,0,0,.04)}
  .crf-app-main{width:calc(100vw - 40px);max-width:1440px;margin:0 auto;padding:20px 0;display:flex;flex-direction:column;gap:16px;color:var(--crf-ink)}
  .crf-settings-nav + .crf-app-main{padding-top:16px}
  .crf-surface{background:var(--crf-panel);border:2px solid #f5f5f5;border-radius:6px;box-shadow:var(--crf-shadow);overflow:hidden}
  .crf-page-hero{display:flex;align-items:flex-end;justify-content:space-between;gap:16px;padding:20px 24px 16px;min-height:99px;flex-wrap:wrap}
  .crf-eyebrow{display:block;font-size:11px;font-weight:700;letter-spacing:.085em;text-transform:uppercase;color:var(--crf-ink-2)}
  .crf-page-title{margin:6px 0 0;font-size:26px;line-height:normal;font-weight:600;letter-spacing:-.02em;color:var(--crf-ink)}
  .crf-page-actions{display:flex;align-items:center;gap:8px;flex-wrap:wrap}
  :is(button,input).crf-button{appearance:none;box-sizing:border-box;min-width:0;height:34px;margin:0;padding:0 16px;display:inline-flex;align-items:center;justify-content:center;gap:6px;border-radius:6px;border:1px solid #d4d4d4;background:#fff;color:var(--crf-ink);font:600 13px/1 clear-sans,ui-sans-serif,system-ui,sans-serif;letter-spacing:normal;text-align:center;text-transform:none;cursor:pointer;text-decoration:none!important;white-space:nowrap;transition:background .15s,border-color .15s,box-shadow .15s}
  :is(button,input).crf-button:hover{background:#f5f5f5;text-decoration:none!important}
  .crf-button.crf-button-primary{background:#ff5a1f;border-color:#ff5a1f;color:#fff!important;box-shadow:0 2px 4px rgba(226,40,40,.18)}
  .crf-button.crf-button-primary:hover{background:#e94e17;border-color:#e94e17}
  .crf-button.crf-button-dark{background:#1c1b1b;border-color:#1c1b1b;color:#fff!important}
  .crf-button.crf-button-dark:hover{background:#383735;border-color:#383735}
  .crf-button.crf-button-compact{height:28px;padding:0 12px;font-size:12px}
  .crf-button.crf-icon-button{width:34px;min-width:34px;padding:0}
  .crf-filter-chip{height:25px;padding:0 13px;border-radius:9999px;border:1px solid var(--crf-border);background:#fff;color:var(--crf-ink-3);font:600 11.5px/1 clear-sans,ui-sans-serif,system-ui,sans-serif;cursor:pointer}
  .crf-filter-chip.is-active{border-color:transparent;background:#e5e5e5;color:var(--crf-ink)}
  .crf-input,.crf-select{height:36px;border:1px solid #d4d4d4;border-radius:6px;background:#fff;color:var(--crf-ink);padding:0 12px;font:13.5px clear-sans,ui-sans-serif,system-ui,sans-serif}
  .crf-input::placeholder{color:var(--crf-ink-4)}
  .crf-section-label{font-size:11px;font-weight:700;letter-spacing:.085em;text-transform:uppercase;color:var(--crf-ink-2)}
  .crf-mono{font-family:ui-monospace,Menlo,monospace}
  .crf-app-header :focus-visible,.crf-settings-nav :focus-visible,.crf-app-main button:focus-visible,.crf-app-main input:focus-visible,.crf-app-main select:focus-visible,.crf-app-main textarea:focus-visible,.crf-app-main [tabindex]:focus-visible{outline:2px solid #ff6600;outline-offset:2px}
  .crf-primary-icon{display:none}
  @media(max-width:760px){
    body:has(.crf-app-header){padding-bottom:calc(74px + env(safe-area-inset-bottom,0px));overflow-x:hidden}
    .crf-app-header{position:sticky;top:0;z-index:80;width:100%;margin-left:0}
    .crf-app-brand-rail{height:2px}
    .crf-app-header-inner{height:56px;padding:0 14px;gap:10px}
    .crf-app-brand{flex:1;min-width:0;min-height:44px}
    .crf-app-brand-icon{width:36px;height:36px;border-radius:10px}
    .crf-app-brand-icon img{width:18px;height:18px}
    .crf-app-brand-copy strong{font-size:17px}
    .crf-app-brand-copy small{display:none}
    .crf-app-status{max-width:42vw;padding:4px 9px;font-size:11px;overflow:hidden;text-overflow:ellipsis}
    .crf-primary-nav{position:fixed;left:0;right:0;bottom:0;z-index:100;width:100%;height:calc(66px + env(safe-area-inset-bottom,0px));margin:0;padding:6px 8px calc(6px + env(safe-area-inset-bottom,0px));display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:2px;border:1px solid rgba(0,0,0,.08);border-bottom:0;border-radius:18px 18px 0 0;background:rgba(255,255,255,.96);box-shadow:0 -8px 24px rgba(0,0,0,.12);overflow:visible;backdrop-filter:blur(14px);-webkit-backdrop-filter:blur(14px)}
    .crf-primary-tab{min-width:0;height:52px;padding:5px 2px;display:flex;flex-direction:column;gap:3px;border-radius:11px;font-size:10.5px;font-weight:600;color:var(--crf-ink-2)!important}
    .crf-primary-tab:hover{background:#fff7ed}
    .crf-primary-tab.is-active{background:var(--crf-orange-soft);color:#e94e17!important}
    .crf-primary-icon{display:block;font-size:18px;line-height:1}
    .crf-primary-label{max-width:100%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    .crf-primary-count{position:absolute;top:3px;left:calc(50% + 7px);min-width:17px;padding:1px 5px;background:#e5e5e5;color:var(--crf-ink-2);font-size:9px;text-align:center}
    .crf-primary-tab.is-active .crf-primary-count{background:#fff;color:#e94e17}
    .crf-app-main{width:calc(100vw - 24px);max-width:none;margin:0 auto;padding:12px 0 calc(18px + env(safe-area-inset-bottom,0px));gap:12px}
    .crf-settings-nav{position:sticky;top:56px;z-index:70;width:calc(100vw - 24px);max-width:none;min-height:46px;margin:12px auto 0;padding:4px;display:grid;grid-template-columns:repeat(3,minmax(max-content,1fr));overflow-x:auto;box-shadow:0 4px 12px rgba(0,0,0,.08)}
    .crf-settings-tab{min-height:44px;padding:8px 12px;font-size:12px}
    .crf-settings-nav + .crf-app-main{padding-top:12px}
    .crf-surface{border-width:1px;border-radius:12px;box-shadow:0 3px 10px rgba(0,0,0,.07)}
    .crf-page-hero{min-height:0;padding:16px;align-items:center;gap:12px}
    .crf-page-title{font-size:24px;line-height:1.15}
    .crf-page-actions{gap:8px;flex-wrap:nowrap}
    :is(button,input).crf-button{min-height:44px;height:44px;padding:0 14px;font-size:13px}
    .crf-button.crf-button-compact{min-height:40px;height:40px;padding:0 12px}
    .crf-button.crf-icon-button{width:44px;min-width:44px;padding:0}
    .crf-filter-chip{min-width:44px;height:38px;padding:0 13px;font-size:12px}
    .crf-input,.crf-select{height:44px;font-size:16px}
    .crf-banner{padding:12px 14px;font-size:13px}
    .crf-toast{right:12px;bottom:calc(78px + env(safe-area-inset-bottom,0px));max-width:calc(100vw - 24px)}
  }
  @media(max-width:390px){
    .crf-app-status{display:none}
    .crf-app-brand-copy strong{font-size:16px}
    .crf-primary-tab{font-size:10px}
  }
  .crf-muted{color:var(--alt-text-color)}
  .crf-banner{margin:6px 0 8px;padding:10px 12px;border-radius:6px;font-size:13px;line-height:1.4}
  .crf-banner-sec{border:1px solid var(--crf-busy);background:color-mix(in srgb,var(--crf-busy) 12%,var(--background-color));color:var(--text-color);font-weight:bold}
  .crf-banner-warn{border:1px solid var(--crf-err);background:color-mix(in srgb,var(--crf-err) 12%,var(--background-color));color:var(--text-color)}
  .crf-banner-info{border:1px solid var(--crf-info);background:color-mix(in srgb,var(--crf-info) 10%,var(--background-color));color:var(--text-color)}
  uui-button:not(:defined),uui-brand-button:not(:defined){cursor:pointer;border:1px solid var(--border-color);border-radius:6px;padding:5px 12px;font-size:13px;color:var(--text-color)}
  uui-button:not([variant]):not(:defined){background:var(--crf-busy);border-color:var(--crf-busy);color:#fff;font-weight:600}
  .crf-toast{position:fixed;right:18px;bottom:48px;z-index:9999;background:var(--inverse-background-color,#222);color:var(--inverse-text-color,#fff);border:1px solid var(--border-color);border-radius:6px;padding:9px 16px;font-size:13px;opacity:0;transform:translateY(6px);transition:opacity .2s,transform .2s;pointer-events:none}
  .crf-toast-show{opacity:1;transform:none}
  .crf-ball{width:12px;height:12px;border-radius:50%;background:var(--disabled-text-color,#888);display:inline-block}
  .crf-ball-idle{background:var(--crf-ok)}
  .crf-ball-busy{background:var(--crf-busy);animation:crf-pulse 1.6s ease-in-out infinite}
  .crf-ball-error{background:var(--crf-err)}
  .crf-ball-starting{animation:crf-pulse 1.1s ease-in-out infinite}
  .crf-phase uui-badge:not(:defined){font-size:11px;color:var(--alt-text-color)}
  .crf-console{border:1px solid var(--border-color);border-radius:6px;overflow:hidden;margin:0 0 8px}
  .crf-console-head{display:flex;align-items:center;justify-content:space-between;padding:3px 6px 3px 12px;min-height:30px;box-sizing:border-box;background:var(--table-header-background-color);font-size:11px;color:var(--alt-text-color)}
  .crf-lg-dim{color:var(--alt-text-color)}
  .crf-lg-ok{color:var(--crf-ok)}
  .crf-lg-warn{color:var(--crf-busy)}
  .crf-lg-err{color:var(--crf-err)}
  .crf-console-body{white-space:pre-wrap;font-family:bitstream,monospace;font-size:12px;line-height:1.5;min-height:90px;max-height:200px;overflow:auto;background:var(--shade-bg-color,var(--background-color));color:var(--text-color);padding:6px 10px}
  .crf-builder-wrap textarea{width:100%;font-family:bitstream,monospace;font-size:12px;background:var(--input-bg-color);color:var(--text-color);border:1px solid var(--textarea-border-color,var(--input-border-color))}
  @keyframes crf-pulse{0%,100%{opacity:1}50%{opacity:.35}}
  @media (prefers-reduced-motion:reduce){.crf-ball-busy,.crf-ball-starting{animation:none}}
</style>
<script>
const CRF_CSRF = <?=json_encode($crf_csrf, JSON_HEX_TAG|JSON_HEX_AMP|JSON_HEX_APOS|JSON_HEX_QUOT)?>;
const CRF_EMBEDDED = <?=crf_is_embedded() ? 'true' : 'false'?>;
const CRF_URL  = "/plugins/ci-runner-farm/include/exec.php";
const CRF_UUI_BASE = "<?=$crf_uui_base?>";
const CRF_UTIL_CSS = "<?=$crf_util_css?>";
function crfDark(){ return /Theme--(black|gray)\b/.test(document.documentElement.className); }
/* Force-register @unraid/ui (see header comment). Resolves both hashed asset
   names at runtime; merges the standalone Tailwind utilities (which the uui
   bundle ships without) with the uui tokens, rescoped for shadow DOM. */
window.CRF_UUI = (async () => {
  try {
    // Fetch the manifest and the standalone utility CSS concurrently: the util CSS URL is
    // resolved server-side (PHP glob) and doesn't depend on the manifest, so there's no
    // reason to await one before starting the other. Cuts a round-trip off first paint.
    const [man, utilCss] = await Promise.all([
      fetch(CRF_UUI_BASE + 'ui.manifest.json').then(r => r.json()),
      CRF_UTIL_CSS ? fetch(CRF_UTIL_CSS).then(r => r.text()) : Promise.resolve('')
    ]);
    // Distinguish a manifest SHAPE change (bundle updated, entries renamed) from an
    // absent bundle (fetch throws -> outer catch), so a future @unraid/ui update logs
    // an actionable message rather than a generic "unavailable".
    if (!(man['style.css'] && man['style.css'].file && man['src/register.ts'] && man['src/register.ts'].file)) {
      console.warn('ci-runner-farm: @unraid/ui manifest shape changed (style.css/register.ts entries missing) — bundle updated; using fallback. Update the crf-core.php loader.');
      return false;
    }
    // The uui stylesheet and the register.ts module are independent — fetch the CSS and
    // import the module concurrently, then merge + rescope for shadow DOM and register.
    const [uuiCss, mod] = await Promise.all([
      fetch(CRF_UUI_BASE + man['style.css'].file).then(r => r.text()),
      import(CRF_UUI_BASE + man['src/register.ts'].file)
    ]);
    const css = [utilCss, uuiCss].filter(Boolean).join('\n')
      .replace(/\.unapi\.dark\b/g, ':host(.dark)')
      .replace(/\.unapi\b/g, ':host')
      .replace(/:root\b/g, ':host')
      .replace(/\.dark\b/g, ':host(.dark)')
      + '\n:host([size="xs"]) .inline-flex{font-size:12px;line-height:1.2;padding:3px 10px;gap:4px}'
      + '\n:host(.crf-stat) [class~="p-4"]{padding:8px 14px}';
    mod.registerAllComponents({ sharedCssContent: css });
    if (crfDark()) document.querySelectorAll('uui-button,uui-brand-button,uui-badge,uui-card-wrapper').forEach(e => e.classList.add('dark'));
    return true;
  } catch (e) { console.warn('ci-runner-farm: @unraid/ui unavailable, using fallback styling', e); return false; }
})();
function crfPost(p){
  p.csrf_token = CRF_CSRF;
  return fetch(CRF_URL,{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},
    body:Object.entries(p).map(([k,v])=>encodeURIComponent(k)+'='+encodeURIComponent(v)).join('&')})
    .then(r=>r.text().then(t=>{
      // fetch() only rejects on network failure, not on 4xx/5xx — so an expired
      // CSRF token (403 after a reboot/array restart) or a backend 500 arrives
      // here with a JSON body that would otherwise parse and resolve as if it were
      // real data, making the fleet look empty and buttons silently no-op. Reject
      // instead, so callers' .catch paints "connection lost / reload".
      if(!r.ok) throw new Error('http '+r.status+(r.status===403?' — session expired, reload the page':'')+': '+t.slice(0,100));
      try{ return JSON.parse(t); }catch(e){ throw new Error('bad response for '+p.action+': '+t.slice(0,120)); }
    }));
}
/* Keep the product-local shell live on every direct screen. Fleet already
   refreshes this state as part of its five-second snapshot; the other direct
   routes do not load Fleet's script, so they need this lightweight shared
   read-only poll for the header status and runner count. */
function crfSetShellState(up,busy){
  const status=document.getElementById('crf-shell-status'), label=document.getElementById('crf-shell-status-label'), count=document.getElementById('crf-shell-count');
  if(count) count.textContent=Number.isFinite(Number(up))?String(up):'\u2013';
  if(!status||!label) return;
  status.classList.remove('crf-app-status-neutral','crf-app-status-idle','crf-app-status-busy','crf-app-status-down');
  if(!up){ status.classList.add('crf-app-status-down'); label.textContent='Stopped'; }
  else if(busy){ status.classList.add('crf-app-status-busy'); label.textContent=busy+' busy'; }
  else { status.classList.add('crf-app-status-idle'); label.textContent='All idle'; }
}
function crfShellRefresh(){
  const screen=document.querySelector('.crf-app-main')?.dataset.screenLabel;
  if(screen==='Runners') return; // Fleet's richer snapshot already owns this header.
  crfPost({action:'status-json'}).then(d=>{
    if(!d||d.schema_version!==2||!Array.isArray(d.runners)) throw new Error('malformed shell snapshot');
    const running=d.runners.filter(r=>r&&r.state==='running');
    crfSetShellState(running.length,running.filter(r=>r.phase==='busy').length);
  }).catch(()=>{
    const status=document.getElementById('crf-shell-status'), label=document.getElementById('crf-shell-status-label');
    if(status){status.classList.remove('crf-app-status-idle','crf-app-status-busy');status.classList.add('crf-app-status-neutral');}
    if(label) label.textContent='Unavailable';
  });
}
document.addEventListener('DOMContentLoaded',()=>{crfShellRefresh();setInterval(crfShellRefresh,15000);},{once:true});
document.addEventListener('DOMContentLoaded',()=>{
  const settings=document.querySelector('[data-crf-primary-key="settings"]');
  if(settings&&!settings.hasAttribute('aria-current')){
    let dirty=false;try{dirty=!!(sessionStorage.getItem('ci-runner-farm:settings-draft:v1')||sessionStorage.getItem('ci-runner-farm:pools-draft:v1'));}catch(_error){}
    settings.classList.toggle('has-dirty',dirty);
  }
},{once:true});
const CRF_PRIMARY_ROUTES=<?=json_encode([
  crf_frame_url('/Utilities/RunnerFarm/RunnerFarmFleet'),
  crf_frame_url('/Utilities/RunnerFarm/RunnerFarmHistory'),
  crf_frame_url('/Utilities/RunnerFarm/RunnerFarmLogs'),
  crf_frame_url('/Utilities/RunnerFarm/RunnerFarmSettings'),
], JSON_HEX_TAG|JSON_HEX_AMP|JSON_HEX_APOS|JSON_HEX_QUOT)?>;
function crfReportFrameState(){
  if(!CRF_EMBEDDED||window.parent===window)return;
  const root=document.documentElement, body=document.body;
  const height=Math.max(root?.scrollHeight||0,root?.offsetHeight||0,body?.scrollHeight||0,body?.offsetHeight||0);
  const label=document.querySelector('.crf-app-main')?.dataset.screenLabel||'Runner Farm';
  parent.postMessage({type:'crf:frame-state',height,path:location.pathname,title:'Runner Farm: '+label},location.origin);
}
document.addEventListener('DOMContentLoaded',()=>{
  if(!CRF_EMBEDDED||window.parent===window)return;
  document.documentElement.classList.add('crf-embedded');
  let pending=0;
  const schedule=()=>{
    if(pending)return;
    pending=requestAnimationFrame(()=>{pending=0;crfReportFrameState();});
  };
  const observer=new ResizeObserver(schedule);
  observer.observe(document.documentElement);
  if(document.body)observer.observe(document.body);
  addEventListener('load',schedule,{once:true});
  addEventListener('resize',schedule);
  addEventListener('message',event=>{
    if(event.origin===location.origin&&event.source===parent&&event.data?.type==='crf:frame-parent-ready')schedule();
  });
  schedule();setTimeout(schedule,250);setTimeout(schedule,1000);
},{once:true});
document.addEventListener('keydown',event=>{
  if(event.metaKey||event.ctrlKey||event.altKey||event.defaultPrevented)return;
  const target=event.target;
  if(target?.closest?.('input,textarea,select,button,a,[contenteditable="true"],[role="dialog"]'))return;
  if([...document.querySelectorAll('dialog[open],[aria-modal="true"],.sweet-alert,.swal-modal,.modal.show,.modal.in')].some(modal=>modal.getAttribute('aria-hidden')!=='true'&&modal.getClientRects().length>0))return;
  const key=Number(event.key);if(!Number.isInteger(key)||key<1||key>CRF_PRIMARY_ROUTES.length)return;
  event.preventDefault();location.assign(CRF_PRIMARY_ROUTES[key-1]);
});
/* Copy text to the clipboard, feature-detecting the async Clipboard API (absent
   in insecure contexts — Unraid's LAN webGUI is often plain HTTP, where
   navigator.clipboard is undefined and .writeText would throw synchronously) and
   falling back to execCommand('copy'). Shared by every tab (one document). */
function crfCopyText(t){
  const legacy=()=>new Promise((res,rej)=>{ try{ const ta=document.createElement('textarea'); ta.value=t; ta.setAttribute('readonly',''); ta.style.position='fixed'; ta.style.top='-1000px'; ta.style.opacity='0'; document.body.appendChild(ta); ta.select(); const ok=document.execCommand('copy'); document.body.removeChild(ta); ok?res():rej(new Error('copy rejected')); }catch(e){ rej(e); } });
  // Some browsers EXPOSE navigator.clipboard on a plain-HTTP LAN page but then REJECT
  // writeText (insecure/unfocused context) — so .catch the promise and fall through to
  // the execCommand textarea, rather than surfacing the rejection as "Copy failed".
  if(navigator.clipboard&&navigator.clipboard.writeText) return navigator.clipboard.writeText(t).catch(legacy);
  return legacy();
}
/* Copy the text content of an element to the clipboard, with button feedback. */
function crfCopyFrom(id, btn){
  const t=(document.getElementById(id)||{}).textContent||'';
  crfCopyText(t).then(()=>{ const o=btn.textContent; btn.textContent='Copied'; setTimeout(()=>btn.textContent=o,1500); }).catch(()=>{ const o=btn.textContent; btn.textContent='Copy failed'; setTimeout(()=>btn.textContent=o,1500); });
}
function crfEsc(s){ return String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])); }
/* Semantic log tinting: escape first, then dim structural prefixes and tint
   error/warn lines and known lifecycle phrases. Applies to both consoles. */
function crfColorize(t){
  return String(t||'').split('\n').map(line=>{
    let l=crfEsc(line);
    l=l.replace(/^(\[ci-runner-farm\]|\d{4}-\d{2}-\d{2}[T ][\d:.]+Z?|#\d+\s)/,'<span class="crf-lg-dim">$1</span>');
    if(/error|fatal|failed|failure/i.test(line)) return '<span class="crf-lg-err">'+l+'</span>';
    if(/warn/i.test(line)) return '<span class="crf-lg-warn">'+l+'</span>';
    l=l.replace(/\b(shrink by \d+|removing idle [\w-]+|deregistered [\w-]+|reaping [\w-]+|stopping|stopped)\b/gi,'<span class="crf-lg-warn">$1</span>');
    l=l.replace(/\b(grow to \d+|daemon up|started|registered|Listening for Jobs|successfully|DONE|CACHED|FINISHED|build complete)\b/gi,'<span class="crf-lg-ok">$1</span>');
    return l;
  }).join('\n');
}
function crfToast(msg){
  let t=document.getElementById('crf-toast');
  if(!t){ t=document.createElement('div'); t.id='crf-toast'; t.className='crf-toast'; document.body.appendChild(t); }
  t.textContent=msg; t.classList.add('crf-toast-show');
  clearTimeout(t._h); t._h=setTimeout(()=>t.classList.remove('crf-toast-show'),2600);
}
</script>
