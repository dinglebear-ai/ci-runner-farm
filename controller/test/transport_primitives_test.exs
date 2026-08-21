defmodule CrfController.TransportPrimitivesTest do
  use ExUnit.Case, async: true

  alias CrfController.{Framing, PeerAuthorizer}

  test "length-prefixed framing round trips and enforces the shared ceiling" do
    payload = ~s({"protocol_version":1})
    assert {:ok, frame} = Framing.encode(payload)
    length = byte_size(payload)
    assert <<^length::unsigned-big-integer-size(32), ^payload::binary>> = frame
    assert {:ok, ^payload} = Framing.decode(frame)

    assert {:error, :invalid_frame_payload} = Framing.encode("")

    assert {:error, :invalid_frame_payload} =
             Framing.encode(:binary.copy("x", Framing.max_payload_bytes() + 1))

    assert {:error, :invalid_frame} = Framing.decode(<<0, 0, 0, 5, "x">>)
  end

  test "certificate fingerprints are explicitly mapped to node identities" do
    certificate = "dookie-client-certificate"
    fingerprint = :crypto.hash(:sha256, certificate) |> Base.encode16(case: :lower)

    assert {:ok, authorizer} = PeerAuthorizer.new([{fingerprint, "dookie"}])
    assert {:ok, peer} = PeerAuthorizer.authorize(authorizer, certificate)
    assert peer.node_id == "dookie"
    assert peer.certificate_sha256 == fingerprint

    assert {:error, :unauthorized_certificate} =
             PeerAuthorizer.authorize(authorizer, "different-certificate")
  end

  test "authorizer rejects malformed fingerprints and ambiguous duplicates" do
    assert {:error, :invalid_fingerprint} = PeerAuthorizer.new([{"not-a-fingerprint", "dookie"}])

    fingerprint = String.duplicate("a", 64)

    assert {:error, :duplicate_or_invalid_identity} =
             PeerAuthorizer.new([{fingerprint, "dookie"}, {fingerprint, "steamy"}])
  end
end
