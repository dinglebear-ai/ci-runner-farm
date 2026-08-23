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
end
