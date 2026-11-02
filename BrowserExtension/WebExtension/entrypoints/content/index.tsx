// Triwarden content script: a key button in login fields (fill after Touch ID in the app) and an offer to
// save what you typed when the form is submitted. Passwords are never stored by the extension.
import { render } from 'solid-js/web';
import { watchForSubmits } from '../../lib/save';
import Overlay from './Overlay';
import './overlay.css';

export default defineContentScript({
  matches: ['https://*/*', 'http://*/*'],
  allFrames: true,
  runAt: 'document_idle',
  // The overlay lives in a closed shadow root, so page styles can't touch it and ours don't leak out.
  cssInjectionMode: 'ui',

  async main(ctx) {
    watchForSubmits();
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
