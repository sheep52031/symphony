defmodule SymphonyElixir.Antigravity.Launcher do
  @moduledoc false

  alias SymphonyElixir.PathSafety

  @bubblewrap "/usr/bin/bwrap"
  @trusted_path "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  @private_runtime_dir "/tmp/symphony-antigravity-runtime"
  @private_agy_path "/tmp/symphony-antigravity-agy"
  @private_tmpfs_roots ["/tmp", "/run/user"]
  @security_sensitive_roots ["/bin", "/boot", "/dev", "/etc", "/lib", "/lib64", "/proc", "/root", "/run", "/sbin", "/sys", "/usr"]
  @broad_writable_roots ["/home", "/media", "/mnt", "/opt", "/srv", "/tmp", "/var", "/var/lib", "/var/tmp"]
  @dedicated_parent_roots ["/tmp", "/var/lib", "/var/tmp", "/opt", "/srv", "/mnt", "/media"]
  @credential_home_roots [
    ".ssh",
    ".gnupg",
    ".aws",
    ".azure",
    ".kube",
    ".docker",
    ".config",
    ".local",
    ".cache",
    ".password-store"
  ]

  @type launch :: %{
          executable: Path.t(),
          args: [String.t()],
          workspace: Path.t(),
          profile_root: Path.t(),
          agy_executable: Path.t()
        }

  @spec build(Path.t(), Path.t(), Path.t(), pos_integer(), keyword()) ::
          {:ok, launch()} | {:error, term()}
  def build(workspace, agy_executable, profile_root, turn_timeout_ms, opts)
      when is_binary(workspace) and is_binary(agy_executable) and is_binary(profile_root) and
             is_integer(turn_timeout_ms) and turn_timeout_ms > 0 do
    bubblewrap = Keyword.get(opts, :bubblewrap_executable, @bubblewrap)

    with {:ok, canonical_home} <- canonical_user_home(),
         {:ok, canonical_workspace} <- canonical_directory(workspace, :workspace),
         {:ok, canonical_profile_root} <- canonical_directory(profile_root, :profile_root),
         :ok <- validate_workspace_boundary(canonical_workspace, canonical_home),
         :ok <- validate_profile_boundary(canonical_workspace, canonical_profile_root, canonical_home),
         :ok <- ensure_directory(canonical_workspace, :workspace),
         :ok <- ensure_directory(canonical_profile_root, :profile_root),
         {:ok, canonical_agy} <- canonical_executable(agy_executable, :agy),
         :ok <- validate_executable_boundary(canonical_workspace, canonical_profile_root, canonical_agy),
         {:ok, canonical_bubblewrap} <- canonical_executable(bubblewrap, :bubblewrap) do
      {:ok,
       %{
         executable: canonical_bubblewrap,
         args:
           bubblewrap_args(
             canonical_home,
             canonical_workspace,
             canonical_profile_root,
             canonical_agy,
             turn_timeout_ms
           ),
         workspace: canonical_workspace,
         profile_root: canonical_profile_root,
         agy_executable: canonical_agy
       }}
    end
  end

  def build(workspace, agy_executable, profile_root, turn_timeout_ms, _opts) do
    config = %{
      workspace: workspace,
      executable: agy_executable,
      profile_root: profile_root,
      turn_timeout_ms: turn_timeout_ms
    }

    {:error, {:invalid_antigravity_launch_config, config}}
  end

  @spec trusted_path() :: String.t()
  def trusted_path, do: @trusted_path

  defp bubblewrap_args(home, workspace, profile_root, agy_executable, turn_timeout_ms) do
    [
      "--die-with-parent",
      "--new-session",
      "--unshare-all",
      "--share-net",
      "--unshare-user",
      "--disable-userns",
      "--ro-bind",
      "/",
      "/",
      "--tmpfs",
      "/run/user",
      "--dev",
      "/dev",
      "--proc",
      "/proc",
      "--tmpfs",
      "/tmp"
    ] ++
      home_mount_args(home) ++
      destination_directory_args([workspace, profile_root], home) ++
      [
        "--dir",
        @private_runtime_dir,
        "--chmod",
        "0700",
        @private_runtime_dir,
        "--bind",
        workspace,
        workspace,
        "--ro-bind",
        Path.join(workspace, ".symphony"),
        Path.join(workspace, ".symphony"),
        "--bind",
        profile_root,
        profile_root,
        "--ro-bind",
        agy_executable,
        @private_agy_path,
        "--chdir",
        workspace,
        "--clearenv"
      ] ++
      environment_args(profile_root) ++
      [
        "--",
        @private_agy_path,
        "--sandbox",
        "--mode",
        "accept-edits",
        "--input-format",
        "stream-json",
        "--output-format",
        "stream-json",
        "--print-timeout",
        native_timeout(turn_timeout_ms + 5_000)
      ]
  end

  defp home_mount_args(home) do
    if private_tmpfs_path?(home), do: [], else: ["--tmpfs", home]
  end

  defp destination_directory_args(paths, home) do
    paths
    |> Enum.flat_map(&destination_ancestors(&1, home))
    |> Enum.uniq()
    |> Enum.sort_by(&{length(Path.split(&1)), &1})
    |> Enum.flat_map(fn path -> ["--dir", path] end)
  end

  defp destination_ancestors(path, home) do
    private_root = private_root_for(path, home)

    case private_root do
      nil ->
        []

      ^path ->
        []

      root ->
        path
        |> Path.split()
        |> Enum.drop(length(Path.split(root)))
        |> Enum.scan(root, &Path.join(&2, &1))
    end
  end

  defp private_root_for(path, home) do
    case Enum.find(@private_tmpfs_roots, &path_contains?(&1, path)) do
      nil -> if not private_tmpfs_path?(home) and path_contains?(home, path), do: home
      root -> root
    end
  end

  defp private_tmpfs_path?(path), do: Enum.any?(@private_tmpfs_roots, &path_contains?(&1, path))

  defp environment_args(profile_root) do
    base = %{
      "HOME" => profile_root,
      "LANG" => System.get_env("LANG") || "C.UTF-8",
      "PATH" => @trusted_path,
      "XDG_RUNTIME_DIR" => @private_runtime_dir
    }

    ["LC_ALL", "LC_CTYPE"]
    |> Enum.reduce(base, fn name, environment ->
      case System.get_env(name) do
        value when is_binary(value) and value != "" -> Map.put(environment, name, value)
        _ -> environment
      end
    end)
    |> Enum.sort()
    |> Enum.flat_map(fn {name, value} -> ["--setenv", name, value] end)
  end

  defp native_timeout(turn_timeout_ms) do
    seconds = turn_timeout_ms |> Kernel.+(999) |> div(1_000)
    "#{seconds}s"
  end

  defp canonical_directory(path, label) do
    case PathSafety.canonicalize(path) do
      {:ok, canonical} -> {:ok, canonical}
      {:error, reason} -> {:error, {:invalid_antigravity_directory, label, reason}}
    end
  end

  defp ensure_directory(path, label) do
    if File.dir?(path),
      do: :ok,
      else: {:error, {:antigravity_directory_not_found, label, path}}
  end

  defp canonical_user_home do
    System.user_home()
    |> canonical_user_home()
  rescue
    _error -> {:error, :invalid_antigravity_home}
  end

  defp canonical_user_home(configured_home) do
    with true <- Path.type(configured_home) == :absolute,
         {:ok, first} <- PathSafety.canonicalize(configured_home),
         true <- first != "/" and File.dir?(first),
         true <- not top_level_path?(first),
         true <- not security_sensitive_path?(first),
         {:ok, second} <- PathSafety.canonicalize(configured_home),
         true <- second == first and File.dir?(second) do
      {:ok, first}
    else
      {:error, reason} -> {:error, {:invalid_antigravity_home, reason}}
      false -> {:error, {:unsafe_antigravity_home, Path.expand(configured_home)}}
    end
  end

  defp canonical_executable(path, label) do
    with true <- Path.type(path) == :absolute,
         {:ok, canonical} <- PathSafety.canonicalize(path),
         {:ok, %File.Stat{type: :regular, mode: mode}} <- File.stat(canonical),
         true <- Bitwise.band(mode, 0o111) != 0 do
      {:ok, canonical}
    else
      false -> {:error, {:invalid_antigravity_executable, label, path}}
      {:ok, %File.Stat{}} -> {:error, {:invalid_antigravity_executable, label, path}}
      {:error, reason} -> {:error, {:invalid_antigravity_executable, label, path, reason}}
    end
  end

  defp validate_workspace_boundary(workspace, home),
    do: validate_writable_root(workspace, :workspace, home)

  defp validate_profile_boundary(workspace, profile_root, home) do
    with :ok <- validate_writable_root(profile_root, :profile_root, home) do
      if path_contains?(workspace, profile_root) or path_contains?(profile_root, workspace),
        do: {:error, {:overlapping_antigravity_write_roots, workspace, profile_root}},
        else: :ok
    end
  end

  defp validate_writable_root(path, label, home) do
    if unsafe_writable_root?(path, home) or not dedicated_writable_root?(path, home),
      do: {:error, unsafe_writable_root_error(label, path)},
      else: :ok
  end

  defp unsafe_writable_root?(path, home) do
    path == "/" or path_contains?(path, home) or
      (path_contains?(home, path) and not dedicated_home_root?(path, home)) or
      security_sensitive_path?(path) or path in @broad_writable_roots or top_level_path?(path)
  end

  defp dedicated_writable_root?(path, home) do
    dedicated_home_root?(path, home) or Enum.any?(@dedicated_parent_roots, &strictly_contains?(&1, path))
  end

  defp dedicated_home_root?(path, home) do
    if path_contains?(home, path) and path != home do
      case relative_path_segments(home, path) do
        [".agy-profiles", _slot] -> true
        [first, _second | _rest] -> not credential_home_root?(first)
        _ -> false
      end
    else
      false
    end
  end

  defp credential_home_root?(segment),
    do: segment in @credential_home_roots or String.starts_with?(segment, ".")

  defp relative_path_segments(parent, child) do
    child
    |> Path.split()
    |> Enum.drop(length(Path.split(parent)))
  end

  defp security_sensitive_path?(path),
    do: Enum.any?(@security_sensitive_roots, &path_contains?(&1, path))

  defp top_level_path?(path), do: length(Path.split(path)) == 2

  defp strictly_contains?(parent, child), do: path_contains?(parent, child) and parent != child

  defp unsafe_writable_root_error(:workspace, path), do: {:unsafe_antigravity_workspace, path}
  defp unsafe_writable_root_error(:profile_root, path), do: {:unsafe_antigravity_profile_root, path}

  defp validate_executable_boundary(workspace, profile_root, executable) do
    if path_contains?(workspace, executable) or path_contains?(profile_root, executable),
      do: {:error, {:unsafe_antigravity_executable_location, executable}},
      else: :ok
  end

  defp path_contains?(parent, child) do
    parent_segments = Path.split(parent)
    child_segments = Path.split(child)
    Enum.take(child_segments, length(parent_segments)) == parent_segments
  end
end
