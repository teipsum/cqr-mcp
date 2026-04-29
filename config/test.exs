import Config

config :cqr_mcp, :sse_port, 0
config :cqr_mcp, :embedded, false

# Snapshot is off by default in test — the roundtrip test enables it
# explicitly via `start_supervised`. This keeps the test suite from
# touching ~/.cqr or shelling out on every run.
config :cqr_mcp, :snapshot_in_test, false
