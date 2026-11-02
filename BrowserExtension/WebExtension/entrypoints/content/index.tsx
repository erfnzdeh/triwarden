// Triwarden content script: a key button in login fields (fill after Touch ID in the app) and an offer to
// save what you typed when the form is submitted. Passwords are never stored by the extension.
import { render } from 'solid-js/web';
import { watchForSubmits } from '../../lib/save';
import Overlay from './Overlay';
import './overlay.css';

/**
 * Vazirmatn for Persian and Arabic item names in the menu. A font in a shadow root's own stylesheet isn't loaded,
 * so it goes in the document's font set, under a name of our own so a page that ships its own Vazirmatn keeps it.
 * The browser only fetches it when the menu draws one of these letters.
 */
function addPersianFont() {
  const font = new FontFace('Triwarden Vazirmatn', `url(${browser.runtime.getURL('/fonts/Vazirmatn-NL.woff2')}) format('woff2')`, {
    weight: '100 900',
    // Arabic script (Persian included), its presentation forms, and the zero-width joiners Persian words use.
    unicodeRange: 'U+0600-06FF, U+0750-077F, U+0870-08FF, U+200C-200F, U+FB50-FDFF, U+FE70-FEFF',
  });
  document.fonts.add(font);
}

export default defineContentScript({
  matches: ['https://*/*', 'http://*/*'],
  allFrames: true,
  runAt: 'document_idle',
  // The overlay lives in a closed shadow root, so page styles can't touch it and ours don't leak out.
  cssInjectionMode: 'ui',

  async main(ctx) {
    watchForSubmits();
    addPersianFont();
    const ui = await createShadowRootUi(ctx, {
      name: 'triwarden-overlay',
      position: 'overlay',
      zIndex: 2147483647,
      anchor: 'body',
      mode: 'closed',
      onMount: (container) => render(() => <Overlay />, container),
      onRemove: (dispose) => dispose?.(),
    });
    ui.mount();
  },
});
