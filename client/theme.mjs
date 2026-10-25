// Bundle the server-owned Theme UI theme for offline startup. Do not fork its
// values here. React UIs can pass this object directly to ThemeUIProvider.
export { default } from "../server/priv/theme.json" with { type: "json" };
