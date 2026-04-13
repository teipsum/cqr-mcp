import Config

config :logger, :default_handler, config: [type: :standard_error]

import_config "#{config_env()}.exs"
