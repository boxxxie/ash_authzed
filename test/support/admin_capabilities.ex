defmodule AshAuthzed.Test.AdminCapabilities.Item do
  @moduledoc false
  use Ash.Resource,
    domain: AshAuthzed.Test.AdminCapabilities,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthzed]

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :admin_id, :uuid, public?: true

    attribute :capability, :atom do
      constraints one_of: [:admin, :can_create, :can_edit, :can_delete]
      public? true
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:title, :admin_id, :capability]
    end

    update :update do
      primary? true
      accept [:title, :admin_id, :capability]
      require_atomic? false
    end
  end

  authzed do
    object_type "managed_item"
    adapter :memory
    adapter_opts store: AshAuthzed.Test.CapabilityMemoryStore
    schema_path "priv/licet/admin_capabilities.yaml"

    relation :catalog, static_subject: "catalog:main"

    external_role :capability,
      subject_type: "user",
      subject_id: :admin_id
  end

  policies do
    policy action(:create) do
      authorize_if authzed_can(:admin_create, target: "catalog:main")
    end

    policy action(:update) do
      authorize_if authzed_can(:admin_edit)
    end

    policy action(:destroy) do
      authorize_if authzed_can(:admin_delete)
    end

    policy action_type(:read) do
      authorize_if authzed_can(:admin_edit)
    end
  end
end

defmodule AshAuthzed.Test.AdminCapabilities do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshAuthzed.Test.AdminCapabilities.Item do
      define :create_item, action: :create
      define :update_item, action: :update
      define :destroy_item, action: :destroy
      define :list_items, action: :read
    end
  end
end
