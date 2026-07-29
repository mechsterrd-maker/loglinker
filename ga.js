/* Google Analytics 4 (GA4) for LogLinkr.
   Single source of truth for the Measurement ID — every page loads this one file.
   To change the ID later, edit only this line. */
(function () {
  var ID = 'G-PBJV5V8RGW';
  var s = document.createElement('script');
  s.async = true;
  s.src = 'https://www.googletagmanager.com/gtag/js?id=' + ID;
  document.head.appendChild(s);
  window.dataLayer = window.dataLayer || [];
  function gtag() { dataLayer.push(arguments); }
  window.gtag = gtag;
  gtag('js', new Date());
  gtag('config', ID);
})();
