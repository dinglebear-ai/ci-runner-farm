defmodule CrfController.OperatorProjectionTest do
  use ExUnit.Case, async: true

  alias CrfController.OperatorProjection

  test "does not silently omit a valid projection when collection takes longer than 250ms" do
    snapshot = fn ->
      Process.sleep(300)
      %{schema_version: 1, nodes: []}
    end

    assert %{
             "schema_version" => 1,
             "controller_instance_id" => "controller",
             "observed_at_unix_ms" => 1_750_000_000_000
           } = OperatorProjection.build("controller", 1_750_000_000_000, snapshot)
  end

  test "serializes timestamp structs in operator state" do
    timestamp = ~U[2026-08-24 01:05:06.325150Z]

    assert %{"peer_authorization" => %{"loaded_at" => "2026-08-24T01:05:06.325150Z"}} =
             OperatorProjection.build("controller", 1_750_000_000_000, fn ->
               %{schema_version: 1, peer_authorization: %{loaded_at: timestamp}}
             end)
  end
end
