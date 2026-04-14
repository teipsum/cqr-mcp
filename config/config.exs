import Config

config :logger, :default_handler, config: [type: :standard_error]

config :cqr_mcp, certification_preservation_policy: :standard

import_config "#{config_env()}.exs"
