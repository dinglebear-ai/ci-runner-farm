defmodule CrfController.OperatorActionsTest do
  use ExUnit.Case, async: true

  alias CrfController.{NodeRegistry, OperatorActions}

  test "drains only the exact current node generation" do
    {:ok, registry} = start_supervised({NodeRegistry, name: nil})

    assert {:ok, _} =
             NodeRegistry.register(
               registry,
               %{
                 id: "unraid-1",
                 generation: 7,
                 os: :linux,
                 arch: :x86_64,
                 execution_backends: [:container],
                 capabilities: ["container", "github-actions"],
                 total: %{cpu_millis: 8_000, memory_bytes: 16_000},
                 available: %{cpu_millis: 6_000, memory_bytes: 12_000}
               },
               now_ms: 100
             )

    assert {:ok, %{node_id: "unraid-1", generation: 7, draining: true}} =
             OperatorActions.set_draining("unraid-1", 7, true, registry)

    assert {:error, :generation_mismatch} =
             OperatorActions.set_draining("unraid-1", 6, false, registry)

    assert {:error, :invalid_node_id} =
             OperatorActions.set_draining("../escape", 7, true, registry)
  end

  test "force abandon requires a literal force acknowledgement" do
    assert {:error, :explicit_force_required} =
             OperatorActions.force_abandon("placement-1", false, self())

    assert {:error, :invalid_force_abandon_request} =
             OperatorActions.force_abandon("placement-1", :yes, self())
  end
end
