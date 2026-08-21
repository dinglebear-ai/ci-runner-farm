defmodule CrfController.PoolPolicyTest do
  use ExUnit.Case, async: true

  alias CrfController.{PoolPolicy, WorkIdentity}

  @gib 1024 * 1024 * 1024

  test "pool policy produces the exact Rust scheduler requirement" do
    assert {:ok, policy} =
             PoolPolicy.new(%{
               id: "windows",
               max_concurrency: 8,
               resources: %{cpu_millis: 4_000, memory_bytes: 8 * @gib},
               required_os: :windows,
               required_arch: :x86_64,
               required_backend: :native_process,
               required_capabilities: ["github-actions", "windows-sdk"],
               work_folder: "_work"
             })

    assert {:ok, requirement} = PoolPolicy.work_requirement(policy, "work-1")
    assert requirement.pool_id == "windows"
    assert requirement.required_os == :windows
    assert requirement.required_backend == :native_process
    assert requirement.resources.cpu_millis == 4_000

    assert MapSet.new(requirement.required_capabilities) ==
             MapSet.new(["github-actions", "windows-sdk"])
  end

  test "pool fuse and unsafe work folders fail closed" do
    base = %{
      id: "build",
      max_concurrency: 64,
      resources: %{cpu_millis: 2_000, memory_bytes: 4 * @gib},
      required_os: :linux,
      required_arch: :x86_64,
      required_backend: :native_process,
      required_capabilities: [],
      work_folder: "_work"
    }

    assert {:ok, _} = PoolPolicy.new(base)
    assert {:error, :invalid_pool_policy} = PoolPolicy.new(%{base | max_concurrency: 65})
    assert {:error, :invalid_pool_policy} = PoolPolicy.new(%{base | work_folder: "../escape"})
  end

  test "work identity is deterministic, bounded, and changes across handle or scale set" do
    assert {:ok, first} = WorkIdentity.for_handle("build", 74, 501)
    assert {:ok, replay} = WorkIdentity.for_handle("build", 74, 501)
    assert first == replay

    assert {:ok, different_handle} = WorkIdentity.for_handle("build", 74, 502)
    assert {:ok, different_scale_set} = WorkIdentity.for_handle("build", 75, 501)
    refute first == different_handle
    refute first == different_scale_set

    for value <- Map.values(first) do
      assert is_binary(value)
      assert byte_size(value) <= 128
    end
  end
end
