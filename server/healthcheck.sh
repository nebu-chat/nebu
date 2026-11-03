#!/bin/sh
# Container healthcheck for the hardened (curl-less) runtime image. Exit 0 = healthy.
# Boots a minimal throw-away VM through the release and requests the local liveness endpoint.
# RELEASE_DISTRIBUTION=none: the probe VM must not try to claim the running node's name.
RELEASE_DISTRIBUTION=none exec /app/bin/nebu eval '
:inets.start()
url = ~c"http://127.0.0.1:4000/health"
case :httpc.request(:get, {url, []}, [timeout: 4000], []) do
  {:ok, {{_, 200, _}, _, _}} -> :ok
  _ -> System.halt(1)
end
'
