defmodule CrfController.PeerRegistryTest do
  use ExUnit.Case, async: true

  alias CrfController.PeerRegistry

  setup do
    cert_a = "dookie-certificate-a"
    cert_b = "dookie-certificate-b"
    fingerprint_a = fingerprint(cert_a)
    fingerprint_b = fingerprint(cert_b)

    registry =
      start_supervised!({PeerRegistry, name: nil, peers: [{fingerprint_a, "dookie"}]})

    %{
      registry: registry,
      cert_a: cert_a,
      cert_b: cert_b,
      fingerprint_a: fingerprint_a,
      fingerprint_b: fingerprint_b
    }
  end

  test "rotation overlap authorizes old and new fingerprints before old revocation", ctx do
    assert {:ok, old_peer} = PeerRegistry.authorize_certificate(ctx.registry, ctx.cert_a)

    assert %{revision: 1, peer_count: 1, node_count: 1, nodes: ["dookie"]} =
             PeerRegistry.status(ctx.registry)

    assert {:ok, %{revision: 2, peer_count: 2}} =
             PeerRegistry.replace_peers(ctx.registry, [
               {ctx.fingerprint_a, "dookie"},
               {ctx.fingerprint_b, "dookie"}
             ])

    assert :ok = PeerRegistry.authorize_identity(ctx.registry, old_peer)
    assert {:ok, new_peer} = PeerRegistry.authorize_certificate(ctx.registry, ctx.cert_b)
    assert :ok = PeerRegistry.authorize_identity(ctx.registry, new_peer)

    assert {:ok, %{revision: 3, peer_count: 1}} =
             PeerRegistry.replace_peers(ctx.registry, [{ctx.fingerprint_b, "dookie"}])

    assert {:error, :unauthorized_certificate} =
             PeerRegistry.authorize_identity(ctx.registry, old_peer)

    assert :ok = PeerRegistry.authorize_identity(ctx.registry, new_peer)
  end

  test "malformed replacement is atomic and does not change active authorization", ctx do
    assert {:ok, peer} = PeerRegistry.authorize_certificate(ctx.registry, ctx.cert_a)

    assert {:error, :invalid_fingerprint} =
             PeerRegistry.replace_peers(ctx.registry, [{"not-a-fingerprint", "dookie"}])

    assert %{revision: 1, peer_count: 1} = PeerRegistry.status(ctx.registry)
    assert :ok = PeerRegistry.authorize_identity(ctx.registry, peer)
  end

  test "live registry may revoke every peer even though boot config may not be empty", ctx do
    assert {:ok, peer} = PeerRegistry.authorize_certificate(ctx.registry, ctx.cert_a)

    assert {:ok, %{revision: 2, peer_count: 0, node_count: 0, nodes: []}} =
             PeerRegistry.replace_peers(ctx.registry, [])

    assert {:error, :unauthorized_certificate} =
             PeerRegistry.authorize_identity(ctx.registry, peer)

    assert {:error, :unauthorized_certificate} =
             PeerRegistry.authorize_certificate(ctx.registry, ctx.cert_a)
  end

  defp fingerprint(certificate) do
    :crypto.hash(:sha256, certificate) |> Base.encode16(case: :lower)
  end
end
