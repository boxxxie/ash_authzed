import Config

if Mix.env() == :test do
  config :ash,
    default_string_length_count: :codepoints,
    disable_async?: true
end
