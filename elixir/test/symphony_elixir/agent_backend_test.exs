defmodule SymphonyElixir.AgentBackendTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{AgentBackend, Config.Schema}
  alias SymphonyElixir.Codex.AppServer

  test "Codex is the closed default backend" do
    assert AgentBackend.supported_names() == ["codex"]
    assert {:ok, AppServer} = AgentBackend.resolve("codex")
    assert {:ok, AppServer} = AgentBackend.resolve(:codex)
    assert {:ok, %{agent: %{backend: "codex"}}} = Schema.parse(%{})
  end

  test "backend selection fails closed" do
    assert {:error, {:unsupported_backend, "unknown"}} = AgentBackend.resolve("unknown")
    assert {:error, {:invalid_backend, 123}} = AgentBackend.resolve(123)
    assert {:error, {:invalid_workflow_config, _}} = Schema.parse(%{"agent" => %{"backend" => "unknown"}})
  end

  test "resolved Codex backend supplies the worker lifecycle" do
    assert {:ok, backend} = AgentBackend.resolve("codex")
    assert {:module, ^backend} = Code.ensure_loaded(backend)
    assert function_exported?(backend, :start_session, 2)
    assert function_exported?(backend, :run_turn, 4)
    assert function_exported?(backend, :stop_session, 1)
  end
end
