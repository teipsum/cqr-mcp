import Config

config :logger, :default_handler, config: [type: :standard_error]

# Configure adapter modules for CQR routing:
# config :cqr_mcp, adapters: [Cqr.Adapter.Grafeo, Cqr.Adapter.Github]
# Default when unset: [Cqr.Adapter.Grafeo]

config :cqr_mcp, certification_preservation_policy: :standard

# Cqr.Repo.Snapshot writes a JSON safety-net dump to ~/.cqr every
# `snapshot_interval_ms`. This is the recovery point if the Grafeo
# on-disk file corrupts (GRAFEO-X001). Disabled in :test by default.
config :cqr_mcp, snapshot_interval_ms: 300_000

# Use EXLA as the default Nx backend so Bumblebee tensors and the
# Cqr.Embedding serving run on the local accelerator instead of pure-Erlang
# binary tensors. EXLA picks up the Metal client automatically on Apple
# Silicon when XLA_TARGET=metal is set; otherwise it falls back to the host
# CPU client. We do NOT pin client: :metal here because that would harden
# the Apple-Silicon assumption into Linux CI.
config :nx, default_backend: EXLA.Backend

import_config "#{config_env()}.exs"
