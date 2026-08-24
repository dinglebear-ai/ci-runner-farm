defmodule CrfController.ScaleSetEligibilityTest do
  use ExUnit.Case, async: true

  alias CrfController.ScaleSetEligibility

  test "eligibility is private, round-trips, and identity-bound" do
    root = Path.join(System.tmp_dir!(), "crf-eligibility-#{System.unique_integer([:positive])}")
    path = Path.join(root, "eligibility.json")

    assert {:ok, nil} = ScaleSetEligibility.load(path, "controller-1")

    assert :ok = ScaleSetEligibility.persist(path, "controller-1", false)
    assert {:ok, false} = ScaleSetEligibility.load(path, "controller-1")

    assert :ok = ScaleSetEligibility.persist(path, "controller-1", true)
    assert {:ok, true} = ScaleSetEligibility.load(path, "controller-1")

    assert {:ok, stat} = File.stat(path)
    assert stat.type == :regular
    if elem(:os.type(), 0) != :win32, do: assert(Bitwise.band(stat.mode, 0o777) == 0o600)

    assert {:error, :invalid_scaleset_eligibility_state} =
             ScaleSetEligibility.load(path, "controller-2")

    File.rm_rf!(root)
  end

  test "corrupted state fails closed rather than defaulting" do
    root =
      Path.join(
        System.tmp_dir!(),
        "crf-eligibility-corrupt-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    path = Path.join(root, "eligibility.json")

    File.write!(
      path,
      ~s({"schema_version":1,"controller_instance_id":"controller-1","eligible":false,"checksum":"bad"})
    )

    File.chmod!(path, 0o600)

    assert {:error, :invalid_scaleset_eligibility_state} =
             ScaleSetEligibility.load(path, "controller-1")

    File.rm_rf!(root)
  end

  test "rejects an invalid path or controller identity" do
    assert {:error, :invalid_scaleset_eligibility_path} =
             ScaleSetEligibility.load("relative/path.json", "controller-1")

    assert {:error, :invalid_controller_instance_id} =
             ScaleSetEligibility.persist("/tmp/eligibility.json", "", true)
  end
end
