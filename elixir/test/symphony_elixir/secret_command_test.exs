defmodule SymphonyElixir.SecretCommandTest do
  use ExUnit.Case

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.SecretCommand

  test "resolves one-line host output while scrubbing tracker secrets from the helper" do
    root = temp_root!()
    script = Path.join(root, "secret-helper")
    marker = Path.join(root, "environment-marker")
    previous_secret = System.get_env("LINEAR_API_KEY")

    on_exit(fn ->
      restore_env("LINEAR_API_KEY", previous_secret)
      File.rm_rf(root)
    end)

    System.put_env("LINEAR_API_KEY", "ambient-secret-that-helper-must-not-receive")

    write_script!(script, """
    #!/bin/sh
    if [ -n "${LINEAR_API_KEY:-}" ]; then
      printf exposed > "#{marker}"
      exit 11
    fi
    printf '%s\\n' "$1"
    """)

    assert {:ok, "resolved-secret"} = SecretCommand.resolve([script, "resolved-secret"])
    refute File.exists?(marker)
  end

  test "returns bounded typed failures without including command output" do
    root = temp_root!()
    script = Path.join(root, "failing-helper")

    on_exit(fn -> File.rm_rf(root) end)

    write_script!(script, """
    #!/bin/sh
    printf '%s\\n' 'secret-value-that-must-not-enter-the-error'
    exit 9
    """)

    assert {:error, {:secret_command_exit, 9}} = SecretCommand.resolve([script])

    write_script!(script, """
    #!/bin/sh
    printf 'first\\nsecond\\n'
    """)

    assert {:error, :invalid_secret_command_output} = SecretCommand.resolve([script])

    write_script!(script, """
    #!/bin/sh
    head -c 70000 /dev/zero | tr '\\0' x
    """)

    assert {:error, :secret_command_output_too_large} = SecretCommand.resolve([script])
    assert {:error, :invalid_secret_command} = SecretCommand.resolve("echo unsafe")
  end

  test "times out a host secret helper without returning partial output" do
    root = temp_root!()
    script = Path.join(root, "slow-helper")

    on_exit(fn -> File.rm_rf(root) end)

    write_script!(script, """
    #!/bin/sh
    sleep 5
    printf 'late-secret'
    """)

    assert {:error, :secret_command_timeout} =
             SecretCommand.resolve([script], timeout_ms: 10)
  end

  test "Linear config resolves api_key_command host-side instead of using ambient LINEAR_API_KEY" do
    root = temp_root!()
    script = Path.join(root, "linear-secret-helper")
    previous_secret = System.get_env("LINEAR_API_KEY")

    on_exit(fn ->
      restore_env("LINEAR_API_KEY", previous_secret)
      File.rm_rf(root)
    end)

    System.put_env("LINEAR_API_KEY", "ambient-linear-secret")
    write_script!(script, "#!/bin/sh\nprintf '%s\\n' 'command-linear-secret'\n")

    assert {:ok, settings} =
             Schema.parse(%{
               "tracker" => %{
                 "kind" => "linear",
                 "provider" => %{
                   "api_key_command" => [script],
                   "api_key_command_secret_environment_names" => ["BW_SESSION", "BW_PASSWORD"],
                   "project_slug" => "project"
                 }
               }
             })

    assert settings.tracker.api_key == "command-linear-secret"
    assert settings.tracker.provider["api_key_command"] == [script]

    assert settings.tracker.secret_environment_names == [
             "LINEAR_API_KEY",
             "BW_SESSION",
             "BW_PASSWORD"
           ]
  end

  test "Linear config returns a typed api_key_command failure without command output" do
    root = temp_root!()
    script = Path.join(root, "failing-linear-secret-helper")

    on_exit(fn -> File.rm_rf(root) end)

    write_script!(script, "#!/bin/sh\nprintf '%s\\n' 'secret-output-must-not-leak'\nexit 9\n")

    result =
      Schema.parse(%{
        "tracker" => %{
          "kind" => "linear",
          "provider" => %{
            "api_key_command" => [script],
            "project_slug" => "project"
          }
        }
      })

    assert {:error, {:tracker_secret_command_failed, {:secret_command_exit, 9}}} = result
    refute inspect(result) =~ "secret-output-must-not-leak"
  end

  test "rejects invalid helper-auth environment names instead of leaving them in agent children" do
    assert {:error, {:invalid_secret_command_environment_names, ["BW_SESSION", "INVALID=VALUE"]}} =
             Schema.parse(%{
               "tracker" => %{
                 "kind" => "linear",
                 "provider" => %{
                   "api_key_command_secret_environment_names" => [
                     "BW_SESSION",
                     "INVALID=VALUE"
                   ],
                   "project_slug" => "project"
                 }
               }
             })
  end

  defp temp_root! do
    root = Path.join(System.tmp_dir!(), "symphony-secret-command-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    root
  end

  defp write_script!(path, contents) do
    File.write!(path, contents)
    File.chmod!(path, 0o755)
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
