const csrf = document.querySelector('meta[name="csrf-token"]').content;
const status = document.querySelector("#status");
const decode = (value) => Uint8Array.from(atob(value.replaceAll("-", "+").replaceAll("_", "/")), (c) => c.charCodeAt(0));
const encode = (value) => value === null ? null : btoa(String.fromCharCode(...new Uint8Array(value))).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");

async function post(path, body) {
  const response = await fetch(path, {
    method: "POST",
    headers: { "content-type": "application/json", "x-csrf-token": csrf },
    body: JSON.stringify(body),
  });
  if (!response.ok) throw new Error();
  return response.json();
}

for (const button of document.querySelectorAll("[data-passkey]")) {
  button.addEventListener("click", async () => {
    const buttons = document.querySelectorAll("[data-passkey]");
    buttons.forEach((b) => { b.disabled = true; });
    status.textContent = status.dataset.prompt;
    try {
      if (!window.PublicKeyCredential) {
        status.textContent = status.dataset.unsupported;
        return;
      }
      const kind = button.dataset.passkey;
      const publicKey = await post("/auth/passkeys/options", { kind });
      publicKey.challenge = decode(publicKey.challenge);
      if (publicKey.user) publicKey.user.id = decode(publicKey.user.id);
      const credential = kind === "register"
        ? await navigator.credentials.create({ publicKey })
        : await navigator.credentials.get({ publicKey });
      const response = credential.response;
      const payload = { id: encode(credential.rawId), clientDataJSON: encode(response.clientDataJSON) };
      for (const field of ["attestationObject", "authenticatorData", "signature", "userHandle"]) {
        if (field in response) payload[field] = encode(response[field]);
      }
      await post("/auth/passkeys/finish", payload);
      window.location.reload();
    } catch (error) {
      status.textContent = error?.name === "NotAllowedError" ? status.dataset.cancelled : status.dataset.failure;
    } finally {
      buttons.forEach((b) => { b.disabled = false; });
    }
  });
}
