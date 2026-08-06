(function () {
  "use strict";

  const cfg = window.SAT_AUTH_CONFIG;
  if (!cfg) {
    throw new Error("SAT_AUTH_CONFIG is missing.");
  }

  const keys = Object.freeze({
    verifier: "sat_pkce_verifier",
    state: "sat_oauth_state",
    returnTo: "sat_return_to",
    accessToken: "sat_access_token",
    idToken: "sat_id_token",
    refreshToken: "sat_refresh_token",
    expiresAt: "sat_expires_at"
  });

  function base64Url(bytes) {
    let binary = "";
    bytes.forEach((byte) => {
      binary += String.fromCharCode(byte);
    });
    return btoa(binary)
      .replace(/\+/g, "-")
      .replace(/\//g, "_")
      .replace(/=+$/g, "");
  }

  function randomString(byteLength) {
    const bytes = new Uint8Array(byteLength);
    crypto.getRandomValues(bytes);
    return base64Url(bytes);
  }

  async function sha256Base64Url(value) {
    const digest = await crypto.subtle.digest(
      "SHA-256",
      new TextEncoder().encode(value)
    );
    return base64Url(new Uint8Array(digest));
  }

  function normalizeReturnTo(returnTo) {
    if (!returnTo || !returnTo.startsWith("/") || returnTo.startsWith("//")) {
      return "/math/index.html";
    }
    return returnTo;
  }

  async function startLogin(returnTo) {
    const verifier = randomString(64);
    const challenge = await sha256Base64Url(verifier);
    const state = randomString(32);

    sessionStorage.setItem(keys.verifier, verifier);
    sessionStorage.setItem(keys.state, state);
    sessionStorage.setItem(keys.returnTo, normalizeReturnTo(returnTo));

    const params = new URLSearchParams({
      response_type: "code",
      client_id: cfg.clientId,
      redirect_uri: cfg.redirectUri,
      scope: cfg.scope,
      state,
      code_challenge: challenge,
      code_challenge_method: "S256"
    });

    window.location.assign(`${cfg.domain}/oauth2/authorize?${params.toString()}`);
  }

  function storeTokens(tokens) {
    if (!tokens.access_token || !tokens.id_token) {
      throw new Error("Cognito did not return the expected tokens.");
    }

    sessionStorage.setItem(keys.accessToken, tokens.access_token);
    sessionStorage.setItem(keys.idToken, tokens.id_token);

    const claims = decodeJwt(tokens.id_token);
    const username = String(
      claims?.["cognito:username"] ||
      claims?.username ||
      ""
    ).trim().toLowerCase();

    if (/^[a-z0-9_-]{1,80}$/.test(username)) {
      localStorage.setItem("sat_user", username);
    }

    if (tokens.refresh_token) {
      sessionStorage.setItem(keys.refreshToken, tokens.refresh_token);
    }

    const expiresInSeconds = Number(tokens.expires_in || 3600);
    sessionStorage.setItem(
      keys.expiresAt,
      String(Date.now() + expiresInSeconds * 1000)
    );
  }

  function clearLocalSession() {
    Object.values(keys).forEach((key) => sessionStorage.removeItem(key));
    localStorage.removeItem("sat_user");
  }

  async function postToken(body) {
    const response = await fetch(`${cfg.domain}/oauth2/token`, {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded"
      },
      body: new URLSearchParams(body).toString()
    });

    const payload = await response.json().catch(() => ({}));
    if (!response.ok) {
      const message = payload.error_description || payload.error || "Token request failed.";
      throw new Error(message);
    }

    return payload;
  }

  async function handleCallback() {
    const params = new URLSearchParams(window.location.search);
    const oauthError = params.get("error");

    if (oauthError) {
      throw new Error(params.get("error_description") || oauthError);
    }

    const code = params.get("code");
    const returnedState = params.get("state");
    const expectedState = sessionStorage.getItem(keys.state);
    const verifier = sessionStorage.getItem(keys.verifier);

    if (!code) {
      throw new Error("Authorization code is missing.");
    }
    if (!expectedState || returnedState !== expectedState) {
      throw new Error("Login state validation failed. Please start again.");
    }
    if (!verifier) {
      throw new Error("PKCE verifier is missing. Please start again.");
    }

    const tokens = await postToken({
      grant_type: "authorization_code",
      client_id: cfg.clientId,
      code,
      redirect_uri: cfg.redirectUri,
      code_verifier: verifier
    });

    storeTokens(tokens);
    sessionStorage.removeItem(keys.verifier);
    sessionStorage.removeItem(keys.state);

    const returnTo = normalizeReturnTo(sessionStorage.getItem(keys.returnTo));
    sessionStorage.removeItem(keys.returnTo);
    window.location.replace(returnTo);
  }

  function decodeJwt(token) {
    if (!token) {
      return null;
    }

    try {
      const part = token.split(".")[1];
      const normalized = part.replace(/-/g, "+").replace(/_/g, "/");
      const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=");
      const json = decodeURIComponent(
        atob(padded)
          .split("")
          .map((char) => `%${char.charCodeAt(0).toString(16).padStart(2, "0")}`)
          .join("")
      );
      return JSON.parse(json);
    } catch (error) {
      console.error("Unable to decode JWT", error);
      return null;
    }
  }

  async function refreshSession() {
    const refreshToken = sessionStorage.getItem(keys.refreshToken);
    if (!refreshToken) {
      return null;
    }

    try {
      const tokens = await postToken({
        grant_type: "refresh_token",
        client_id: cfg.clientId,
        refresh_token: refreshToken
      });
      storeTokens(tokens);
      return getSession(false);
    } catch (error) {
      clearLocalSession();
      return null;
    }
  }

  async function getSession(allowRefresh = true) {
    const accessToken = sessionStorage.getItem(keys.accessToken);
    const idToken = sessionStorage.getItem(keys.idToken);
    const expiresAt = Number(sessionStorage.getItem(keys.expiresAt) || 0);

    if (accessToken && idToken && expiresAt > Date.now() + 30000) {
      return {
        accessToken,
        idToken,
        claims: decodeJwt(idToken)
      };
    }

    return allowRefresh ? refreshSession() : null;
  }

  async function requireAuth() {
    const session = await getSession();
    if (session) {
      return session;
    }

    const returnTo = `${window.location.pathname}${window.location.search}${window.location.hash}`;
    window.location.replace(`/login.html?returnTo=${encodeURIComponent(returnTo)}`);
    return null;
  }

  function logout() {
    clearLocalSession();
    const params = new URLSearchParams({
      client_id: cfg.clientId,
      logout_uri: cfg.logoutUri
    });
    window.location.assign(`${cfg.domain}/logout?${params.toString()}`);
  }

  window.SATAuth = Object.freeze({
    startLogin,
    handleCallback,
    getSession,
    requireAuth,
    logout,
    decodeJwt
  });
})();
