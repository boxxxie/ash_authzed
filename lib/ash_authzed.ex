defmodule AshAuthzed do
  @moduledoc """
  Standalone Ash Framework extension for Zanzibar / ReBAC authorization
  backed by `Licet` (embedded Postgres/Ecto), `SpiceDB` / `Authzed` (HTTP via `Req`),
  or `AshAuthzed.Adapters.Memory` (in-memory `Licet` engine).

  ## Usage

      defmodule MyApp.Accounts.User do
        use Ash.Resource,
          domain: MyApp.Accounts,
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          extensions: [AshAuthzed]

        authzed do
          object_type "user_profile"
          adapter :licet
          adapter_opts [instance: MyApp.Licet]

          relation :owner, subject_type: "user", subject_id: :id
          relation :platform, static_subject: "platform:main"
          external_role :role, target: "platform:main", subject_type: "user", subject_id: :id

          conditional_wildcard :is_protected_admin,
            subject_type: "user",
            attribute: :role,
            in: [:admin, :super_admin]
        end

        policies do
          policy action(:read) do
            authorize_if rebac_can(:view)
          end

          policy action(:update_profile) do
            authorize_if rebac_can(:edit)
          end
        end
      end
  """

  alias Spark.Dsl.Extension

  defmodule Relation do
    @moduledoc """
    Represents a direct Zanzibar relation between the resource and a subject.
    """
    defstruct [:name, :subject_type, :subject_id, :static_subject, __spark_metadata__: nil]

    @type t :: %__MODULE__{
            name: atom(),
            subject_type: String.t() | nil,
            subject_id: atom() | nil,
            static_subject: String.t() | nil,
            __spark_metadata__: term()
          }
  end

  defmodule ExternalRole do
    @moduledoc """
    Represents a role or capability attribute on the resource that maps to a relation
    on the resource instance itself (`:self`, the default) or an external object
    (e.g., `target: "platform:main"` -> `platform:main#<role>@user:<id>`).
    """
    defstruct [
      :attribute,
      :target,
      :subject_type,
      :subject_id,
      :role_mapping,
      __spark_metadata__: nil
    ]

    @type t :: %__MODULE__{
            attribute: atom(),
            target: String.t() | :self | nil,
            subject_type: String.t(),
            subject_id: atom(),
            role_mapping: map(),
            __spark_metadata__: term()
          }
  end

  defmodule ConditionalWildcard do
    @moduledoc """
    Represents a conditional wildcard relation (`object_type:id#name@subject_type:*`)
    written when `attribute` is in the specified list of values.
    """
    defstruct [:name, :subject_type, :attribute, :in, __spark_metadata__: nil]

    @type t :: %__MODULE__{
            name: atom(),
            subject_type: String.t(),
            attribute: atom(),
            in: [atom() | String.t()],
            __spark_metadata__: term()
          }
  end

  @relation %Spark.Dsl.Entity{
    name: :relation,
    describe: "Declares a direct relationship tuple synced on create, update, and destroy.",
    target: Relation,
    args: [:name],
    schema: [
      name: [type: :atom, required: true, doc: "The Zanzibar relation name on this object type."],
      subject_type: [type: :string, doc: "The subject type (e.g. `\"user\"`)."],
      subject_id: [
        type: :atom,
        doc: "The resource attribute holding the subject ID (e.g. `:id` or `:owner_id`)."
      ],
      static_subject: [
        type: :string,
        doc: "A static subject reference (`\"type:id\"`), such as `\"platform:main\"`."
      ]
    ]
  }

  @external_role %Spark.Dsl.Entity{
    name: :external_role,
    describe:
      "Syncs a resource attribute as a relation on the resource itself (`:self`) or an external target object.",
    target: ExternalRole,
    args: [:attribute],
    schema: [
      attribute: [
        type: :atom,
        required: true,
        doc: "The attribute on the resource holding the role or capability name."
      ],
      target: [
        type: {:or, [:string, {:in, [:self]}]},
        default: :self,
        doc:
          "The target object (`\"type:id\"`) on which the role relation is written, or `:self` (default) to target the resource instance itself (`\"<object_type>:<id>\"`)."
      ],
      subject_type: [type: :string, default: "user", doc: "The subject type."],
      subject_id: [
        type: :atom,
        default: :id,
        doc: "The attribute holding the subject ID."
      ],
      role_mapping: [
        type: :map,
        default: %{},
        doc:
          "Optional map translating attribute values to schema relation names (e.g. `%{user: \"member\"}`)."
      ]
    ]
  }

  @conditional_wildcard %Spark.Dsl.Entity{
    name: :conditional_wildcard,
    describe:
      "Syncs a wildcard tuple (`object:id#relation@subject_type:*`) when an attribute value matches.",
    target: ConditionalWildcard,
    args: [:name],
    schema: [
      name: [type: :atom, required: true, doc: "The relation name on this object type."],
      subject_type: [
        type: :string,
        default: "user",
        doc: "The wildcard subject type (`\"user\"` -> `\"user:*\"`)."
      ],
      attribute: [type: :atom, required: true, doc: "The attribute to inspect on the record."],
      in: [
        type: {:list, :any},
        required: true,
        doc: "List of attribute values for which the wildcard tuple should exist."
      ]
    ]
  }

  @section_schema [
    object_type: [
      type: :string,
      required: true,
      doc: "The Zanzibar definition name for this Ash resource (e.g. `\"user_profile\"`)."
    ],
    actor_type: [
      type: :string,
      default: "user",
      doc: "The Zanzibar definition name for actors (defaults to `\"user\"`)."
    ],
    id_attribute: [
      type: :atom,
      default: :id,
      doc: "The primary key attribute on the resource used for object IDs."
    ],
    adapter: [
      type: :atom,
      default: :licet,
      doc: "The ReBAC adapter to use (`:licet`, `:spicedb_http`, `:memory`, or a custom module)."
    ],
    adapter_opts: [
      type: :keyword_list,
      default: [],
      doc: "Options forwarded to the configured adapter (e.g. `[instance: MyApp.Licet]`)."
    ],
    schema_path: [
      type: :string,
      doc:
        "Path to the `.zed` or `.yaml` validation file used for compile-time schema drift verification."
    ]
  ]

  @authzed_section %Spark.Dsl.Section{
    name: :authzed,
    describe: "Configures Zanzibar / Authzed ReBAC tuple synchronization and policy checks.",
    schema: @section_schema,
    entities: [@relation, @external_role, @conditional_wildcard]
  }

  @rebac_section %Spark.Dsl.Section{
    name: :rebac,
    describe: "Alias section for `authzed`.",
    schema: @section_schema,
    entities: [@relation, @external_role, @conditional_wildcard]
  }

  use Spark.Dsl.Extension,
    sections: [@authzed_section, @rebac_section],
    transformers: [AshAuthzed.Transformer],
    verifiers: [AshAuthzed.Verifiers.VerifyZedSchema],
    imports: [AshAuthzed.PolicyMacros]

  @doc false
  def __sections__, do: [@authzed_section, @rebac_section]

  @doc """
  Fetches a configuration option from the resource's `authzed` or `rebac` DSL section.
  """
  @spec get_opt(Ash.Resource.t(), atom(), term()) :: term()
  def get_opt(resource, key, default \\ nil) do
    case Extension.get_opt(resource, [:authzed], key, nil) do
      nil -> Extension.get_opt(resource, [:rebac], key, default)
      val -> val
    end
  end

  @doc """
  Returns all ReBAC entities declared in the resource's `authzed` and `rebac` DSL sections.
  """
  @spec get_entities(Ash.Resource.t()) :: [
          Relation.t() | ExternalRole.t() | ConditionalWildcard.t()
        ]
  def get_entities(resource) do
    Extension.get_entities(resource, [:authzed]) ++ Extension.get_entities(resource, [:rebac])
  end

  @doc """
  Builds the adapter options keyword list for a given Ash resource, merging any call-site overrides.
  """
  @spec adapter_config(Ash.Resource.t(), keyword()) :: keyword()
  def adapter_config(resource, overrides \\ []) do
    default_adapter = get_opt(resource, :adapter, :licet)
    adapter = Application.get_env(:ash_authzed, :adapter, default_adapter)
    default_adapter_opts = get_opt(resource, :adapter_opts, [])
    app_adapter_opts = Application.get_env(:ash_authzed, :adapter_opts, [])
    override_adapter_opts = Keyword.get(overrides, :adapter_opts, [])

    adapter_opts =
      default_adapter_opts
      |> Keyword.merge(app_adapter_opts)
      |> Keyword.merge(override_adapter_opts)

    [adapter: adapter, adapter_opts: adapter_opts]
    |> Keyword.merge(Keyword.delete(overrides, :adapter_opts))
  end

  @doc """
  Discovers all Ash resources in the given OTP app (or list of Ash domains)
  that use the `AshAuthzed` extension.
  """
  @spec registered_resources(atom() | [Ash.Domain.t()]) :: [Ash.Resource.t()]
  def registered_resources(otp_app) when is_atom(otp_app) do
    domains = Application.get_env(otp_app, :ash_domains, [])
    registered_resources(domains)
  end

  def registered_resources(domains) when is_list(domains) do
    for domain <- domains,
        resource <- Ash.Domain.Info.resources(domain),
        exts = Spark.extensions(resource),
        __MODULE__ in exts or AshRebac in exts,
        uniq: true do
      resource
    end
  end

  @doc """
  Streams an Ash Resource or `Ash.Query` in keyset-paginated batches and writes
  its relationship tuples via `AshAuthzed.Adapter.write_tuples/2`.

  ## Options
    * `:batch_size` - Number of records per chunk (default: `500`)
    * `:reconcile?` - Whether to also emit `:delete` ops for non-matching enum roles (default: `true`)
    * `:dry_run?` - If `true`, computes operations and returns counts without writing to the adapter (default: `false`)
    * `:tenant` - Optional tenant passed to `Ash.stream!/2`
    * `:stream_opts` - Additional options forwarded to `Ash.stream!/2`
    * `:adapter_opts` - Additional options forwarded to `AshAuthzed.Adapter.write_tuples/2`
    * `:on_batch` - Optional callback invoked with running stats after each batch
  """
  @spec backfill(Ash.Resource.t() | Ash.Query.t(), keyword()) ::
          {:ok,
           %{
             records: non_neg_integer(),
             operations: non_neg_integer(),
             batches: non_neg_integer()
           }}
          | {:error, term()}
  def backfill(resource_or_query, opts \\ []) do
    resource = resolve_resource(resource_or_query)
    batch_size = Keyword.get(opts, :batch_size, 500)
    reconcile? = Keyword.get(opts, :reconcile?, true)
    dry_run? = Keyword.get(opts, :dry_run?, false)
    adapter_opts = adapter_config(resource, Keyword.get(opts, :adapter_opts, []))
    on_batch = Keyword.get(opts, :on_batch, fn _stats -> :ok end)

    stream_opts =
      opts
      |> Keyword.get(:stream_opts, [])
      |> Keyword.put(:authorize?, false)
      |> Keyword.put(:batch_size, batch_size)
      |> maybe_put_tenant(opts[:tenant])

    resource_or_query
    |> read_batches(stream_opts, batch_size)
    |> Enum.reduce_while(
      {:ok, %{records: 0, operations: 0, batches: 0}},
      fn batch, {:ok, acc} ->
        ops = AshAuthzed.SyncChange.operations_for_records(batch, reconcile?: reconcile?)

        case persist_batch_ops(ops, dry_run?, adapter_opts) do
          :ok ->
            updated = %{
              records: acc.records + length(batch),
              operations: acc.operations + length(ops),
              batches: acc.batches + 1
            }

            on_batch.(updated)
            {:cont, {:ok, updated}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end
    )
  end

  @doc """
  Backfills all `AshAuthzed`-enabled resources in the given OTP app or domain list.
  """
  @spec backfill_all(atom() | [Ash.Domain.t()], keyword()) ::
          {:ok, %{optional(Ash.Resource.t()) => map()}} | {:error, {Ash.Resource.t(), term()}}
  def backfill_all(otp_app_or_domains, opts \\ []) do
    resources = registered_resources(otp_app_or_domains)

    Enum.reduce_while(resources, {:ok, %{}}, fn resource, {:ok, results} ->
      case backfill(resource, opts) do
        {:ok, stats} -> {:cont, {:ok, Map.put(results, resource, stats)}}
        {:error, reason} -> {:halt, {:error, {resource, reason}}}
      end
    end)
  end

  defp resolve_resource(%Ash.Query{resource: resource}), do: resource
  defp resolve_resource(resource) when is_atom(resource), do: resource

  defp maybe_put_tenant(opts, nil), do: opts
  defp maybe_put_tenant(opts, tenant), do: Keyword.put(opts, :tenant, tenant)

  defp read_batches(resource_or_query, stream_opts, batch_size) do
    resource = resolve_resource(resource_or_query)
    primary_read = Ash.Resource.Info.primary_action(resource, :read)

    if primary_read && primary_read.pagination do
      resource_or_query
      |> Ash.stream!(stream_opts)
      |> Stream.chunk_every(batch_size)
    else
      read_opts = Keyword.take(stream_opts, [:authorize?, :tenant, :actor, :domain])

      resource_or_query
      |> Ash.read!(read_opts)
      |> Enum.chunk_every(batch_size)
    end
  end

  defp persist_batch_ops(_ops, true, _adapter_opts), do: :ok

  defp persist_batch_ops(ops, false, adapter_opts) do
    case AshAuthzed.Adapter.write_tuples(ops, adapter_opts) do
      {:ok, _} -> :ok
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end

defmodule AshRebac do
  @moduledoc """
  Alias for `AshAuthzed` for compatibility with `extensions: [AshRebac]`.
  """
  use Spark.Dsl.Extension,
    sections: AshAuthzed.__sections__(),
    transformers: [AshAuthzed.Transformer],
    verifiers: [AshAuthzed.Verifiers.VerifyZedSchema],
    imports: [AshAuthzed.PolicyMacros]

  defdelegate get_opt(resource, key, default \\ nil), to: AshAuthzed
  defdelegate get_entities(resource), to: AshAuthzed
  defdelegate adapter_config(resource, overrides \\ []), to: AshAuthzed
  defdelegate registered_resources(otp_app_or_domains), to: AshAuthzed
  defdelegate backfill(resource_or_query, opts \\ []), to: AshAuthzed
  defdelegate backfill_all(otp_app_or_domains, opts \\ []), to: AshAuthzed
end
