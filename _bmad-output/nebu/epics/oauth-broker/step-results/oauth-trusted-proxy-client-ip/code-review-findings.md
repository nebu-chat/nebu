# Code review oauth-trusted-proxy-client-ip cycle 0: 0 MAJOR, 3 MINOR, 10 INFO
All AC1-AC10 implemented; all consumers use Nebu.Web.ClientIP.get/1; plug never raises; cluster-safe.
MINOR 1: stale "RED-phase" prose in tests: client_ip_test.exs:3,13-15; client_ip_integration_test.exs:3,21-22,256-257 (wrong claim "green on HEAD, do not touch new module"); client_ip_contract_test.exs:3; adr_033_test.exs:550. Fix prose.
MINOR 2: contract test scans only remote_ip/x-forwarded-for: add get_peer_data|peer_data (and x_forwarded_for) to forbidden tokens (client_ip_contract_test.exs:38-46; client_ip.ex:6-7 claims "only places").
MINOR 3: property loop client_ip_test.exs:604-631 accepts {:peer,_} for trusted peer always: count :forwarded results, assert lower bound (>= 20).
INFO: I1 peer_string inspect vs to_string for non-tuple; I2 prefix "/08" accepted; I3 whole-value-ignored warning wording ("1 invalid entry"); I7 `assert log == ""` flake risk at :info; I8 07-deployment subsection placement; others no action.
