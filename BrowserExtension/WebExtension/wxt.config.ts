import { defineConfig } from 'wxt';

// One source, three targets: Chrome/Edge/Brave (MV3 service worker), Firefox (MV3 event page) and Safari
// (bundled into TriwardenSafari.appex by Xcode). The version comes from package.json.
export default defineConfig({
  modules: ['@wxt-dev/module-solid'],
  manifestVersion: 3,
  manifest: ({ browser }) => ({
    name: 'Triwarden',
    description: 'Fill and save logins from your Triwarden vault. Filling asks for Touch ID in the app.',
    icons: { 48: 'icon-48.png', 96: 'icon-96.png', 128: 'icon-128.png' },
    permissions: ['nativeMessaging', 'contextMenus'],
    commands: {
      'fill-login': {
        suggested_key: { default: 'Ctrl+Shift+L', mac: 'Command+Shift+L' },
        description: 'Fill the login or one-time code on this page',
      },
    },
    // Chromium: the Chrome Web Store's public key, so an unpacked build has the store's extension ID (deiehcliaaoigminkkbnjlgmaoagimdm)
    // and the host manifest can name it ahead of time. It is a public key.
    ...(browser === 'chrome' && {
      key: 'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA42663IYRdt7SsrqT2NGa1DivTogJyXpX2e4rCu/x9gJbaih2Wbu3NlRs8Ft0yyKr5n7f+XpCASFRjdhqvKQ6KJXVCG1oFfRaVDbVTH2/39bFEn52IElvaRXXY8vUBx6eANvo+EjlSPRJuzBXRwqZg0nJ0KyS1Nvw1yFJmV3m0QsvXhC/VHyMXIIkZrmE8BGzFYpK8RjASWEPpJuGkY+s4hEBRleYIxO/kshvNozCXj6AfISLNBSN8URwIKbEJBuZzZ1VWuObBFkEoiAGYTyYHpP/KGT1l6JOXR9LCk5ZzEXpaLTmg+GQjTee47VJSXfX2TrllLL6JeOnCXPB7Nf+ewIDAQAB',
    }),
    ...(browser === 'firefox' && {
      browser_specific_settings: {
        gecko: {
          // Permanent once published on addons.mozilla.org, and the host manifest's allowed_extensions must match it.
          id: 'triwarden@sinhong2011.github.io',
          // data_collection_permissions only exists from Firefox 140; older versions would reject the manifest.
          strict_min_version: '140.0',
          // The extension itself collects nothing; page URLs only go to the local app.
          data_collection_permissions: { required: ['none'] },
        },
      },
    }),
  }),
});
