/// Page scripts for the Douyin parser, kept verbatim from YunX apart from the global prefix.
enum DouyinScripts {
    /// Runs before page code, so it sees the page's own detail response. The response is the only
    /// source that is certainly this work and not a recommendation; only the detail endpoint counts.
    static let detailHook = #"""
(function () {
  try {
    if (window.__thermoDetailHookInstalled) return;
    window.__thermoDetailHookInstalled = true;
    var rawOpen = XMLHttpRequest.prototype.open;
    var rawSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function (method, url) {
      try { this.__thermoUrl = String(url || ''); } catch (e) { this.__thermoUrl = ''; }
      return rawOpen.apply(this, arguments);
    };
    XMLHttpRequest.prototype.send = function () {
      var xhr = this;
      try {
        xhr.addEventListener('load', function () {
          try {
            var url = xhr.__thermoUrl || '';
            if (url.indexOf('aweme/v1/web/aweme/detail') < 0) return;
            if (xhr.status !== 200) return;
            // ★ 不能只读 responseText：页面若把 responseType 设成 'json'，读 responseText 会抛
            //   InvalidStateError（被 try 吞掉 → 钩子永远拿不到值，表现就是「一直不就绪」）。
            var text = '';
            try { text = xhr.responseText || ''; } catch (e) { text = ''; }
            if (!text) {
              try {
                var r = xhr.response;
                if (r) text = (typeof r === 'string') ? r : JSON.stringify(r);
              } catch (e) { text = ''; }
            }
            if (text) window.__thermoAwemeDetail = text;
          } catch (e) {}
        });
      } catch (e) {}
      return rawSend.apply(this, arguments);
    };
  } catch (e) {}
})()
"""#

    /// Either source may be ready. Links redirect to the real page type, so the check cannot branch on
    /// the link. Only real work images count: covers and recommendations would end the wait early.
    static let readyCheck = #"""
(function () {
  var raw = window.__thermoAwemeDetail;
  if (typeof raw === 'string' && raw.length > 0) return 'true';
  var imgs = document.querySelectorAll('img');
  for (var i = 0; i < imgs.length; i++) {
    if (isWorkImage(imgs[i].src || '')) return 'true';
  }
  return 'false';
  function isWorkImage(s) {
    if (!s || s.indexOf('douyinpic.com') < 0) return false;
    if (s.indexOf('WEBPC_RELATED') >= 0) return false;
    return s.indexOf('biz_tag=aweme_images') >= 0 || s.indexOf('tplv-dy-aweme-images') >= 0;
  }
})()
"""#

    /// Images and motion resources must come as pairs from one source, or indices drift.
    /// Source order: SSR, then the hook, then DOM images (which have no motion resources).
    static let extract = #"""
(function () {
  try {
    function firstUrl(node) {
      if (!node) return '';
      var list = node.url_list || node.urlList || null;
      if (list && list.length) return String(list[0] || '');
      return '';
    }

    function keysOf(node) {
      if (!node || typeof node !== 'object') return '';
      var keys = [];
      for (var p in node) keys.push(p);
      return keys.join(',');
    }

    // 动图资源：每张图各自的短视频（Live Photo 的「会动的那一半」）。两种数据源形态不同：
    // - 网页 SSR：`video.playAddr` 是 [{src: '...'}]
    // - 接口 JSON（XHR 钩子）：`video.play_addr` 是 {uri, url_list: [...]}（snake_case）
    function motionUrl(item) {
      if (!item) return '';
      var v = item.video;
      if (!v) return '';
      var direct = firstUrl(v.playAddr) || firstUrl(v.play_addr)
          || firstUrl(v.playApi) || firstUrl(v.play_addr_h264)
          || firstUrl(v.downloadAddr) || firstUrl(v.download_addr);
      if (direct) return direct;
      var list = v.playAddr || v.play_addr || null;
      if (list && list.length) {
        var first = list[0];
        if (first) return String(first.src || first.url || '');
      }
      return '';
    }

    // 钩子那份详情（视频/图文页页面自己会请求 aweme/v1/web/aweme/detail）
    function hookDetail() {
      var raw = window.__thermoAwemeDetail || '';
      if (!raw) return null;
      try {
        var root = JSON.parse(raw);
        return root.aweme_detail || root.awemeDetail || (root.data && root.data.aweme_detail) || null;
      } catch (e) { return null; }
    }

    // SSR 详情：抖音把作品详情 URL 编码后塞在 <script id="RENDER_DATA"> 里（app.videoDetail）。
    // 记录失败原因（ssrNote），下次「为什么没走到 SSR」直接看日志即可。
    var ssrNote = 'none';
    function readSsrDetail() {
      var node = document.querySelector('#RENDER_DATA');
      if (node && node.textContent) {
        try {
          var app = JSON.parse(decodeURIComponent(node.textContent)).app;
          if (app && app.videoDetail) { ssrNote = 'rd-ok'; return app.videoDetail; }
          ssrNote = 'rd-no-videoDetail';
        } catch (e) {
          ssrNote = 'rd-' + (e && e.name ? e.name : 'parse-fail');
        }
      } else {
        ssrNote = 'rd-missing';
      }
      try {
        var ssr = window.SSR_RENDER_DATA;
        if (ssr && ssr.app && ssr.app.videoDetail) { ssrNote += '+global-ok'; return ssr.app.videoDetail; }
        ssrNote += '+global-' + (typeof ssr);
      } catch (e) {}
      return null;
    }

    // 图片 + 动图资源**成对**抽取（保证下标一致）；同时带上首项的字段名，便于排查字段改版
    function imagesFrom(node) {
      if (!node || !node.length) return null;
      var list = [];
      var mlist = [];
      for (var i = 0; i < node.length; i++) {
        var item = node[i];
        var u = firstUrl(item);
        if (!u && item.display_image) u = firstUrl(item.display_image);
        if (!u && item.owner_watermark_image) u = firstUrl(item.owner_watermark_image);
        if (u) {
          list.push(u);
          mlist.push(motionUrl(item));
        }
      }
      if (!list.length) return null;
      return {
        images: list,
        motions: mlist,
        imgKeys: keysOf(node[0]),
        videoKeys: keysOf(node[0] && node[0].video)
      };
    }

    // DOM 里的作品图兜底（只认 aweme_images / tplv-dy-aweme-images，排除封面与「相关推荐」）
    function domWorkImages() {
      var result = [];
      var all = document.querySelectorAll('img');
      for (var i = 0; i < all.length; i++) {
        var src = all[i].src || '';
        if (src.indexOf('douyinpic') < 0) continue;
        if (src.indexOf('WEBPC_RELATED') >= 0) continue;
        var isWork = src.indexOf('biz_tag=aweme_images') >= 0 || src.indexOf('tplv-dy-aweme-images') >= 0;
        if (isWork && result.indexOf(src) < 0) result.push(src);
      }
      return result;
    }

    var hooked = hookDetail();
    var ssr = readSsrDetail();

    var images = [];
    var motions = [];
    var src = '';
    var picked = imagesFrom(ssr && ssr.images);
    if (picked) { src = 'ssr'; }
    if (!picked) {
      picked = imagesFrom(hooked && hooked.images);
      if (picked) { src = 'hook'; }
    }
    if (!picked) {
      picked = imagesFrom(hooked && hooked.image_post_info && hooked.image_post_info.images);
      if (picked) { src = 'hook'; }
    }
    if (picked) {
      images = picked.images;
      motions = picked.motions;
    } else {
      images = domWorkImages();
      src = images.length ? 'dom' : 'none';
    }

    // 视频直链：钩子优先（视频页的详情在这里），其次 SSR
    var v = (hooked && hooked.video) || (ssr && ssr.video) || null;
    var video = '';
    if (v) {
      video = firstUrl(v.play_addr) || firstUrl(v.playAddr) || firstUrl(v.play_addr_h264);
      if (!video && v.bit_rate && v.bit_rate.length) {
        for (var i = 0; i < v.bit_rate.length; i++) {
          var candidate = firstUrl(v.bit_rate[i].play_addr);
          if (candidate) { video = candidate; break; }
        }
      }
      video = video.replace('/playwm/', '/play/');
    }

    var d = hooked || ssr;
    var author = '';
    if (d && d.author) author = d.author.nickname || d.author.unique_id || '';
    if (!author && d && d.authorInfo) author = d.authorInfo.nickname || d.authorInfo.nickName || '';

    // 标题：优先详情里的 desc；没有就退到 document.title —— 抖音详情页标题就是「<文案> - 抖音」，
    // 去掉尾巴即可，实测与 desc 等价。
    var title = (d && d.desc) || '';
    if (!title) {
      var pageTitle = document.title || '';
      var tail = pageTitle.lastIndexOf(' - 抖音');
      if (tail > 0) pageTitle = pageTitle.substring(0, tail);
      title = pageTitle;
    }

    var motionCount = 0;
    for (var m = 0; m < motions.length; m++) {
      if (motions[m]) motionCount++;
    }

    return {
      title: title,
      author: author,
      video: video,
      images: images,
      motions: motions,
      src: src,
      motionCount: motionCount,
      // 诊断字段：没取到动图时靠它们定位（数据源、SSR 状态、图片项与 video 节点的字段名）
      ssr: ssrNote,
      imgKeys: picked ? picked.imgKeys : '',
      videoKeys: picked ? picked.videoKeys : '',
      cover: (v && (firstUrl(v.cover) || firstUrl(v.origin_cover))) || ''
    };
  } catch (e) {
    return { error: 'js: ' + e };
  }
})()
"""#
}
