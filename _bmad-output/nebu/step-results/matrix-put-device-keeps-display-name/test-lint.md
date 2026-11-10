# test-lint — matrix-put-device-keeps-display-name: 5 scenarios, 16 ExUnit tests, 0 e2e files
MINOR | server/test/nebu/matrix/device_put_keeps_display_name_test.exs:107 | test without assertion: "PUT with a name string still renames (regression)" | assert the observable outcome
MINOR | server/test/nebu/matrix/device_put_keeps_display_name_test.exs:133 | test without assertion: "PUT {\"display_name\": <#{label}>} -> 400 M_BAD_JSON and the" | assert the observable outcome
MINOR | _bmad-output/nebu/step-results/matrix-put-device-keeps-display-name/oracle-context.md | spec error code M_NOT_JSON is not referenced by any test | add a test for it or note why it does not apply
