defmodule Raft.ServerTest do
  use ExUnit.Case, async: false
  alias Raft.Consensus
  alias Raft.Server

  test "init" do
    nodes = [:a, :b, :c]
    _a = Consensus.new(:a)
    _b = Consensus.new(:b)
    _c = Consensus.new(:c)
    nodes |> Enum.each(&Server.start_link/1)
    nodes |> Enum.each(&Server.ev(&1, {:config, nodes}))
  end
end
