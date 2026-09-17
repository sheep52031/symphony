defmodule SymphonyElixir.SecretCommand do
  @moduledoc """
  Resolves a host-side secret from a non-shell command without placing the result in child process
  arguments or environment.
  """

  @default_timeout_ms 15_000
  @max_secret_bytes 65_536

  @spec resolve(term(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def resolve(command, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    with {:ok, executable, arguments} <- normalize_command(command),
         :ok <- validate_timeout(timeout_ms),
         {:ok, output, 0} <- run_command(executable, arguments, timeout_ms),
         {:ok, secret} <- normalize_secret(output) do
      {:ok, secret}
    else
      {:ok, _output, status} -> {:error, {:secret_command_exit, status}}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_command([executable | arguments])
       when is_binary(executable) and is_list(arguments) do
    cond do
      String.trim(executable) == "" ->
        {:error, :empty_secret_command}

      not Enum.all?(arguments, &is_binary/1) ->
        {:error, :invalid_secret_command_arguments}

      true ->
        case System.find_executable(executable) do
          nil -> {:error, {:secret_command_not_found, executable}}
          path -> {:ok, path, arguments}
        end
    end
  end

  defp normalize_command(_command), do: {:error, :invalid_secret_command}

  defp validate_timeout(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0, do: :ok
  defp validate_timeout(timeout_ms), do: {:error, {:invalid_secret_command_timeout, timeout_ms}}

  defp run_command(executable, arguments, timeout_ms) do
    task =
      Task.async(fn ->
        try do
          {:ok,
           System.cmd(executable, arguments,
             stderr_to_stdout: true,
             env: scrubbed_secret_environment()
           )}
        rescue
          error in [ArgumentError, ErlangError] ->
            {:error, {:secret_command_start_failed, error}}
        end
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, {output, status}}} -> {:ok, output, status}
      {:ok, {:error, reason}} -> {:error, reason}
      {:exit, reason} -> {:error, {:secret_command_start_failed, reason}}
      nil -> {:error, :secret_command_timeout}
    end
  end

  defp scrubbed_secret_environment do
    [
      {"LINEAR_API_KEY", nil},
      {"GITHUB_TOKEN", nil},
      {"GITLAB_PAT", nil},
      {"ASANA_PAT", nil},
      {"JIRA_API_TOKEN", nil}
    ]
  end

  defp normalize_secret(output) when is_binary(output) and byte_size(output) <= @max_secret_bytes do
    secret = String.trim(output)

    cond do
      secret == "" -> {:error, :empty_secret_command_output}
      String.contains?(secret, ["\n", "\r", <<0>>]) -> {:error, :invalid_secret_command_output}
      true -> {:ok, secret}
    end
  end

  defp normalize_secret(output) when is_binary(output), do: {:error, :secret_command_output_too_large}
  defp normalize_secret(_output), do: {:error, :invalid_secret_command_output}
end
