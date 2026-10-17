defmodule AshAuthzed.Verifiers.VerifyZedSchemaTest do
  use ExUnit.Case, async: true

  import Spark.Test

  test "raises DslError with 'Did you mean?' when a policy references a typo permission" do
    error =
      assert_dsl_error do
        defmodule BrokenPermissionResource do
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            authorizers: [Ash.Policy.Authorizer],
            extensions: [AshAuthzed]

          authzed do
            object_type "user_profile"
            relation :owner, subject_type: "user", subject_id: :id
          end

          attributes do
            uuid_primary_key :id
          end

          actions do
            defaults [:read]
          end

          policies do
            policy action(:read) do
              # Typo: `:veiw` instead of `:view`
              authorize_if authzed_can(:veiw)
            end
          end
        end
      end

    assert error.message =~ "unknown permission `:veiw` on `definition user_profile`"
    assert error.message =~ "Did you mean `view`?"
  end

  test "raises DslError when an Ash enum role value is missing from `definition platform` in .zed" do
    error =
      assert_dsl_error do
        defmodule UnmappedRoleResource do
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            extensions: [AshAuthzed]

          authzed do
            object_type "user_profile"
            external_role :role, target: "platform:main", subject_type: "user", subject_id: :id
          end

          attributes do
            uuid_primary_key :id

            attribute :role, :atom do
              constraints one_of: [:member, :admin, :billing_auditor]
            end
          end

          actions do
            defaults [:read]
          end
        end
      end

    assert error.message =~ "Attribute `:role` allows value `:billing_auditor`"
    assert error.message =~ "missing on `definition platform` in your .zed schema"
  end

  test "raises DslError when a relation or object_type is missing or misspelled" do
    error =
      assert_dsl_error do
        defmodule MisspelledRelationResource do
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            extensions: [AshAuthzed]

          authzed do
            object_type "user_profile"
            # Typo: `:owenr` instead of `:owner`
            relation :owenr, subject_type: "user", subject_id: :id
          end

          attributes do
            uuid_primary_key :id
          end

          actions do
            defaults [:read]
          end
        end
      end

    assert error.message =~ "Relation `:owenr` does not exist on `definition user_profile`"
    assert error.message =~ "Did you mean `owner`?"
  end

  test "raises DslError when authzed_can/2 with :on references an undefined capability on the target definition" do
    error =
      assert_dsl_error do
        defmodule BrokenTargetCapabilityResource do
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            authorizers: [Ash.Policy.Authorizer],
            extensions: [AshAuthzed]

          authzed do
            object_type "managed_item"
            schema_path "priv/licet/admin_capabilities.yaml"
            relation :catalog, static_subject: "catalog:main"
          end

          attributes do
            uuid_primary_key :id
          end

          actions do
            defaults [:read, :create]
          end

          policies do
            policy action(:create) do
              # Typo on target `catalog`: `:admin_creat` instead of `:admin_create`
              authorize_if authzed_can(:admin_creat, on: "catalog:main")
            end
          end
        end
      end

    assert error.message =~ "unknown permission `:admin_creat` on `definition catalog`"
    assert error.message =~ "Did you mean `admin_create`?"
  end

  test "raises DslError when target is missing `:id` or relation subject_id attribute does not exist" do
    target_error =
      assert_dsl_error do
        defmodule MalformedTargetResource do
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            extensions: [AshAuthzed]

          authzed do
            object_type "user_profile"
            relation :platform, static_subject: "platform_without_colon"
          end

          attributes do
            uuid_primary_key :id
          end

          actions do
            defaults [:read]
          end
        end
      end

    assert target_error.message =~ "Invalid target format \"platform_without_colon\""

    attr_error =
      assert_dsl_error do
        defmodule MissingSubjectIdAttrResource do
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            extensions: [AshAuthzed]

          authzed do
            object_type "user_profile"
            relation :owner, subject_type: "user", subject_id: :non_existent_owner_id
          end

          attributes do
            uuid_primary_key :id
          end

          actions do
            defaults [:read]
          end
        end
      end

    assert attr_error.message =~ "Referenced attribute `:non_existent_owner_id` does not exist"
  end

  test "AshRebac works as a full Spark DSL extension alias" do
    defmodule RebacAliasResource do
      use Ash.Resource,
        domain: nil,
        validate_domain_inclusion?: false,
        authorizers: [Ash.Policy.Authorizer],
        extensions: [AshRebac]

      rebac do
        object_type "user_profile"
        relation :owner, subject_type: "user", subject_id: :id
      end

      attributes do
        uuid_primary_key :id
      end

      actions do
        defaults [:read]
      end

      policies do
        policy action(:read) do
          authorize_if rebac_can(:view)
        end
      end
    end

    assert AshRebac.get_opt(RebacAliasResource, :object_type) == "user_profile"
  end
end
