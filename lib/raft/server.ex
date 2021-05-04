defmodule Raft.Server do
  use GenServer
  alias Raft.Consensus
  require Logger

  def start_link(cons) do
    name = cons.me
    state = %{cons: cons, timers: %{}}
    GenServer.start_link(__MODULE__, state, name: name)
  end

  def do_actions(state, _actions) do
    state
  end

  @impl true
  def init(state) do
    {cons, actions} = Consensus.init(state.cons)
    state = do_actions(state, actions)
    {:ok, state}
  end

  @impl true
  def handle_cast(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

end
