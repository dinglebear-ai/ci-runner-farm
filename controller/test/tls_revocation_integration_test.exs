defmodule CrfController.TlsRevocationIntegrationTest do
  use ExUnit.Case, async: false

  alias CrfController.{
    Framing,
    Ingress,
    NodeMailbox,
    NodeRegistry,
    PeerRegistry,
    PlacementLedger,
    TestFixtures,
    TlsServer
  }

  @openssl System.find_executable("openssl")

  if not is_nil(@openssl) and elem(:os.type(), 0) != :win32 do
    test "authenticated TLS sessions survive command processing beyond the handshake timeout" do
      root = Path.join(System.tmp_dir!(), "crf-tls-idle-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      pki = create_pki(root)
      on_exit(fn -> File.rm_rf(root) end)

      registry = start_supervised!({NodeRegistry, name: nil, stale_after_ms: 10_000})
      placements = start_supervised!({PlacementLedger, name: nil})
      mailbox = start_supervised!({NodeMailbox, name: nil, capacity: 16})

      ingress =
        start_supervised!(
          {Ingress,
           name: nil,
           node_registry: registry,
           placement_ledger: placements,
           node_mailbox: mailbox,
           ledger_capacity: 16}
        )

      peer_registry =
        start_supervised!({PeerRegistry, name: nil, peers: [{pki.client_fingerprint, "dookie"}]})

      {:ok, connection_supervisor} = Task.Supervisor.start_link()

      tls =
        start_supervised!(
          {TlsServer,
           name: nil,
           port: 0,
           ingress: ingress,
           connection_supervisor: connection_supervisor,
           peer_registry: peer_registry,
           peers: [{pki.client_fingerprint, "dookie"}],
           certfile: pki.server_cert,
           keyfile: pki.server_key,
           cacertfile: pki.ca_cert,
           handshake_timeout: 1_000,
           idle_timeout: 5_000}
        )

      assert {:ok, socket} = connect(TlsServer.port(tls), pki)

      registration = TestFixtures.registration("dookie", 7, :linux, :container, "message-1")
      assert :ok = send_frame(socket, registration)
      assert {:ok, registration_response} = recv_frame(socket)
      assert TestFixtures.decode_json(registration_response)["status"] == "accepted"

      Process.sleep(1_100)

      heartbeat =
        TestFixtures.heartbeat("dookie", 7, "message-2", 8_000, 16 * 1024 * 1024 * 1024, [])

      assert :ok = send_frame(socket, heartbeat)
      assert {:ok, heartbeat_response} = recv_frame(socket)
      assert TestFixtures.decode_json(heartbeat_response)["status"] == "accepted"
    end

    test "authenticated idle TLS sessions close and release their connection task" do
      root = Path.join(System.tmp_dir!(), "crf-tls-timeout-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      pki = create_pki(root)
      on_exit(fn -> File.rm_rf(root) end)

      registry = start_supervised!({NodeRegistry, name: nil, stale_after_ms: 10_000})
      placements = start_supervised!({PlacementLedger, name: nil})
      mailbox = start_supervised!({NodeMailbox, name: nil, capacity: 16})

      ingress =
        start_supervised!(
          {Ingress,
           name: nil,
           node_registry: registry,
           placement_ledger: placements,
           node_mailbox: mailbox,
           ledger_capacity: 16}
        )

      peer_registry =
        start_supervised!({PeerRegistry, name: nil, peers: [{pki.client_fingerprint, "dookie"}]})

      {:ok, connection_supervisor} = Task.Supervisor.start_link(max_children: 2)

      tls =
        start_supervised!(
          {TlsServer,
           name: nil,
           port: 0,
           ingress: ingress,
           connection_supervisor: connection_supervisor,
           peer_registry: peer_registry,
           peers: [{pki.client_fingerprint, "dookie"}],
           certfile: pki.server_cert,
           keyfile: pki.server_key,
           cacertfile: pki.ca_cert,
           handshake_timeout: 1_000,
           idle_timeout: 150}
        )

      assert {:ok, socket} = connect(TlsServer.port(tls), pki)

      assert eventually(fn ->
               Task.Supervisor.children(connection_supervisor) |> length() == 2
             end)

      assert {:error, :closed} = :ssl.recv(socket, Framing.header_bytes(), 2_000)

      assert eventually(fn ->
               Task.Supervisor.children(connection_supervisor) |> length() == 1
             end)
    end

    test "revoking a fingerprint closes an already-authenticated TLS session on its next frame" do
      root = Path.join(System.tmp_dir!(), "crf-tls-revoke-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      pki = create_pki(root)
      on_exit(fn -> File.rm_rf(root) end)

      registry = start_supervised!({NodeRegistry, name: nil, stale_after_ms: 10_000})
      placements = start_supervised!({PlacementLedger, name: nil})
      mailbox = start_supervised!({NodeMailbox, name: nil, capacity: 16})

      ingress =
        start_supervised!(
          {Ingress,
           name: nil,
           node_registry: registry,
           placement_ledger: placements,
           node_mailbox: mailbox,
           ledger_capacity: 16}
        )

      peer_registry =
        start_supervised!({PeerRegistry, name: nil, peers: [{pki.client_fingerprint, "dookie"}]})

      {:ok, connection_supervisor} = Task.Supervisor.start_link()

      tls =
        start_supervised!(
          {TlsServer,
           name: nil,
           port: 0,
           ingress: ingress,
           connection_supervisor: connection_supervisor,
           peer_registry: peer_registry,
           peers: [{pki.client_fingerprint, "dookie"}],
           certfile: pki.server_cert,
           keyfile: pki.server_key,
           cacertfile: pki.ca_cert,
           handshake_timeout: 5_000}
        )

      port = TlsServer.port(tls)

      assert {:ok, socket} =
               :ssl.connect(
                 ~c"127.0.0.1",
                 port,
                 [
                   mode: :binary,
                   active: false,
                   verify: :verify_peer,
                   versions: [:"tlsv1.3"],
                   cacertfile: String.to_charlist(pki.ca_cert),
                   certfile: String.to_charlist(pki.client_cert),
                   keyfile: String.to_charlist(pki.client_key),
                   server_name_indication: ~c"localhost"
                 ],
                 5_000
               )

      registration = TestFixtures.registration("dookie", 7, :linux, :container, "message-1")
      assert :ok = send_frame(socket, registration)
      assert {:ok, registration_response} = recv_frame(socket)
      assert TestFixtures.decode_json(registration_response)["status"] == "accepted"

      assert {:ok, %{peer_count: 0}} = PeerRegistry.revoke_all(peer_registry)

      heartbeat =
        TestFixtures.heartbeat("dookie", 7, "message-2", 8_000, 16 * 1024 * 1024 * 1024, [])

      assert :ok = send_frame(socket, heartbeat)
      assert {:error, :closed} = :ssl.recv(socket, Framing.header_bytes(), 5_000)
      assert [%{id: "dookie", generation: 7}] = NodeRegistry.snapshot(registry)
    end
  else
    test "live TLS revocation integration requires OpenSSL on Unix" do
      assert true
    end
  end

  defp eventually(fun, attempts \\ 40)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(25)
      eventually(fun, attempts - 1)
    end
  end

  defp create_pki(root) do
    ca_key = Path.join(root, "ca.key")
    ca_cert = Path.join(root, "ca.pem")
    server_key = Path.join(root, "server.key")
    server_csr = Path.join(root, "server.csr")
    server_cert = Path.join(root, "server.pem")
    server_ext = Path.join(root, "server.ext")
    client_key = Path.join(root, "client.key")
    client_csr = Path.join(root, "client.csr")
    client_cert = Path.join(root, "client.pem")
    client_ext = Path.join(root, "client.ext")

    openssl!([
      "req",
      "-x509",
      "-newkey",
      "rsa:2048",
      "-sha256",
      "-nodes",
      "-days",
      "1",
      "-subj",
      "/CN=CRF-Test-CA",
      "-keyout",
      ca_key,
      "-out",
      ca_cert
    ])

    File.write!(server_ext, "subjectAltName=DNS:localhost,IP:127.0.0.1
extendedKeyUsage=serverAuth
keyUsage=digitalSignature,keyEncipherment
")

    openssl!([
      "req",
      "-new",
      "-newkey",
      "rsa:2048",
      "-sha256",
      "-nodes",
      "-subj",
      "/CN=localhost",
      "-keyout",
      server_key,
      "-out",
      server_csr
    ])

    openssl!([
      "x509",
      "-req",
      "-in",
      server_csr,
      "-CA",
      ca_cert,
      "-CAkey",
      ca_key,
      "-CAcreateserial",
      "-days",
      "1",
      "-sha256",
      "-extfile",
      server_ext,
      "-out",
      server_cert
    ])

    File.write!(client_ext, "extendedKeyUsage=clientAuth
keyUsage=digitalSignature,keyEncipherment
")

    openssl!([
      "req",
      "-new",
      "-newkey",
      "rsa:2048",
      "-sha256",
      "-nodes",
      "-subj",
      "/CN=dookie",
      "-keyout",
      client_key,
      "-out",
      client_csr
    ])

    openssl!([
      "x509",
      "-req",
      "-in",
      client_csr,
      "-CA",
      ca_cert,
      "-CAkey",
      ca_key,
      "-CAserial",
      Path.join(root, "ca.srl"),
      "-days",
      "1",
      "-sha256",
      "-extfile",
      client_ext,
      "-out",
      client_cert
    ])

    [{:Certificate, client_der, :not_encrypted}] =
      client_cert |> File.read!() |> :public_key.pem_decode()

    %{
      ca_cert: ca_cert,
      server_key: server_key,
      server_cert: server_cert,
      client_key: client_key,
      client_cert: client_cert,
      client_fingerprint: :crypto.hash(:sha256, client_der) |> Base.encode16(case: :lower)
    }
  end

  defp openssl!(args) do
    {output, status} = System.cmd(@openssl, args, stderr_to_stdout: true)
    assert status == 0, "OpenSSL failed: #{output}"
    :ok
  end

  defp send_frame(socket, payload) do
    with {:ok, frame} <- Framing.encode(payload), do: :ssl.send(socket, frame)
  end

  defp connect(port, pki) do
    :ssl.connect(
      ~c"127.0.0.1",
      port,
      [
        mode: :binary,
        active: false,
        verify: :verify_peer,
        versions: [:"tlsv1.3"],
        cacertfile: String.to_charlist(pki.ca_cert),
        certfile: String.to_charlist(pki.client_cert),
        keyfile: String.to_charlist(pki.client_key),
        server_name_indication: ~c"localhost"
      ],
      5_000
    )
  end

  defp recv_frame(socket) do
    with {:ok, <<length::unsigned-big-integer-size(32)>>} <-
           :ssl.recv(socket, Framing.header_bytes(), 5_000),
         {:ok, payload} <- :ssl.recv(socket, length, 5_000) do
      {:ok, payload}
    end
  end
end
