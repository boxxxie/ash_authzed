spark_locals_without_parens = [
  object_type: 1,
  actor_type: 1,
  id_attribute: 1,
  adapter: 1,
  adapter_opts: 1,
  schema_path: 1,
  relation: 1,
  relation: 2,
  external_role: 1,
  external_role: 2,
  conditional_wildcard: 1,
  conditional_wildcard: 2,
  rebac_can: 1,
  rebac_can: 2,
  rebac_can_assign: 2,
  authzed_can: 1,
  authzed_can: 2,
  authzed_can_assign: 2
]

[
  import_deps: [:ash, :spark],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: spark_locals_without_parens,
  export: [
    locals_without_parens: spark_locals_without_parens
  ]
]
