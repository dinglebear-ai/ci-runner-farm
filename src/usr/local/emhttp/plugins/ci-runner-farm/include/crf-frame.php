<?php
/* Same-origin frame host for the redesigned CI Runner Farm application shell.
   Native Unraid routes keep the webGUI chrome; ?crf_embed=1 renders the
   standalone product shell inside an iframe. */

if (!function_exists('crf_is_embedded')) {
  function crf_is_embedded(): bool {
    return isset($_GET['crf_embed']) && (string)$_GET['crf_embed'] === '1';
  }
}

if (!function_exists('crf_frame_url')) {
  function crf_frame_url(string $path): string {
    if (!crf_is_embedded()) return $path;
    return $path . (str_contains($path, '?') ? '&' : '?') . 'crf_embed=1';
  }
}

if (!function_exists('crf_render_frame_host')) {
  function crf_render_frame_host(string $page, string $title): void {
    $path = '/Utilities/RunnerFarm/' . ltrim($page, '/');
    $src = $path . '?crf_embed=1';
    $id = 'crf-app-frame';
    ?>
    <style>
      body:has(.crf-frame-host) #displaybox>.tabs,
      body:has(.crf-frame-host) #displaybox>.content>.tabs,
      body:has(.crf-frame-host) #displaybox>.content>div.title{display:none!important}
      body:has(.crf-frame-host) #displaybox>.content{width:100%!important;max-width:none!important;margin:0!important;padding:0!important;overflow:visible!important}
      .crf-frame-host{width:100%;min-width:0;margin:0;padding:0;background:#f2f2f2}
      .crf-app-frame{display:block;width:100%;height:calc(100vh - 245px);min-height:680px;border:0;background:#f2f2f2}
      @media (max-width:767px){.crf-app-frame{height:calc(100vh - 155px);min-height:620px}}
    </style>
    <div class="crf-frame-host">
      <iframe
        id="<?=htmlspecialchars($id, ENT_QUOTES)?>"
        class="crf-app-frame"
        src="<?=htmlspecialchars($src, ENT_QUOTES)?>"
        title="<?=htmlspecialchars($title, ENT_QUOTES)?>"
        loading="eager"></iframe>
    </div>
    <script>
    (()=>{
      const frame=document.getElementById(<?=json_encode($id)?>);
      if(!frame)return;
      const origin=location.origin;
      const embeddedUrl=path=>path+(path.includes('?')?'&':'?')+'crf_embed=1';
      const resize=height=>{
        const value=Math.max(620,Math.min(30000,Math.ceil(Number(height)||0)));
        if(value)frame.style.height=value+'px';
      };
      addEventListener('message',event=>{
        if(event.origin!==origin||event.source!==frame.contentWindow)return;
        const data=event.data||{};
        if(data.type!=='crf:frame-state')return;
        resize(data.height);
        if(typeof data.path==='string'&&data.path.startsWith('/Utilities/RunnerFarm/RunnerFarm')&&data.path!==location.pathname){
          history.replaceState({crfFramePath:data.path},'',data.path);
        }
        if(typeof data.title==='string'&&data.title)frame.title=data.title;
      });
      addEventListener('popstate',()=>{
        if(!location.pathname.startsWith('/Utilities/RunnerFarm/RunnerFarm'))return;
        frame.src=embeddedUrl(location.pathname);
      });
      frame.addEventListener('load',()=>{
        try{frame.contentWindow.postMessage({type:'crf:frame-parent-ready'},origin);}catch(_error){}
      });
    })();
    </script>
    <?php
  }
}

if (!function_exists('crf_begin_embedded_page')) {
  function crf_begin_embedded_page(string $page, string $title): bool {
    if (crf_is_embedded()) return true;
    crf_render_frame_host($page, $title);
    return false;
  }
}
