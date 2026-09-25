defmodule SymphonyElixir.WorkflowArchiveTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../..", __DIR__)
  @archive_root Path.join(@repo_root, ".github/workflow-archive/2026-09-26")
  @pinned_sha256 %{
    "burrito-nightly.yml" => "f586526f0dbde71ad90a8bf8aa62e75aa101245c49371a7b069d1dcae03e82c9",
    "burrito-release.yml" => "469851a2f0bf10565ffad113ee78312f68478886dac962237a42efb8459e18a8",
    "make-all.yml" => "e8a1a491830005d8e361dd71242deb2c1c4f43dd5bbd3c74b62c9e32c841570e",
    "pr-description-lint.yml" => "d1e8dd4c7a25c40b45270147d3509fc99122484bce4e2841cc2d208f78a5854a"
  }

  test "all four former registered workflows remain byte-identical in the archive" do
    Enum.each(@pinned_sha256, fn {filename, expected_sha256} ->
      contents = File.read!(Path.join(@archive_root, filename))
      actual_sha256 = :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)

      assert actual_sha256 == expected_sha256, "unexpected archived workflow bytes: #{filename}"
    end)
  end

  test "GitHub has no registered workflow files" do
    assert Path.wildcard(Path.join(@repo_root, ".github/workflows/*")) == []
  end
end
