if Code.ensure_loaded?(Req) do
  defmodule AshAuthzed.Adapters.SpiceDBHttp do
    @moduledoc """
    Adapter for communicating with an external SpiceDB / Authzed server over HTTP/JSON via `Req`.

    ## Options

    * `:url` - Base URL of the SpiceDB HTTP server. Defaults to `"http://localhost:8443"`.
    * `:token` - Preshared key / Bearer token for SpiceDB authentication. Defaults to `"secret"`.
    * `:req_options` - Additional options forwarded directly to `Req.post/2` (such as `:plug` for testing).
    """

    @behaviour AshAuthzed.Adapter

    alias AshAuthzed.Error
    alias Licet.Relationship

    @impl true
    def check(resource, permission, subject, opts) do
      with {:ok, res_map} <- parse_object(resource),
           {:ok, sub_map} <- parse_subject(subject) do
        payload =
          %{
            resource: res_map,
            permission: to_string(permission),
            subject: sub_map
          }
          |> maybe_put_consistency(opts[:consistency])

        case post("/v1/permissions/check", payload, opts) do
          {:ok, %{"permissionship" => "PERMISSIONSHIP_HAS_PERMISSION"}} ->
            {:ok, true}

          {:ok, %{"permissionship" => _}} ->
            {:ok, false}

          {:ok, unexpected} ->
            {:error, Error.new(:unexpected_spicedb_response, unexpected)}

          {:error, _} = err ->
            err
        end
      end
    end

    @impl true
    def lookup_resources(resource_type, permission, subject, opts) do
      with {:ok, sub_map} <- parse_subject(subject) do
        payload =
          %{
            resourceObjectType: resource_type,
            permission: to_string(permission),
            subject: sub_map
          }
          |> maybe_put_consistency(opts[:consistency])

        case post("/v1/permissions/resources", payload, opts) do
          {:ok, body} ->
            {:ok, extract_resource_ids(body)}

          {:error, _} = err ->
            err
        end
      end
    end

    @impl true
    def write_tuples([], _opts), do: {:ok, :noop}

    def write_tuples(operations, opts) do
      with {:ok, updates} <- build_updates(operations) do
        case post("/v1/relationships/write", %{updates: updates}, opts) do
          {:ok, %{"writtenAt" => %{"token" => token}}} ->
            {:ok, token}

          {:ok, body} ->
            {:ok, body}

          {:error, _} = err ->
            err
        end
      end
    end

    @impl true
    def apply_schema(schema_text, opts) do
      case post("/v1/schema/write", %{schema: schema_text}, opts) do
        {:ok, %{"writtenAt" => %{"token" => token}}} ->
          {:ok, token}

        {:ok, body} ->
          {:ok, body}

        {:error, _} = err ->
          err
      end
    end

    @doc """
    Converts a Zanzibar relationship tuple string into a SpiceDB JSON relationship map.
    """
    @spec parse_tuple_to_json(String.t()) :: {:ok, map()} | {:error, Error.t()}
    def parse_tuple_to_json(tuple_str) when is_binary(tuple_str) do
      case Relationship.parse(tuple_str) do
        {:ok, rel} ->
          subject_obj = %{
            objectType: rel.subject_type,
            objectId: rel.subject_id
          }

          subject =
            if rel.subject_relation != "" do
              %{object: subject_obj, optionalRelation: rel.subject_relation}
            else
              %{object: subject_obj}
            end

          {:ok,
           %{
             resource: %{
               objectType: rel.resource_type,
               objectId: rel.resource_id
             },
             relation: rel.relation,
             subject: subject
           }}

        {:error, reason} ->
          {:error, Error.new(:invalid_tuple, reason)}
      end
    end

    defp build_updates(operations) do
      Enum.reduce_while(operations, {:ok, []}, fn {op, tuple_str}, {:ok, acc} ->
        spicedb_op =
          case op do
            :create -> "OPERATION_TOUCH"
            :touch -> "OPERATION_TOUCH"
            :delete -> "OPERATION_DELETE"
          end

        case parse_tuple_to_json(tuple_str) do
          {:ok, rel_json} ->
            {:cont, {:ok, [%{operation: spicedb_op, relationship: rel_json} | acc]}}

          {:error, _} = err ->
            {:halt, err}
        end
      end)
      |> case do
        {:ok, list} -> {:ok, Enum.reverse(list)}
        error -> error
      end
    end

    defp parse_object(str) when is_binary(str) do
      case String.split(str, ":", parts: 2) do
        [type, id] when type != "" and id != "" ->
          {:ok, %{objectType: type, objectId: id}}

        _ ->
          {:error, Error.new(:invalid_object, "Expected `type:id`, got: #{inspect(str)}")}
      end
    end

    defp parse_subject(str) when is_binary(str) do
      case String.split(str, "#", parts: 2) do
        [obj_part, rel] ->
          with {:ok, obj} <- parse_object(obj_part) do
            {:ok, %{object: obj, optionalRelation: rel}}
          end

        [obj_part] ->
          with {:ok, obj} <- parse_object(obj_part) do
            {:ok, %{object: obj}}
          end
      end
    end

    defp extract_resource_ids(%{"results" => results}) when is_list(results) do
      Enum.flat_map(results, &extract_id_from_item/1)
    end

    defp extract_resource_ids(%{"result" => %{"resourceObjectId" => id}}) when is_binary(id),
      do: [id]

    defp extract_resource_ids(%{"resourceObjectId" => id}) when is_binary(id), do: [id]

    defp extract_resource_ids(body) when is_binary(body) do
      body
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case Jason.decode(line) do
          {:ok, decoded} -> extract_id_from_item(decoded)
          _ -> []
        end
      end)
    end

    defp extract_resource_ids(_), do: []

    defp extract_id_from_item(%{"result" => %{"resourceObjectId" => id}}), do: [id]
    defp extract_id_from_item(%{"resourceObjectId" => id}), do: [id]
    defp extract_id_from_item(_), do: []

    defp maybe_put_consistency(payload, nil), do: payload

    defp maybe_put_consistency(payload, :fully_consistent) do
      Map.put(payload, :consistency, %{fullyConsistent: true})
    end

    defp maybe_put_consistency(payload, :full) do
      Map.put(payload, :consistency, %{fullyConsistent: true})
    end

    defp maybe_put_consistency(payload, :minimize_latency) do
      Map.put(payload, :consistency, %{minimizeLatency: true})
    end

    defp maybe_put_consistency(payload, {:at_least_as_fresh, token}) when is_binary(token) do
      Map.put(payload, :consistency, %{atLeastAsFresh: %{token: token}})
    end

    defp maybe_put_consistency(payload, {:at_exact_snapshot, token}) when is_binary(token) do
      Map.put(payload, :consistency, %{atExactSnapshot: %{token: token}})
    end

    defp maybe_put_consistency(payload, consistency) when is_map(consistency) do
      Map.put(payload, :consistency, consistency)
    end

    defp post(path, payload, opts) do
      url = Keyword.get(opts, :url, "http://localhost:8443")
      token = Keyword.get(opts, :token, "secret")
      req_opts = Keyword.get(opts, :req_options, [])

      request_opts =
        [
          url: String.trim_trailing(url, "/") <> path,
          headers: [{"authorization", "Bearer #{token}"}],
          json: payload,
          decode_body: false
        ]
        |> Keyword.merge(req_opts)

      case Req.post(request_opts) do
        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          {:ok, normalize_body(body)}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, Error.new(:spicedb_http_error, %{status: status, body: normalize_body(body)})}

        {:error, exception} ->
          {:error, Error.new(:spicedb_request_failed, exception)}
      end
    end

    defp normalize_body(body) when is_binary(body) do
      case Jason.decode(body) do
        {:ok, decoded} -> decoded
        {:error, _} -> body
      end
    end

    defp normalize_body(body), do: body
  end
end
