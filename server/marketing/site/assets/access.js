(() => {
  const form = document.querySelector("#access-form");
  if (!form) return;
  const strings = document.querySelector("#access-strings").dataset;
  const message = document.querySelector("#access-message");
  const member = document.querySelector("#access-member");
  const link = document.querySelector("#access-link");
  const referral = new URLSearchParams(location.search).get("ref");
  let csrf;

  function announce(text, error = false) {
    message.textContent = text;
    message.dataset.error = String(error);
    message.hidden = false;
  }

  async function request(path, method = "GET", body) {
    const response = await fetch(`/waitlist/${path}`, {
      method,
      credentials: "same-origin",
      headers: { "content-type": "application/json", ...(csrf ? { "x-csrf-token": csrf } : {}) },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    if (!response.ok) throw new Error(String(response.status));
    return response.json();
  }

  function showStatus(data) {
    csrf = data.csrf;
    if (!data.entry) return;
    form.hidden = true;
    member.hidden = false;
    document.querySelector("#access-rank").textContent = `#${data.entry.rank}`;
    document.querySelector("#access-referrals").textContent = String(data.entry.referrals);
    const invitation = new URL(location.pathname, data.origin);
    invitation.searchParams.set("ref", data.entry.code);
    link.value = invitation.href;
    document.querySelector("#access-share").href = `mailto:?subject=${encodeURIComponent(strings.shareSubject)}&body=${encodeURIComponent(`${strings.shareBody}\n\n${link.value}`)}`;
    announce(strings.welcome);
  }

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const button = form.querySelector("button");
    button.disabled = true;
    announce(strings.sending);
    try {
      const data = await request("status");
      csrf = data.csrf;
      await request("join", "POST", {
        email: form.elements.email.value,
        ref: referral,
        website: form.elements.website.value,
      });
      announce(strings.sent);
    } catch (error) {
      announce(error.message === "503" ? strings.unavailable : strings.error, true);
    } finally {
      button.disabled = false;
    }
  });

  document.querySelector("#access-copy").addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(link.value);
      announce(strings.copied);
    } catch {
      link.focus();
      link.select();
      announce(strings.copyFailed);
    }
  });

  const removal = document.querySelector("#access-removal");
  document.querySelector("#access-remove").addEventListener("click", () => {
    removal.hidden = false;
    document.querySelector("#access-remove-cancel").focus();
  });
  document.querySelector("#access-remove-cancel").addEventListener("click", () => {
    removal.hidden = true;
    document.querySelector("#access-remove").focus();
  });
  document.querySelector("#access-remove-confirm").addEventListener("click", async (event) => {
    event.target.disabled = true;
    try {
      await request("membership", "DELETE");
      member.hidden = true;
      removal.hidden = true;
      form.hidden = false;
      form.reset();
      announce(strings.removed);
      message.focus();
    } catch {
      announce(strings.removeError, true);
    } finally {
      event.target.disabled = false;
    }
  });

  async function initialize() {
    // Confirmation secrets stay in the fragment, never in server request URLs.
    const token = new URLSearchParams(location.hash.slice(1)).get("access");
    if (token) {
      history.replaceState(null, "", `${location.pathname}${location.search}#access`);
      announce(strings.confirming);
    }
    try {
      const data = await request("status");
      csrf = data.csrf;
      if (token) {
        showStatus(await request("confirm", "POST", { token }));
        document.querySelector("#access").scrollIntoView();
        message.focus({ preventScroll: true });
      } else {
        showStatus(data);
      }
    } catch (error) {
      if (token) announce(error.message === "422" ? strings.expired : strings.unavailable, true);
      // A standalone static preview can still show the story and form. On submit,
      // absence of Phoenix is an error, never a fictional successful signup.
    }
  }

  // An email link can open in the tab already showing this page. Fragment-only
  // navigation doesn't reload the document, so handle it just like a fresh visit.
  window.addEventListener("hashchange", () => {
    if (new URLSearchParams(location.hash.slice(1)).has("access")) initialize();
  });

  // Returning to the tab refreshes changing rank; expired sessions never expose data.
  document.addEventListener("visibilitychange", async () => {
    if (document.hidden || member.hidden) return;
    try {
      const data = await request("status");
      if (data.entry) showStatus(data);
      else {
        member.hidden = true;
        form.hidden = false;
        announce(strings.sessionExpired);
      }
    } catch { /* Keep the last known state if the connection is interrupted. */ }
  });
  initialize();
})();
