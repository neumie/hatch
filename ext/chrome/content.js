(function () {
  var STORAGE_KEY = '_hatch_workspace';
  var url = new URL(window.location.href);
  var param = url.searchParams.get('_hatch');

  // Capture workspace name from query param, then strip it from the URL
  if (param) {
    sessionStorage.setItem(STORAGE_KEY, param);
    url.searchParams.delete('_hatch');
    history.replaceState(null, '', url.pathname + url.search + url.hash);
  }

  var workspace = sessionStorage.getItem(STORAGE_KEY);
  if (!workspace) return;

  var prefix = '[' + workspace + '] ';

  function updateTitle() {
    if (document.title && !document.title.startsWith(prefix)) {
      document.title = prefix + document.title;
    }
  }

  updateTitle();

  // Re-apply prefix whenever the page changes the title (SPA route changes, etc.)
  new MutationObserver(updateTitle).observe(
    document.querySelector('head'),
    { childList: true, subtree: true, characterData: true }
  );
})();
