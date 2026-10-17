defmodule AshAuthzed.Test.Accounts do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshAuthzed.Test.User
  end
end

defmodule AshAuthzed.Test.User do
  @moduledoc false
  use Ash.Resource,
    domain: AshAuthzed.Test.Accounts,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthzed]

  ets do
    private? true
  end

  attributes do
    attribute :id, :string do
      primary_key? true
      allow_nil? false
      writable? true
    end

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :role, :atom do
      constraints one_of: [:user, :admin, :super_admin]
      default :user
      allow_nil? false
      public? true
    end
  end

  actions do
    defaults [:destroy]

    read :read do
      primary? true
      pagination keyset?: true, required?: false
    end

    create :create do
      primary? true
      accept [:id, :name, :role]
    end

    update :update_profile do
      require_atomic? false
      accept [:name]
    end

    update :change_role do
      require_atomic? false
      accept [:role]
    end
  end

  authzed do
    object_type "user_profile"
    adapter :memory
    adapter_opts store: AshAuthzed.Test.MemoryStore

    relation :owner, subject_type: "user", subject_id: :id
    relation :platform, static_subject: "platform:main"

    external_role :role,
      target: "platform:main",
      subject_type: "user",
      subject_id: :id,
      role_mapping: %{user: "member", admin: "admin", super_admin: "super_admin"}

    conditional_wildcard :is_protected_admin,
      subject_type: "user",
      attribute: :role,
      in: [:admin, :super_admin]
  end

  policies do
    policy action(:read) do
      authorize_if rebac_can(:view)
    end

    policy action(:create) do
      authorize_if rebac_can_assign(:role, on: "platform:main")
    end

    policy action(:update_profile) do
      authorize_if rebac_can(:edit)
    end

    policy action(:destroy) do
      authorize_if rebac_can(:delete)
    end

    policy action(:change_role) do
      forbid_unless rebac_can_assign(:role, on: "platform:main")
      authorize_if rebac_can(:change_role)
    end
  end
end
