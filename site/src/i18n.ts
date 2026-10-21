import { getLocale } from "./paraglide/runtime.js";

/** The site's languages, kept in sync with the app. `path` is the URL prefix under the deploy base. */
export const LOCALES = [
  { id: "en", lang: "en", code: "EN", label: "English", sub: "International", path: "" },
  { id: "zh-hant", lang: "zh-Hant-TW", code: "TW", label: "繁體中文", sub: "Traditional Chinese · Taiwan", path: "zh-hant/" },
  { id: "zh-hk", lang: "zh-Hant-HK", code: "HK", label: "粵語", sub: "Cantonese", path: "zh-hk/" },
  { id: "zh-hans", lang: "zh-Hans", code: "CN", label: "简体中文", sub: "Simplified Chinese", path: "zh-hans/" },
  { id: "ja", lang: "ja", code: "JA", label: "日本語", sub: "Japanese", path: "ja/" },
  { id: "ko", lang: "ko", code: "KO", label: "한국어", sub: "Korean", path: "ko/" },
  { id: "fr", lang: "fr", code: "FR", label: "Français", sub: "French", path: "fr/" },
  { id: "es", lang: "es", code: "ES", label: "Español", sub: "Spanish", path: "es/" },
  { id: "th", lang: "th", code: "TH", label: "ไทย", sub: "Thai", path: "th/" },
] as const;

export type Locale = (typeof LOCALES)[number];

export const currentLocale = (): Locale => LOCALES.find((l) => l.id === getLocale()) ?? LOCALES[0];

/** A page in a given language, under the deploy base: `localeHref(l)` is the home page, `localeHref(l, "guides/ssh-agent/")` a guide. */
export const localeHref = (l: Locale, page = "") => `${import.meta.env.BASE_URL.replace(/\/$/, "")}/${l.path}${page}`;
