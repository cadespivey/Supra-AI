import localFont from "next/font/local";

export const equity = localFont({
  src: [
    {
      path: "../public/fonts/equity_a_regular.woff2",
      weight: "400",
      style: "normal",
    },
    {
      path: "../public/fonts/equity_a_italic.woff2",
      weight: "400",
      style: "italic",
    },
    {
      path: "../public/fonts/equity_a_bold.woff2",
      weight: "700",
      style: "normal",
    },
    {
      path: "../public/fonts/equity_a_bold_italic.woff2",
      weight: "700",
      style: "italic",
    },
  ],
  variable: "--font-equity",
  fallback: ["Georgia", "Times New Roman", "serif"],
  display: "swap",
});

export const equityCaps = localFont({
  src: [
    {
      path: "../public/fonts/equity_a_caps_regular.woff2",
      weight: "400",
      style: "normal",
    },
    {
      path: "../public/fonts/equity_a_caps_bold.woff2",
      weight: "700",
      style: "normal",
    },
  ],
  variable: "--font-equity-caps",
  fallback: ["Georgia", "Times New Roman", "serif"],
  display: "swap",
});
