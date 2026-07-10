Feature: Admin UI — War Room Mode (embedded panel, RETIRED)

  # enhanced-logging/war-room-dedicated-page (amendment 2): the embedded War
  # Room start/stop panel this feature file's scenarios exercised
  # (`[data-testid="war-room-panel"]`/`war-room-start-form`/
  # `stop-war-room-button` on `/admin/logs`) was RETIRED once the dedicated
  # `/admin/logs/war-room` page shipped — see
  # server/test/nebu/admin/logs_live/war_room_panel_retirement_test.exs for
  # the ExUnit-side "must be ABSENT" contract, and this same directory's
  # war-room-dedicated-page.feature (scenario
  # @amendment2-embedded-panel-retired) for the replacement coverage: the
  # embedded panel is gone from /admin/logs, and the sidebar "War Room" nav
  # item now leads to the real dedicated page with its own start form,
  # exclusive-scope UI, session list, and detail drill-down.
  #
  # Every scenario previously here (@ac11-war-room-panel-inactive,
  # @ac7-war-room-broad-scope-warning, @ac7-war-room-default-scope-warning,
  # @ac8-war-room-sync-scope-warning, @ac9-war-room-user-device-filter-fields,
  # @ac11-war-room-start-stop-roundtrip) asserted PRESENCE of markup that no
  # longer renders on /admin/logs — the equivalent form/warning/start-stop
  # coverage now lives on war-room-dedicated-page.feature's own scenarios
  # (@ac7-ac8-war-room-scoping-form, @ac9-ac10-war-room-exclusive-scope),
  # targeting the dedicated page instead.
