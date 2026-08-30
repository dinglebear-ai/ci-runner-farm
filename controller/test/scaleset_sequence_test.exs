defmodule CrfController.ScaleSetSequenceTest do
  use ExUnit.Case, async: true

  alias CrfController.ScaleSetSequence

  test "sequence reservations are private, monotonic, and identity-bound" do
    root = Path.join(System.tmp_dir!(), "crf-sequence-#{System.unique_integer([:positive])}")
    path = Path.join(root, "sequence.json")

    assert {:ok, 0} = ScaleSetSequence.load(path, "controller-1")
    assert {:ok, 1} = ScaleSetSequence.reserve(path, "controller-1")
    assert {:ok, 2} = ScaleSetSequence.reserve(path, "controller-1")
    assert {:ok, 2} = ScaleSetSequence.load(path, "controller-1")

    assert {:ok, stat} = File.stat(path)
    assert stat.type == :regular
    if elem(:os.type(), 0) != :win32, do: assert(Bitwise.band(stat.mode, 0o777) == 0o600)

    assert {:error, :invalid_scaleset_sequence_state} =
             ScaleSetSequence.load(path, "controller-2")

    File.rm_rf!(root)
  end

  test "corrupted state fails closed rather than resetting to zero" do
    root =
      Path.join(System.tmp_dir!(), "crf-sequence-corrupt-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    path = Path.join(root, "sequence.json")

    File.write!(
      path,
      ~s({"schema_version":1,"controller_instance_id":"controller-1","sequence":9,"checksum":"bad"})
    )

    File.chmod!(path, 0o600)

    assert {:error, :invalid_scaleset_sequence_state} =
             ScaleSetSequence.load(path, "controller-1")

    assert {:error, :invalid_scaleset_sequence_state} =
             ScaleSetSequence.reserve(path, "controller-1")

    File.rm_rf!(root)
  end

  test "advance_to durably fast-forwards a sidecar replay fence" do
    root =
      Path.join(System.tmp_dir!(), "crf-sequence-advance-#{System.unique_integer([:positive])}")

    path = Path.join(root, "sequence.json")

    assert :ok = ScaleSetSequence.advance_to(path, "controller-1", 41)
    assert {:ok, 42} = ScaleSetSequence.reserve(path, "controller-1")

    assert {:error, :invalid_scaleset_sequence_advance} =
             ScaleSetSequence.advance_to(path, "controller-1", 40)

    File.rm_rf!(root)
  end
end
