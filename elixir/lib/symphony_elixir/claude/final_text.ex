defmodule SymphonyElixir.Claude.FinalText do
  @moduledoc """
  Makes the final assistant text of a completed Claude turn visible. The status surfaces get a short
  summary and `<workspace>/.symphony/claude/last-result.txt` gets the bounded full text. Only the
  assistant's own `result` text is read; environment values, the config directory and credentials
  are never touched, written or logged.
  """

  require Logger

  @summary_characters 2_000
  @file_bytes 65_536
  @file_mode 0o600
  @directory_mode 0o700
  @relative_path ".symphony/claude/last-result.txt"

  @doc "The first #{@summary_characters} characters of the final text, or nil when the turn produced none."
  @spec summary(map()) :: String.t() | nil
  def summary(result) do
    case text(result) do
      nil -> nil
      text -> String.slice(text, 0, @summary_characters)
    end
  end

  @doc """
  Overwrites the private result file with the final text (at most #{@file_bytes} bytes, cut on a
  character boundary). A failed write never fails the turn: the summary still reaches the status
  surfaces, and the log names only the session and the POSIX reason.
  """
  @spec write(Path.t(), map()) :: :ok
  def write(workspace, result) do
    content = bounded(text(result) || "")

    case write_private(Path.join(workspace, @relative_path), content) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Claude final result file not written session_id=#{inspect(result["session_id"])} reason=#{inspect(reason)}")
    end
  end

  defp text(%{"result" => text}) when is_binary(text), do: if(String.trim(text) == "", do: nil, else: text)
  defp text(_result), do: nil

  defp bounded(text) when byte_size(text) <= @file_bytes, do: text

  defp bounded(text) do
    case :unicode.characters_to_binary(binary_part(text, 0, @file_bytes)) do
      valid when is_binary(valid) -> valid
      {_status, valid, _rest} -> valid
    end
  end

  # The workspace is writable by the child, so never follow a path it could have pre-created and never
  # expose the text to another user. The private directory is mode 0700 (other users cannot even reach
  # the temporary file, whatever the umask), the temporary file is created exclusively under a random
  # name, chmod to 0600 BEFORE any text is written, and the text goes through that same open file
  # descriptor (the path is never reopened). Finally rename replaces a symlink instead of following it.
  defp write_private(path, text) do
    directory = Path.dirname(path)
    temporary = path <> "." <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false) <> ".tmp"

    with :ok <- File.mkdir_p(directory),
         :ok <- File.chmod(directory, @directory_mode),
         {:ok, io} <- File.open(temporary, [:write, :exclusive, :binary]) do
      written = write_through(io, temporary, text)
      _ = File.close(io)

      with :ok <- written,
           :ok <- File.rename(temporary, path) do
        :ok
      else
        {:error, _reason} = error ->
          _ = File.rm(temporary)
          error
      end
    end
  end

  defp write_through(io, temporary, text) do
    with :ok <- File.chmod(temporary, @file_mode) do
      IO.binwrite(io, text)
    end
  end
end
