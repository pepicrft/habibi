import { mount, signal, Text, View, type YNode } from "nsh";
import { nativeComponent } from "nsh/native";

type Page = {
  kit: { id: string; name: string; description: string };
  colors: { text: string; secondary: string; accent: string };
  typography: { title: number; heading: number; body: number; caption: number };
};

// Public presentation data only. This bridge cannot connect, install, fetch,
// read a vault or invoke tools. Those controls belong to the native sheet.
const Host = nativeComponent<{ ready: boolean }, { data: Page }>("habibi.kit-page", {
  props: ["ready"], events: ["data"],
});

function GitHubPage() {
  const page = signal<Page | undefined>(undefined);
  let host: YNode | undefined;
  return (
    <View style={{ width: "100%" }}>
      <Host ref={(node) => (host = node)} ready={true} onData={(value) => page.set(value)} style={{ width: 0, height: 0 }} />
      {page() && (
        <View testID="kit-presentation" style={{ gap: 16, width: "100%" }}
          onLayout={({ size }) => host?.command("height", size.height)}>
          <Text style={{ fontSize: page()!.typography.title, fontWeight: "600", color: page()!.colors.text, textAlign: "center" }}>{page()!.kit.name}</Text>
          <Text style={{ fontSize: page()!.typography.body, color: page()!.colors.secondary, textAlign: "center" }}>
            Your profile. Your public projects. Ready to talk about with Habibi.
          </Text>
          <View style={{ gap: 8 }}>
            <Text style={{ fontSize: page()!.typography.heading, fontWeight: "600", color: page()!.colors.text }}>What Habibi can do</Text>
            <Text style={{ fontSize: page()!.typography.body, color: page()!.colors.text }}>Read your GitHub profile</Text>
            <Text style={{ fontSize: page()!.typography.body, color: page()!.colors.text }}>List 10 recent public repositories you own</Text>
            <Text style={{ fontSize: page()!.typography.caption, color: page()!.colors.secondary }}>No private repositories, file contents or write access.</Text>
          </View>
        </View>
      )}
    </View>
  );
}

mount(GitHubPage);
