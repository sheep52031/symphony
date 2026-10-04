defmodule SymphonyElixir.ProcessSession do
  @moduledoc false

  # Prefer util-linux unchanged. Stock macOS has Perl's POSIX setsid instead.
  # Callers with a trust boundary supply absolute paths rather than searching PATH.
  @spec prefix(Path.t() | nil, Path.t() | nil) :: String.t() | nil
  def prefix(setsid \\ System.find_executable("setsid"), perl \\ System.find_executable("perl")) do
    cond do
      executable?(setsid) ->
        "#{shell_escape(setsid)} --wait"

      executable?(perl) ->
        # Erlang ports can already be group leaders, in which case setsid would fail
        # with EPERM. Fork first, and keep the port parent waiting just like --wait.
        script =
          "my $pid = fork(); defined $pid or die \"fork: $!\"; " <>
            "if ($pid) { waitpid($pid, 0); exit(($? & 127) ? 128 + ($? & 127) : $? >> 8); } " <>
            "POSIX::setsid() >= 0 or die \"setsid: $!\"; exec @ARGV or die \"exec: $!\""

        "#{shell_escape(perl)} -MPOSIX -e #{shell_escape(script)} --"

      true ->
        nil
    end
  end

  defp executable?(path) when is_binary(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp executable?(_path), do: false

  defp shell_escape(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
end
