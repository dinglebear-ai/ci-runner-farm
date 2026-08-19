defmodule CrfController.ControllerConfigTest do
  use ExUnit.Case, async: false

  alias CrfController.{Application, ControllerConfig, PoolPolicy}

  @revision String.duplicate("a", 64)
  @fingerprint String.duplicate("B", 64)

  setup do
    root =
      Path.join(System.tmp_dir!(), "crf-controller-config-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    scheduler = touch(root, "crf-scheduler")
    cert = touch(root, "controller.crt")
    key = touch(root, "controller.key")
    ca = touch(root, "ca.crt")

    on_exit(fn ->
      File.rm_rf!(root)
      System.delete_env("CRF_CONTROLLER_CONFIG")
    end)

    %{root: root, scheduler: scheduler, cert: cert, key: key, ca: ca}
  end

  test "loads a strict complete distributed controller config", ctx do
    path = write_config(ctx, config(ctx))

    assert {:ok, %ControllerConfig{} = parsed} = ControllerConfig.load(path)
    assert parsed.scheduler_opts[:executable] == ctx.scheduler
    assert parsed.scheduler_opts[:request_timeout_ms] == 5_000
    assert parsed.placement_opts[:state_path] == Path.join(ctx.root, "placements.json")
    assert parsed.node_registry_opts[:stale_after_ms] == 15_000
    assert parsed.scaleset_opts[:socket_path] == Path.join(ctx.root, "scaleset.sock")
    assert parsed.scaleset_opts[:sequence_path] == Path.join(ctx.root, "sequence.json")
    assert parsed.scaleset_opts[:controller_instance_id] == "controller-1"
    assert parsed.tls_opts[:port] == 7443
    assert parsed.tls_opts[:peers] == [{String.downcase(@fingerprint), "dookie"}]
    assert parsed.demand_opts[:auto_reconcile]
    assert parsed.demand_opts[:reconcile_interval_ms] == 1_000
    assert [%PoolPolicy{id: "build", required_os: :linux}] = parsed.demand_opts[:policies]
  end

  test "unknown fields and duplicate pools fail closed", ctx do
    base = config(ctx)
    unexpected = put_in(base, ["demand", "surprise"], true)
    assert {:error, :unexpected_controller_config_fields} = ControllerConfig.parse(unexpected)

    [pool] = base["demand"]["pools"]
    duplicate = put_in(base, ["demand", "pools"], [pool, pool])
    assert {:error, :duplicate_pool_policy} = ControllerConfig.parse(duplicate)
  end

  test "relative paths and malformed revisions fail closed", ctx do
    relative = put_in(config(ctx), ["scaleset", "socket_path"], "relative.sock")
    assert {:error, :invalid_scaleset_socket} = ControllerConfig.parse(relative)

    revision = put_in(config(ctx), ["scaleset", "config_revision"], String.duplicate("g", 64))
    assert {:error, :invalid_scaleset_revision} = ControllerConfig.parse(revision)
  end

  test "managed scale-set sidecar uses the same socket and sealed evidence files", ctx do
    executable = touch(ctx.root, "crf-scaleset")
    runtime = touch(ctx.root, "scaleset-runtime.json")
    compatibility = touch(ctx.root, "scaleset-compatibility.json")

    managed =
      put_in(config(ctx), ["sidecar"], %{
        "executable" => executable,
        "runtime_config" => runtime,
        "compatibility" => compatibility,
        "startup_timeout_ms" => 15_000
      })

    assert {:ok, parsed} = ControllerConfig.parse(managed)
    assert parsed.sidecar_opts[:executable] == executable
    assert parsed.sidecar_opts[:socket_path] == Path.join(ctx.root, "scaleset.sock")
    assert parsed.sidecar_opts[:runtime_config] == runtime
    assert parsed.sidecar_opts[:compatibility] == compatibility

    if elem(:os.type(), 0) != :win32 do
      File.chmod!(runtime, 0o644)
      assert {:error, :invalid_scaleset_runtime_config} = ControllerConfig.parse(managed)
    end
  end

  test "managed sidecar is supervised before the scale-set client", ctx do
    executable = touch(ctx.root, "crf-scaleset-managed")
    runtime = touch(ctx.root, "managed-runtime.json")
    compatibility = touch(ctx.root, "managed-compatibility.json")

    managed =
      put_in(config(ctx), ["sidecar"], %{
        "executable" => executable,
        "runtime_config" => runtime,
        "compatibility" => compatibility,
        "startup_timeout_ms" => 15_000
      })

    path = write_config(ctx, managed)
    System.put_env("CRF_CONTROLLER_CONFIG", path)
    assert {:ok, children} = Application.children_from_environment()
    modules = child_modules(children)

    sidecar_index = Enum.find_index(modules, &(&1 == CrfController.ScaleSetSidecar))
    client_index = Enum.find_index(modules, &(&1 == CrfController.ScaleSetClient))
    assert is_integer(sidecar_index) and is_integer(client_index)
    assert sidecar_index < client_index
  end

  test "controller config file must not be group/world readable on Unix", ctx do
    path = write_config(ctx, config(ctx))

    if elem(:os.type(), 0) == :win32 do
      assert {:ok, _} = ControllerConfig.load(path)
    else
      File.chmod!(path, 0o644)
      assert {:error, :invalid_controller_config_file} = ControllerConfig.load(path)
    end
  end

  test "application selects the complete distributed child tree only when configured", ctx do
    System.delete_env("CRF_CONTROLLER_CONFIG")
    assert {:ok, legacy} = Application.children_from_environment()
    legacy_modules = child_modules(legacy)
    refute CrfController.ScaleSetClient in legacy_modules
    refute CrfController.DemandCoordinator in legacy_modules
    refute CrfController.TlsServer in legacy_modules

    path = write_config(ctx, config(ctx))
    System.put_env("CRF_CONTROLLER_CONFIG", path)
    assert {:ok, distributed} = Application.children_from_environment()

    assert child_modules(distributed) == [
             CrfController.NodeRegistry,
             CrfController.PlacementLedger,
             CrfController.OfferLedger,
             CrfController.NodeMailbox,
             CrfController.SchedulerClient,
             CrfController.PlacementCoordinator,
             CrfController.Ingress,
             Task.Supervisor,
             CrfController.ScaleSetClient,
             CrfController.DemandCoordinator,
             CrfController.TlsServer
           ]
  end

  defp child_modules(children) do
    Enum.map(children, fn
      {module, _opts} when is_atom(module) -> module
      other -> raise "unexpected child spec: #{inspect(other)}"
    end)
  end

  defp write_config(ctx, value) do
    path = Path.join(ctx.root, "controller.json")
    File.write!(path, :json.encode(value) |> IO.iodata_to_binary())
    File.chmod!(path, 0o600)
    path
  end

  defp touch(root, name) do
    path = Path.join(root, name)
    File.write!(path, "fixture")
    File.chmod!(path, 0o600)
    path
  end

  defp config(ctx) do
    %{
      "schema_version" => 1,
      "scheduler" => %{
        "executable" => ctx.scheduler,
        "request_timeout_ms" => 5_000
      },
      "state" => %{
        "placement_path" => Path.join(ctx.root, "placements.json")
      },
      "node_registry" => %{
        "stale_after_ms" => 15_000
      },
      "scaleset" => %{
        "socket_path" => Path.join(ctx.root, "scaleset.sock"),
        "sequence_path" => Path.join(ctx.root, "sequence.json"),
        "controller_instance_id" => "controller-1",
        "config_revision" => @revision,
        "ownership_revision" => String.duplicate("b", 64),
        "timeout_ms" => 30_000
      },
      "sidecar" => :null,
      "tls" => %{
        "port" => 7443,
        "certfile" => ctx.cert,
        "keyfile" => ctx.key,
        "cacertfile" => ctx.ca,
        "handshake_timeout_ms" => 15_000,
        "peers" => [
          %{"fingerprint" => @fingerprint, "node_id" => "dookie"}
        ]
      },
      "demand" => %{
        "auto_reconcile" => true,
        "reconcile_interval_ms" => 1_000,
        "offer_ttl_ms" => 90_000,
        "placement_loss_grace_ms" => 60_000,
        "max_new_offers_per_tick" => 4,
        "pools" => [
          %{
            "id" => "build",
            "max_concurrency" => 8,
            "resources" => %{"cpu_millis" => 2_000, "memory_bytes" => 4 * 1024 * 1024 * 1024},
            "required_os" => "linux",
            "required_arch" => "x86_64",
            "required_backend" => "native_process",
            "required_capabilities" => ["github-actions"],
            "work_folder" => "_work"
          }
        ]
      }
    }
  end
end
