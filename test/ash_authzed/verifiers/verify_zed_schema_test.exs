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
end
