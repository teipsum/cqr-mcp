import Config

config :logger, :default_handler, config: [type: :standard_error]

# Configure adapter modules for CQR routing:
# config :cqr_mcp, adapters: [Cqr.Adapter.Grafeo, Cqr.Adapter.Github]
# Default when unset: [Cqr.Adapter.Grafeo]

config :cqr_mcp, certification_preservation_policy: :standard

import_config "#{config_env()}.exs"
