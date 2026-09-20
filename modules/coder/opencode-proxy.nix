{
  config,
  lib,
  ...
}:
let
  utils = import ../../lib {
    inherit config lib;
  };
in
{
  # OpenCode Go (a.k.a. OpenCode Console / "Zen") now rejects any request that
  # does not carry an `x-opencode-session` header, with:
  #   400 {"type":"MissingSessionID","message":"... Request is missing
  #        x-opencode-session and cannot be routed efficiently. ..."}
  #
  # Coder's AI Bridge — which serves the Coder "Agents" feature — proxies model
  # traffic to whichever provider you configured, as a generic "OpenAI
  # Compatible" endpoint, and does NOT add that header. It only *reads* it (or
  # `x-session-affinity`) for its own session tracking (coder/coder#26128,
  # coder/coder#26140). So requests to OpenCode Go die with a 400.
  #
  # This vhost sits between Coder's AI Bridge and opencode.ai and adds the
  # header. In Coder's AI settings, set the provider base URL to:
  #
  #   https://opencode-proxy.${config.common.internalDomain}/zen/v1
  #
  # (keep the `/zen/v1` path — this vhost forwards the path unchanged, so the
  #  rest of the URL just needs to match OpenCode's own API layout).
  #
  # See modules/coder/README.md and the upstream issues:
  #   https://github.com/anomalyco/opencode/issues/47763
  #   https://github.com/anomalyco/opencode/issues/47438
  services.nginx.appendHttpConfig = ''
    # Always provide x-opencode-session. Prefer one the client already sent,
    # then OpenCode's own x-session-affinity (what the AI Bridge forwards), and
    # finally a unique-per-request id so the header can never be missing.
    map $http_x_opencode_session $opencode_session_pre {
      default $http_x_opencode_session;
      ""      $http_x_session_affinity;
    }
    map $opencode_session_pre $opencode_session {
      default $opencode_session_pre;
      ""      $request_id;
    }
  '';

  services.nginx.virtualHosts."opencode-proxy.${config.common.internalDomain}" = utils.mkVirtualHost {
    internal = true;
    settings = {
      # Raw proxy_pass in extraConfig (rather than mkVirtualHost's `port`) on
      # purpose: the NixOS nginx module only injects `recommendedProxyConfig`
      # (which forces `proxy_set_header Host $host`) when the structured
      # `proxyPass` option is set. We want to send `Host: opencode.ai`, not this
      # internal vhost name, so we opt out of that include.
      extraConfig = ''
        proxy_pass https://opencode.ai;

        # opencode.ai terminates TLS on its own name, so send it in both SNI and
        # the Host header.
        proxy_ssl_server_name on;
        proxy_set_header Host opencode.ai;

        # The entire point of this vhost:
        proxy_set_header x-opencode-session $opencode_session;

        # LLM responses are SSE streams: don't buffer, allow long-lived requests.
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
      '';
    };
  };
}
