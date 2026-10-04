defmodule SymphonyElixir.ProcessSessionTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ProcessSession

  test "prefers the existing setsid --wait launch when available" do
    setsid = System.find_executable("setsid")
    prefix = ProcessSession.prefix()

    if setsid do
      assert prefix == "'#{setsid}' --wait"
    else
      assert is_binary(System.find_executable("perl"))
      assert prefix =~ " -MPOSIX -e "
      assert prefix =~ "fork()"
      assert prefix =~ "POSIX::setsid()"
      assert prefix =~ "exec @ARGV"
    end
  end

  test "retains direct-child fallback when neither launcher exists" do
    assert ProcessSession.prefix(nil, nil) == nil
    assert ProcessSession.prefix("/nonexistent/setsid", "/nonexistent/perl") == nil
  end
end
