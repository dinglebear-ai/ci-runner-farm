defmodule CrfController.WireTest do
  use ExUnit.Case, async: true

  alias CrfController.{PeerIdentity, TestFixtures, TlsOptions, Wire}

  test "decodes a Windows native node without controller platform assumptions" do
    binary = TestFixtures.registration("steamy", 3, :windows, :native_process, "message-1")

    assert {:ok, envelope} = Wire.decode_node_envelope(binary, TestFixtures.peer("steamy"))
    assert envelope.node_id == "steamy"
    assert envelope.node_generation == 3
    assert {:register, node, "0.1.0"} = envelope.payload
    assert node.os == :windows
    assert node.execution_backends == [:native_process]
  end

  test "fully occupied nodes may report zero free resources" do
    binary = TestFixtures.heartbeat("dookie", 7, "message-2", 0, 0, ["placement-1"])

    assert {:ok, envelope} = Wire.decode_node_envelope(binary, TestFixtures.peer("dookie"))
    assert {:heartbeat, available, active} = envelope.payload
    assert available.cpu_millis == 0
    assert available.memory_bytes == 0
    assert active == MapSet.new(["placement-1"])
  end

  test "authenticated certificate identity must match the claimed node" do
    binary = TestFixtures.registration("dookie", 7, :linux, :container, "message-3")

    assert {:error, :authenticated_identity_mismatch} =
             Wire.decode_node_envelope(binary, TestFixtures.peer("steamy"))
  end

  test "unknown wire fields fail closed" do
    binary = TestFixtures.registration("dookie", 7, :linux, :container, "message-4")
    decoded = TestFixtures.decode_json(binary) |> Map.put("surprise", true)
    mutated = :json.encode(decoded) |> IO.iodata_to_binary()

    assert {:error, :unexpected_fields} =
             Wire.decode_node_envelope(mutated, TestFixtures.peer("dookie"))
  end

  test "response envelopes are versioned and typed" do
    assert {:ok, binary} = Wire.encode_response("message-5", :duplicate, nil)
    response = TestFixtures.decode_json(binary)
    assert response["protocol_version"] == 1
    assert response["message_id"] == "message-5"
    assert response["status"] == "duplicate"
    assert response["code"] == :null
    assert response["command"] == :null
  end

  test "peer identity fingerprints the authenticated certificate" do
    assert {:ok, peer} = PeerIdentity.from_authenticated_certificate("dookie", "certificate")

    expected = :crypto.hash(:sha256, "certificate") |> Base.encode16(case: :lower)
    assert peer.certificate_sha256 == expected
  end

  test "TLS server options require mutual authentication and TLS 1.3" do
    assert {:ok, options} =
             TlsOptions.server(
               certfile: "/etc/crf/controller.pem",
               keyfile: "/etc/crf/controller-key.pem",
               cacertfile: "/etc/crf/ca.pem"
             )

    assert Keyword.fetch!(options, :verify) == :verify_peer
    assert Keyword.fetch!(options, :fail_if_no_peer_cert) == true
    assert Keyword.fetch!(options, :versions) == [:"tlsv1.3"]
    assert Keyword.fetch!(options, :cacertfile) == ~c"/etc/crf/ca.pem"
  end
end
