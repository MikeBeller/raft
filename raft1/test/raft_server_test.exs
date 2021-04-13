defmodule Raft.ServerTest do
  use ExUnit.Case
  alias Raft.Server

  test "start election timer" do
    {:ok, _server} = Raft.Server.start_link(name: :foo)
    :timer.sleep(1000)

  end
end
